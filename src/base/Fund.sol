// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Math } from "src/utils/Math.sol";
import { ERC4626, ERC20 } from "src/base/ERC4626.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { Registry } from "src/Registry.sol";
import { PriceRouter } from "src/modules/price-router/PriceRouter.sol";
import { Uint32Array } from "src/utils/Uint32Array.sol";
import { BaseAdaptor } from "src/modules/adaptors/BaseAdaptor.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Owned } from "@solmate/auth/Owned.sol";
import { FeesManager } from "src/modules/fees/FeesManager.sol";

/**
 * @title Swaap Fund
 * @notice A composable ERC4626 that can use arbitrary DeFi assets/positions using adaptors.
 * @dev Forked from https://github.com/PeggyJV/cellar-contracts
 */
contract Fund is ERC4626, Ownable {
    using Uint32Array for uint32[];
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using Address for address;

    // ========================================= One Slot Values =========================================
    // Below values are frequently accessed in the same TXs. By moving them to the top
    // they will be stored in the same slot, reducing cold access reads.

    /**
     * @notice The maximum amount of shares that can be in circulation.
     * @dev Can be increase or decreased by Fund's Owner.
     */
    uint192 public shareSupplyCap;

    /**
     * @notice `locked` is public, so that the state can be checked even during view function calls.
     */
    bool public locked;

    /**
     * @notice Whether or not the contract is shutdown in case of an emergency.
     */
    bool public isShutdown;

    /**
     * @notice This bool is used to stop rebalancers from abusing Base Adaptor functions(deposit/withdraw).
     */
    bool public blockExternalReceiver;

    /**
     * @notice Stores the position id of the holding position in the creditPositions array.
     */
    uint32 public holdingPosition;

    /**
     * @notice Sets the end date when the fund pause mode will be disregarded whatever its state.
     */
    uint256 public immutable endPauseTimestamp;

    // ========================================= MULTICALL =========================================

    /**
     * @notice Allows caller to call multiple functions in a single TX.
     * @dev Does NOT return the function return values.
     */
    function multicall(bytes[] calldata data) external {
        for (uint256 i; i < data.length; ++i) address(this).functionDelegateCall(data[i]);
    }

    // ========================================= REENTRANCY GUARD =========================================

    error Fund__Reentrancy();

    function _revertWhenReentrant() internal view {
        if (locked) revert Fund__Reentrancy();
    }

    function _nonReentrantAfter() internal {
        locked = false;
    }

    function _nonReentrantBefore() internal {
        _revertWhenReentrant();
        locked = true;
    }

    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    // ========================================= PRICE ROUTER CACHE =========================================

    /**
     * @notice Cached price router contract.
     * @dev This way fund has to "opt in" to price router changes.
     */
    PriceRouter public priceRouter;

    /**
     * @notice Updates the fund to use the latest price router in the registry.
     * @param checkTotalAssets If true totalAssets is checked before and after updating the price router,
     *        and is verified to be withing a +- 5% envelope.
     *        If false totalAssets is only called after updating the price router.]
     * @param allowableRange The +- range the total assets may deviate between the old and new price router.
     *                       - 1_000 == 10%
     *                       - 500 == 5%
     * @param expectedPriceRouter The registry price router differed from the expected price router.
     * @dev `allowableRange` reverts from arithmetic underflow if it is greater than 10_000, this is
     *      desired behavior.
     * @dev Callable by the Fund's owner.
     */
    function cachePriceRouter(
        bool checkTotalAssets,
        uint16 allowableRange,
        address expectedPriceRouter
    ) external onlyOwner {
        uint256 minAssets;
        uint256 maxAssets;

        if (checkTotalAssets) {
            uint256 assetsBefore = totalAssets();
            minAssets = assetsBefore.mulDivDown(1e4 - allowableRange, 1e4);
            maxAssets = assetsBefore.mulDivDown(1e4 + allowableRange, 1e4);
        }

        // Make sure expected price router is equal to price router grabbed from registry.
        _checkRegistryAddressAgainstExpected(_PRICE_ROUTER_REGISTRY_SLOT, expectedPriceRouter);

        priceRouter = PriceRouter(expectedPriceRouter);

        if (checkTotalAssets) {
            uint256 assetsAfter = totalAssets();
            if (assetsAfter < minAssets || assetsAfter > maxAssets)
                revert Fund__TotalAssetDeviatedOutsideRange(assetsAfter, minAssets, maxAssets);
        }
    }

    // ========================================= POSITIONS CONFIG =========================================

    /**
     * @notice Emitted when a position is added.
     * @param position id of position that was added
     * @param index index that position was added at
     */
    event PositionAdded(uint32 position, uint256 index);

    /**
     * @notice Emitted when a position is removed.
     * @param position id of position that was removed
     * @param index index that position was removed from
     */
    event PositionRemoved(uint32 position, uint256 index);

    /**
     * @notice Emitted when the positions at two indexes are swapped.
     * @param newPosition1 id of position (previously at index2) that replaced index1.
     * @param newPosition2 id of position (previously at index1) that replaced index2.
     * @param index1 index of first position involved in the swap
     * @param index2 index of second position involved in the swap.
     */
    event PositionSwapped(uint32 newPosition1, uint32 newPosition2, uint256 index1, uint256 index2);

    /**
     * @notice Emitted when owner adds/removes a position to/from the funds catalogue.
     */
    event PositionCatalogueAltered(uint32 positionId, bool inCatalogue);

    /**
     * @notice Emitted when owner adds/removes an adaptor to/from the funds catalogue.
     */
    event AdaptorCatalogueAltered(address adaptor, bool inCatalogue);

    /**
     * @notice Attempted to add a position that is already being used.
     * @param position id of the position
     */
    error Fund__PositionAlreadyUsed(uint32 position);

    /**
     * @notice Attempted to make an unused position the holding position.
     * @param position id of the position
     */
    error Fund__PositionNotUsed(uint32 position);

    /**
     * @notice Attempted to add a position that is not in the catalogue.
     * @param position id of the position
     */
    error Fund__PositionNotInCatalogue(uint32 position);

    /**
     * @notice Attempted an action on a position that is required to be empty before the action can be performed.
     * @param position address of the non-empty position
     * @param sharesRemaining amount of shares remaining in the position
     */
    error Fund__PositionNotEmpty(uint32 position, uint256 sharesRemaining);

    /**
     * @notice Attempted an operation with an asset that was different then the one expected.
     * @param asset address of the asset
     * @param expectedAsset address of the expected asset
     */
    error Fund__AssetMismatch(address asset, address expectedAsset);

    /**
     * @notice Attempted to add a position when the position array is full.
     * @param maxPositions maximum number of positions that can be used
     */
    error Fund__PositionArrayFull(uint256 maxPositions);

    /**
     * @notice Attempted to add a position, with mismatched debt.
     * @param position the posiiton id that was mismatched
     */
    error Fund__DebtMismatch(uint32 position);

    /**
     * @notice Attempted to remove the Funds holding position.
     */
    error Fund__RemovingHoldingPosition();

    /**
     * @notice Attempted to add an invalid holding position.
     * @param positionId the id of the invalid position.
     */
    error Fund__InvalidHoldingPosition(uint32 positionId);

    /**
     * @notice Attempted to force out the wrong position.
     */
    error Fund__FailedToForceOutPosition();

    /**
     * @notice Array of uint32s made up of funds credit positions Ids.
     */
    uint32[] public creditPositions;

    /**
     * @notice Array of uint32s made up of funds debt positions Ids.
     */
    uint32[] public debtPositions;

    /**
     * @notice Tell whether a position is currently used.
     */
    mapping(uint256 => bool) public isPositionUsed;

    /**
     * @notice Get position data given position id.
     */
    mapping(uint32 => Registry.PositionData) public getPositionData;

    /**
     * @notice Get the ids of the credit positions currently used by the fund.
     */
    function getCreditPositions() external view returns (uint32[] memory) {
        return creditPositions;
    }

    /**
     * @notice Get the ids of the debt positions currently used by the fund.
     */
    function getDebtPositions() external view returns (uint32[] memory) {
        return debtPositions;
    }

    /**
     * @notice Maximum amount of positions a fund can have in its credit/debt arrays.
     */
    uint256 internal constant _MAX_POSITIONS = 32;

    /**
     * @notice Allows owner to change the holding position.
     * @dev Callable by the Fund's owner.
     */
    function setHoldingPosition(uint32 positionId) public onlyOwner {
        if (!isPositionUsed[positionId]) revert Fund__PositionNotUsed(positionId);
        if (_assetOf(positionId) != asset) revert Fund__AssetMismatch(address(asset), address(_assetOf(positionId)));
        if (getPositionData[positionId].isDebt) revert Fund__InvalidHoldingPosition(positionId);
        holdingPosition = positionId;
    }

    /**
     * @notice Positions the rebalancers can use.
     */
    mapping(uint32 => bool) public positionCatalogue;

    /**
     * @notice Adaptors the rebalancers can use.
     */
    mapping(address => bool) public adaptorCatalogue;

    /**
     * @notice Allows the Owner to add positions to this fund's catalogue.
     * @dev Callable by the Fund's owner.
     */
    function addPositionToCatalogue(uint32 positionId) public onlyOwner {
        // Make sure position is not paused and is trusted.
        registry.revertIfPositionIsNotTrusted(positionId);
        positionCatalogue[positionId] = true;
        emit PositionCatalogueAltered(positionId, true);
    }

    /**
     * @notice Allows owner to remove positions from this fund's catalogue.
     * @dev Callable by the Fund's owner.
     */
    function removePositionFromCatalogue(uint32 positionId) external onlyOwner {
        positionCatalogue[positionId] = false;
        emit PositionCatalogueAltered(positionId, false);
    }

    /**
     * @notice Allows owner to add adaptors to this fund's catalogue.
     * @dev Callable by the Fund's owner.
     */
    function addAdaptorToCatalogue(address adaptor) external onlyOwner {
        // Make sure adaptor is not paused and is trusted.
        registry.revertIfAdaptorIsNotTrusted(adaptor);
        adaptorCatalogue[adaptor] = true;
        emit AdaptorCatalogueAltered(adaptor, true);
    }

    /**
     * @notice Allows owner to remove adaptors from this fund's catalogue.
     * @dev Callable by the Fund's owner.
     */
    function removeAdaptorFromCatalogue(address adaptor) external onlyOwner {
        adaptorCatalogue[adaptor] = false;
        emit AdaptorCatalogueAltered(adaptor, false);
    }

    /**
     * @notice Insert a trusted position to the list of positions used by the fund at a given index.
     * @param index index at which to insert the position
     * @param positionId id of position to add
     * @param configurationData data used to configure how the position behaves
     * @dev Callable by the Fund's owner.
     */
    function addPosition(
        uint32 index,
        uint32 positionId,
        bytes memory configurationData,
        bool inDebtArray
    ) public onlyOwner {
        _whenNotShutdown();

        // Check if position is already being used.
        if (isPositionUsed[positionId]) revert Fund__PositionAlreadyUsed(positionId);

        // Check if position is in the position catalogue.
        if (!positionCatalogue[positionId]) revert Fund__PositionNotInCatalogue(positionId);

        // Grab position data from registry.
        // Also checks if position is not trusted and reverts if so.
        (address adaptor, bool isDebt, bytes memory adaptorData) = registry.addPositionToFund(positionId);

        if (isDebt != inDebtArray) revert Fund__DebtMismatch(positionId);

        // Copy position data from registry to here.
        getPositionData[positionId] = Registry.PositionData({
            adaptor: adaptor,
            isDebt: isDebt,
            adaptorData: adaptorData,
            configurationData: configurationData
        });

        if (isDebt) {
            if (debtPositions.length >= _MAX_POSITIONS) revert Fund__PositionArrayFull(_MAX_POSITIONS);
            // Add new position at a specified index.
            debtPositions.add(index, positionId);
        } else {
            if (creditPositions.length >= _MAX_POSITIONS) revert Fund__PositionArrayFull(_MAX_POSITIONS);
            // Add new position at a specified index.
            creditPositions.add(index, positionId);
        }

        isPositionUsed[positionId] = true;

        emit PositionAdded(positionId, index);
    }

    /**
     * @notice Remove the position at a given index from the list of positions used by the fund.
     * @dev Callable by the Fund's owner.
     * @param index index at which to remove the position
     */
    function removePosition(uint32 index, bool inDebtArray) external onlyOwner {
        // Get position being removed.
        uint32 positionId = inDebtArray ? debtPositions[index] : creditPositions[index];

        // Only remove position if it is empty, and if it is not the holding position.
        uint256 positionBalance = _balanceOf(positionId);
        if (positionBalance > 0) revert Fund__PositionNotEmpty(positionId, positionBalance);

        _removePosition(index, positionId, inDebtArray);
    }

    /**
     * @notice Allows Fund's owner to forceably remove a position from the Fund without checking its balance is zero.
     * @dev Callable by the Fund's owner.
     */
    function forcePositionOut(uint32 index, uint32 positionId, bool inDebtArray) external onlyOwner {
        // Get position being removed.
        uint32 _positionId = inDebtArray ? debtPositions[index] : creditPositions[index];
        // Make sure position id right, and is distrusted.
        if (positionId != _positionId || registry.isPositionTrusted(positionId))
            revert Fund__FailedToForceOutPosition();

        _removePosition(index, positionId, inDebtArray);
    }

    /**
     * @notice Internal helper function to remove positions from funds tracked arrays.
     */
    function _removePosition(uint32 index, uint32 positionId, bool inDebtArray) internal {
        if (positionId == holdingPosition) revert Fund__RemovingHoldingPosition();

        if (inDebtArray) {
            // Remove position at the given index.
            debtPositions.remove(index);
        } else {
            creditPositions.remove(index);
        }

        isPositionUsed[positionId] = false;
        delete getPositionData[positionId];

        emit PositionRemoved(positionId, index);
    }

    /**
     * @notice Swap the positions at two given indexes.
     * @param index1 index of first position to swap
     * @param index2 index of second position to swap
     * @param inDebtArray bool indicating to switch positions in the debt array, or the credit array.
     * @dev Callable by the Fund's owner.
     */
    function swapPositions(uint32 index1, uint32 index2, bool inDebtArray) external onlyOwner {
        // Get the new positions that will be at each index.
        uint32 newPosition1;
        uint32 newPosition2;

        if (inDebtArray) {
            newPosition1 = debtPositions[index2];
            newPosition2 = debtPositions[index1];
            // Swap positions.
            (debtPositions[index1], debtPositions[index2]) = (newPosition1, newPosition2);
        } else {
            newPosition1 = creditPositions[index2];
            newPosition2 = creditPositions[index1];
            // Swap positions.
            (creditPositions[index1], creditPositions[index2]) = (newPosition1, newPosition2);
        }

        emit PositionSwapped(newPosition1, newPosition2, index1, index2);
    }

    // =========================================== EMERGENCY LOGIC ===========================================

    /**
     * @notice Emitted when fund emergency state is changed.
     * @param isShutdown whether the fund is shutdown
     */
    event ShutdownChanged(bool isShutdown);

    /**
     * @notice Attempted action was prevented due to contract being shutdown.
     */
    error Fund__ContractShutdown();

    /**
     * @notice Attempted action was prevented due to contract not being shutdown.
     */
    error Fund__ContractNotShutdown();

    /**
     * @notice Attempted to interact with the fund when it is paused.
     */
    error Fund__Paused();

    /**
     * @notice View function external contracts can use to see if the fund is paused.
     */
    function isPaused() public view returns (bool) {
        if (block.timestamp < endPauseTimestamp) {
            return registry.isCallerPaused(address(this));
        }
        return false;
    }

    /**
     * @notice Pauses all user entry/exits, and rebalances.
     */
    function _whenNotPaused() internal view {
        if (isPaused()) revert Fund__Paused();
    }

    /**
     * @notice Prevent a function from being called during a shutdown.
     */
    function _whenNotShutdown() internal view {
        if (isShutdown) revert Fund__ContractShutdown();
    }

    /**
     * @notice Shutdown the fund. Used in an emergency or if the fund has been deprecated.
     * @dev Callable by the Fund's owner.
     */
    function initiateShutdown() external onlyOwner {
        _whenNotShutdown();
        isShutdown = true;

        emit ShutdownChanged(true);
    }

    /**
     * @notice Restart the fund.
     * @dev Callable by the Fund's owner.
     */
    function liftShutdown() external onlyOwner {
        if (!isShutdown) revert Fund__ContractNotShutdown();
        isShutdown = false;

        emit ShutdownChanged(false);
    }

    // =========================================== CONSTRUCTOR ===========================================

    /**
     * @notice Delay between the creation of the fund and the end of the pause period.
     */
    uint256 internal constant _DELAY_UNTIL_END_PAUSE = 30 days * 9; // 9 months

    /**
     * @notice Id to get the price router from the registry.
     */
    uint256 internal constant _PRICE_ROUTER_REGISTRY_SLOT = 2;

    /**
     * @notice The minimum amount of shares to be minted in the contructor.
     */
    uint256 internal constant _MINIMUM_CONSTRUCTOR_MINT = 1e4;

    uint8 internal constant _FUND_DECIMALS = 18;

    /**
     * @notice Attempted to deploy contract without minting enough shares.
     */
    error Fund__MinimumConstructorMintNotMet();

    /**
     * @notice Address of the platform's registry contract. Used to get the latest address of modules.
     */
    Registry public immutable registry;

    uint8 internal immutable _ASSET_DECIMALS;

    /**
     * @notice Address of the fees manager contract.
     */
    FeesManager public immutable FEES_MANAGER;

    /**
     * @dev Owner should be set to the ProtocolDAO
     * @param _registry address of the platform's registry contract
     * @param _asset address of underlying token used for the for accounting, depositing, and withdrawing
     * @param _name name of this fund's share token
     * @param _symbol symbol of this fund's share token
     * @param _holdingPosition the holding position of the Fund
     *        must use a position that does NOT call back to fund on use(Like ERC20 positions).
     * @param _holdingPositionConfig configuration data for holding position
     * @param _initialDeposit initial amount of assets to deposit into the Fund
     * @param _shareSupplyCap starting share supply cap
     */
    constructor(
        address _owner,
        Registry _registry,
        ERC20 _asset,
        string memory _name,
        string memory _symbol,
        uint32 _holdingPosition,
        bytes memory _holdingPositionConfig,
        uint256 _initialDeposit,
        uint192 _shareSupplyCap
    ) ERC4626(_asset) ERC20(_name, _symbol, _FUND_DECIMALS) Ownable() {
        endPauseTimestamp = block.timestamp + _DELAY_UNTIL_END_PAUSE;
        registry = _registry;
        priceRouter = PriceRouter(_registry.getAddress(_PRICE_ROUTER_REGISTRY_SLOT));

        // Initialize holding position.
        addPositionToCatalogue(_holdingPosition);
        addPosition(0, _holdingPosition, _holdingPositionConfig, false);
        setHoldingPosition(_holdingPosition);

        // Update Share Supply Cap.
        shareSupplyCap = _shareSupplyCap;

        if (_initialDeposit < _MINIMUM_CONSTRUCTOR_MINT) revert Fund__MinimumConstructorMintNotMet();

        // Deposit into Fund, and mint shares to Deployer address.
        _asset.safeTransferFrom(_owner, address(this), _initialDeposit);
        // Set the share price as 1:1 * 10**(fund.decimals - asset.decimals) with underlying asset.
        _ASSET_DECIMALS = _asset.decimals(); // reverts if asset decimals > fund decimals
        _mint(msg.sender, _initialDeposit * (10 ** (_FUND_DECIMALS - _ASSET_DECIMALS)));
        // Deposit _initialDeposit into holding position.
        _depositTo(_holdingPosition, _initialDeposit);

        FEES_MANAGER = _registry.FEES_MANAGER();

        transferOwnership(_owner);
    }

    // =========================================== CORE LOGIC ===========================================

    /**
     * @notice Attempted an action with zero shares.
     */
    error Fund__ZeroShares();

    /**
     * @notice Attempted an action with zero assets.
     */
    error Fund__ZeroAssets();

    /**
     * @notice Withdraw did not withdraw all assets.
     * @param assetsOwed the remaining assets owed that were not withdrawn.
     */
    error Fund__IncompleteWithdraw(uint256 assetsOwed);

    /**
     * @notice called at the beginning of deposit.
     */
    function beforeDeposit(uint256, uint256, address) internal view virtual {
        _whenNotShutdown();
        _whenNotPaused();
    }

    /**
     * @notice called at the end of deposit.
     * @param assets amount of assets deposited by user.
     */
    function afterDeposit(uint256 assets, uint256, address) internal virtual {
        _depositTo(holdingPosition, assets);
    }

    /**
     * @notice called at the beginning of withdraw.
     */
    function beforeWithdraw(uint256, uint256, address, address) internal view virtual {
        _whenNotPaused();
    }

    /**
     * @notice Called when users enter the fund via deposit or mint.
     */
    function _enter(uint256 assets, uint256 shares, address receiver) internal {
        beforeDeposit(assets, shares, receiver);

        // Need to transfer before minting or ERC777s could reenter.
        asset.safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets, shares, receiver);
    }

    /**
     * @notice Deposits assets into the fund, and returns shares to receiver.
     * @param assets amount of assets deposited by user.
     * @param receiver address to receive the shares.
     * @return shares amount of shares given for deposit.
     */
    function deposit(uint256 assets, address receiver) public virtual override nonReentrant returns (uint256 shares) {
        // the total supply is the equivalent of total shares after applying the performance and management fees
        (uint256 _totalAssets, uint256 _totalSupply) = _collectFeesAndGetTotalAssetsAndTotalSupply(true);

        if ((shares = _convertToShares(assets, _totalAssets, _totalSupply)) == 0) revert Fund__ZeroShares();

        if ((_totalSupply + shares) > shareSupplyCap) revert Fund__ShareSupplyCapExceeded();

        _enter(assets, shares, receiver);
    }

    /**
     * @notice Mints shares from the fund, and returns shares to receiver.
     * @param shares amount of shares requested by user.
     * @param receiver address to receive the shares.
     * @return assets amount of assets deposited into the fund.
     */
    function mint(uint256 shares, address receiver) public virtual override nonReentrant returns (uint256 assets) {
        // the total supply is the equivalent of total shares after applying the performance and management fees
        (uint256 _totalAssets, uint256 _totalSupply) = _collectFeesAndGetTotalAssetsAndTotalSupply(true);

        // previewMint rounds up, but initial mint could return zero assets, so check for rounding error.
        if ((assets = _previewMint(shares, _totalAssets, _totalSupply)) == 0) revert Fund__ZeroAssets();

        if ((_totalSupply + shares) > shareSupplyCap) revert Fund__ShareSupplyCapExceeded();

        _enter(assets, shares, receiver);
    }

    /**
     * @notice Called when users exit the fund via withdraw or redeem.
     */
    function _exit(uint256 assets, uint256 shares, address receiver, address owner) internal {
        beforeWithdraw(assets, shares, receiver, owner);

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        _withdrawInOrder(assets, receiver);

        /// @notice `afterWithdraw` is currently not used.
        // afterWithdraw(assets, shares, receiver, owner);
    }

    /**
     * @notice Withdraw assets from the fund by redeeming shares.
     * @dev Unlike conventional ERC4626 contracts, this may not always return one asset to the receiver.
     *      Since there are no swaps involved in this function, the receiver may receive multiple
     *      assets. The value of all the assets returned will be equal to the amount defined by
     *      `assets` denominated in the `asset` of the fund (eg. if `asset` is USDC and `assets`
     *      is 1000, then the receiver will receive $1000 worth of assets in either one or many
     *      tokens).
     * @param assets equivalent value of the assets withdrawn, denominated in the fund's asset
     * @param receiver address that will receive withdrawn assets
     * @param owner address that owns the shares being redeemed
     * @return shares amount of shares redeemed
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256 shares) {
        // the total supply is the equivalent of total shares after applying the performance and management fees
        (uint256 _totalAssets, uint256 _totalSupply) = _collectFeesAndGetTotalAssetsAndTotalSupply(false);

        // No need to check for rounding error, `previewWithdraw` rounds up.
        shares = _previewWithdraw(assets, _totalAssets, _totalSupply);

        _exit(assets, shares, receiver, owner);
    }

    /**
     * @notice Redeem shares to withdraw assets from the fund.
     * @dev Unlike conventional ERC4626 contracts, this may not always return one asset to the receiver.
     *      Since there are no swaps involved in this function, the receiver may receive multiple
     *      assets. The value of all the assets returned will be equal to the amount defined by
     *      `assets` denominated in the `asset` of the fund (eg. if `asset` is USDC and `assets`
     *      is 1000, then the receiver will receive $1000 worth of assets in either one or many
     *      tokens).
     * @param shares amount of shares to redeem
     * @param receiver address that will receive withdrawn assets
     * @param owner address that owns the shares being redeemed
     * @return assets equivalent value of the assets withdrawn, denominated in the fund's asset
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256 assets) {
        // the total supply is the equivalent of total shares after applying the performance and management fees
        (uint256 _totalAssets, uint256 _totalSupply) = _collectFeesAndGetTotalAssetsAndTotalSupply(false);

        if ((assets = _convertToAssets(shares, _totalAssets, _totalSupply)) == 0) revert Fund__ZeroAssets();

        _exit(assets, shares, receiver, owner);
    }

    /**
     * @notice Called at the beginning of `previewDeposit`, `previewMint`, `previewWithdraw` and `previewRedeem`.
     * @return _totalAssets the virtual total assets in the fund after fees if any
     * @return _totalSupply the virtual total supply of shares after fees if any
     */
    function _previewTotalAssetsAndTotalSupplyAfterFees(
        bool _isEntering
    ) internal view virtual returns (uint256, uint256) {
        uint256 _totalAssets = _calculateTotalAssets();
        uint256 _totalSupply = totalSupply;

        if (isShutdown) {
            return (_totalAssets, _totalSupply);
        }

        (uint16 _enterOrExitFeesRate, uint256 _feesAsShares) = FEES_MANAGER.previewApplyFeesBeforeJoinExit(
            _totalAssets,
            _totalSupply,
            _isEntering
        );

        _totalAssets = _applyEnterOrExitFees(_totalAssets, _enterOrExitFeesRate, _isEntering);

        return (_totalAssets, _totalSupply + _feesAsShares);
    }

    /**
     * @notice Collect fees from the fund.
     * @dev Callable by anyone (permissionless).
     */
    function collectFees() external nonReentrant {
        _whenNotPaused();
        _collectFeesAndGetTotalAssetsAndTotalSupply(false);
    }

    /**
     * @notice Called at the beginning of `deposit`, `mint`, `withdraw` and `redeem`.
     * @dev This function is called before the fund applies fees.
     * @return _totalAssets the virtual total assets in the fund after enter or exit fees
     * @return _totalSupply the total supply of shares after management and performance fees
     */
    function _collectFeesAndGetTotalAssetsAndTotalSupply(bool _isEntering) internal virtual returns (uint256, uint256) {
        uint256 _totalAssets = _calculateTotalAssets();
        uint256 _totalSupply = totalSupply;

        if (isShutdown) {
            return (_totalAssets, _totalSupply);
        }

        try FEES_MANAGER.applyFeesBeforeJoinExit(_totalAssets, _totalSupply, _isEntering) returns (
            uint16 _enterOrExitFeesRate,
            uint256 _feesAsShares
        ) {
            if (_feesAsShares > 0) {
                _mint(address(FEES_MANAGER), _feesAsShares);
                _totalSupply += _feesAsShares;
            }

            _totalAssets = _applyEnterOrExitFees(_totalAssets, _enterOrExitFeesRate, _isEntering);

            return (_totalAssets, _totalSupply);
        } catch {
            // If fees fail to apply, return with 0 fees. (it should not happen in normal cases)
            return (_totalAssets, _totalSupply);
        }
    }

    uint16 internal constant _BPS_ONE_HUNDRED_PER_CENT = 1e4;

    /// @return virtualTotalAssets the virtual total assets after applying enter or exit fees
    function _applyEnterOrExitFees(
        uint256 _totalAssets,
        uint16 _enterOrExitFeeRate,
        bool _isEntering
    ) internal pure returns (uint256) {
        if (_enterOrExitFeeRate == 0) {
            return _totalAssets;
        }

        if (_isEntering) {
            return _totalAssets.mulDivUp(_BPS_ONE_HUNDRED_PER_CENT + _enterOrExitFeeRate, _BPS_ONE_HUNDRED_PER_CENT);
        }

        return _totalAssets.mulDivDown(_BPS_ONE_HUNDRED_PER_CENT - _enterOrExitFeeRate, _BPS_ONE_HUNDRED_PER_CENT);
    }

    /**
     * @notice Struct used in `_withdrawInOrder` in order to hold multiple pricing values in a single variable.
     * @dev Prevents stack too deep errors.
     */
    struct WithdrawPricing {
        uint256 priceBaseUSD;
        uint256 oneBase;
        uint256 priceQuoteUSD;
        uint256 oneQuote;
    }

    /**
     * @notice Multipler used to insure calculations use very high precision.
     */
    uint256 private constant PRECISION_MULTIPLIER = 1e18;

    /**
     * @dev Withdraw from positions in the order defined by `positions`.
     * @param assets the amount of assets to withdraw from fund
     * @param receiver the address to sent withdrawn assets to
     * @dev Only loop through credit array because debt can not be withdraw by users.
     */
    function _withdrawInOrder(uint256 assets, address receiver) internal {
        // Save asset price in USD, and decimals to reduce external calls.
        WithdrawPricing memory pricingInfo;
        pricingInfo.priceQuoteUSD = priceRouter.getPriceInUSD(asset);
        pricingInfo.oneQuote = 10 ** _ASSET_DECIMALS;
        uint256 creditLength = creditPositions.length;
        for (uint256 i; i < creditLength; ++i) {
            uint32 position = creditPositions[i];
            uint256 withdrawableBalance = _withdrawableFrom(position);
            // Move on to next position if this one is empty.
            if (withdrawableBalance == 0) continue;
            ERC20 positionAsset = _assetOf(position);

            pricingInfo.priceBaseUSD = priceRouter.getPriceInUSD(positionAsset);
            pricingInfo.oneBase = 10 ** positionAsset.decimals();
            uint256 totalWithdrawableBalanceInAssets;
            {
                uint256 withdrawableBalanceInUSD = (PRECISION_MULTIPLIER * withdrawableBalance).mulDivDown(
                    pricingInfo.priceBaseUSD,
                    pricingInfo.oneBase
                );
                totalWithdrawableBalanceInAssets = withdrawableBalanceInUSD.mulDivDown(
                    pricingInfo.oneQuote,
                    pricingInfo.priceQuoteUSD
                );
                totalWithdrawableBalanceInAssets = totalWithdrawableBalanceInAssets / PRECISION_MULTIPLIER;
            }

            // We want to pull as much as we can from this position, but no more than needed.
            uint256 amount;

            if (totalWithdrawableBalanceInAssets > assets) {
                // Convert assets into position asset.
                uint256 assetsInUSD = (PRECISION_MULTIPLIER * assets).mulDivDown(
                    pricingInfo.priceQuoteUSD,
                    pricingInfo.oneQuote
                );
                amount = assetsInUSD.mulDivDown(pricingInfo.oneBase, pricingInfo.priceBaseUSD);
                amount = amount / PRECISION_MULTIPLIER;
                assets = 0;
            } else {
                amount = withdrawableBalance;
                assets = assets - totalWithdrawableBalanceInAssets;
            }

            // Withdraw from position.
            _withdrawFrom(position, amount, receiver);

            // Stop if no more assets to withdraw.
            if (assets == 0) break;
        }
        // If withdraw did not remove all assets owed, revert.
        if (assets > 0) revert Fund__IncompleteWithdraw(assets);
    }

    // ========================================= ACCOUNTING LOGIC =========================================

    function _calculateTotalWithdrawableAssets() internal view returns (uint256 withdrawableAssets) {
        uint256 numOfCreditPositions = creditPositions.length;
        ERC20[] memory creditAssets = new ERC20[](numOfCreditPositions);
        uint256[] memory creditBalances = new uint256[](numOfCreditPositions);

        for (uint256 i; i < numOfCreditPositions; ++i) {
            uint32 position = creditPositions[i];
            // If the withdrawable balance is zero there is no point to query the asset since a zero balance has zero value.
            if ((creditBalances[i] = _withdrawableFrom(position)) == 0) continue;
            creditAssets[i] = _assetOf(position);
        }

        withdrawableAssets = priceRouter.getValues(creditAssets, creditBalances, asset);
    }

    function _calculateTotalAssets() internal view returns (uint256 assets) {
        (ERC20[] memory creditAssets, uint256[] memory creditBalances) = _getCreditOrDebtPositionsData(false);
        (ERC20[] memory debtAssets, uint256[] memory debtBalances) = _getCreditOrDebtPositionsData(true);

        assets = priceRouter.getValuesDelta(creditAssets, creditBalances, debtAssets, debtBalances, asset);
    }

    /**
     * @return _positionAssets the assets of the positions
     * @return _positionBalances the balances of the positions
     */
    function _getCreditOrDebtPositionsData(bool _isDebt) internal view returns (ERC20[] memory, uint256[] memory) {
        uint32[] memory _positions = _isDebt ? debtPositions : creditPositions;

        uint256 numOfPositions = _positions.length;
        ERC20[] memory _positionAssets = new ERC20[](numOfPositions);
        uint256[] memory _positionBalances = new uint256[](numOfPositions);

        for (uint256 i; i < numOfPositions; ++i) {
            uint32 position = _positions[i];
            // If the balance is zero there is no point to query the asset since a zero balance has zero value.
            if ((_positionBalances[i] = _balanceOf(position)) == 0) continue;
            _positionAssets[i] = _assetOf(position);
        }

        return (_positionAssets, _positionBalances);
    }

    /**
     * @notice The total amount of assets in the fund.
     * @dev EIP4626 states totalAssets needs to be inclusive of fees.
     * Since performance fees mint shares, total assets remains unchanged,
     * so this implementation is inclusive of fees even though it does not explicitly show it.
     * @dev EIP4626 states totalAssets must not revert, but it is possible for `totalAssets` to revert
     * so it does NOT conform to ERC4626 standards.
     * @dev Run a re-entrancy check because totalAssets can be wrong if re-entering from deposit/withdraws.
     */
    function totalAssets() public view override returns (uint256 assets) {
        _whenNotPaused();
        _revertWhenReentrant();
        assets = _calculateTotalAssets();
    }

    /**
     * @notice The total amount of withdrawable assets in the fund.
     * @dev Run a re-entrancy check because totalAssetsWithdrawable can be wrong if re-entering from deposit/withdraws.
     */
    function totalAssetsWithdrawable() public view returns (uint256 assets) {
        _whenNotPaused();
        _revertWhenReentrant();
        assets = _calculateTotalWithdrawableAssets();
    }

    /**
     * @notice The amount of assets that the fund would exchange for the amount of shares provided.
     * @dev Use preview functions to get accurate assets.
     * @dev Under estimates assets.
     * @param shares amount of shares to convert
     * @return assets the shares can be exchanged for
     */
    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return previewRedeem(shares);
    }

    /**
     * @notice The amount of shares that the fund would exchange for the amount of assets provided.
     * @dev Use preview functions to get accurate shares.
     * @dev Under estimates shares.
     * @param assets amount of assets to convert
     * @return shares the assets can be exchanged for
     */
    function convertToShares(uint256 assets) public view override returns (uint256 shares) {
        return previewDeposit(assets);
    }

    /**
     * @notice Simulate the effects of minting shares at the current block, given current on-chain conditions.
     * @param shares amount of shares to mint
     * @return assets that will be deposited
     */
    function previewMint(uint256 shares) public view override returns (uint256 assets) {
        (uint256 _totalAssets, uint256 _totalSupply) = _previewTotalAssetsAndTotalSupplyAfterFees(true);
        assets = _previewMint(shares, _totalAssets, _totalSupply);
    }

    /**
     * @notice Simulate the effects of withdrawing assets at the current block, given current on-chain conditions.
     * @param assets amount of assets to withdraw
     * @return shares that will be redeemed
     */
    function previewWithdraw(uint256 assets) public view override returns (uint256 shares) {
        (uint256 _totalAssets, uint256 _totalSupply) = _previewTotalAssetsAndTotalSupplyAfterFees(false);
        shares = _previewWithdraw(assets, _totalAssets, _totalSupply);
    }

    /**
     * @notice Simulate the effects of depositing assets at the current block, given current on-chain conditions.
     * @param assets amount of assets to deposit
     * @return shares that will be minted
     */
    function previewDeposit(uint256 assets) public view override returns (uint256 shares) {
        (uint256 _totalAssets, uint256 _totalSupply) = _previewTotalAssetsAndTotalSupplyAfterFees(true);
        shares = _convertToShares(assets, _totalAssets, _totalSupply);
    }

    /**
     * @notice Simulate the effects of redeeming shares at the current block, given current on-chain conditions.
     * @param shares amount of shares to redeem
     * @return assets that will be returned
     */
    function previewRedeem(uint256 shares) public view override returns (uint256 assets) {
        (uint256 _totalAssets, uint256 _totalSupply) = _previewTotalAssetsAndTotalSupplyAfterFees(false);
        assets = _convertToAssets(shares, _totalAssets, _totalSupply);
    }

    /**
     * @notice Finds the max amount of value an `owner` can remove from the fund.
     * @param owner address of the user to find max value.
     * @param inShares if false, then returns value in terms of assets
     *                 if true then returns value in terms of shares
     */
    function _findMax(address owner, bool inShares) internal view virtual returns (uint256 maxOut) {
        _whenNotPaused();
        // Get amount of assets to withdraw.
        (uint256 _totalAssets, uint256 _totalSupply) = _previewTotalAssetsAndTotalSupplyAfterFees(false);

        uint256 assets = _convertToAssets(balanceOf[owner], _totalAssets, _totalSupply);

        uint256 withdrawable = _calculateTotalWithdrawableAssets();
        maxOut = assets <= withdrawable ? assets : withdrawable;

        if (inShares) maxOut = _convertToShares(maxOut, _totalAssets, _totalSupply);
        // else leave maxOut in terms of assets.
    }

    /**
     * @notice Returns the max amount withdrawable by a user inclusive of performance fees
     * @dev EIP4626 states maxWithdraw must not revert, but it is possible for `totalAssets` to revert
     * so it does NOT conform to ERC4626 standards.
     * @param owner address to check maxWithdraw of.
     * @return the max amount of assets withdrawable by `owner`.
     */
    function maxWithdraw(address owner) public view override returns (uint256) {
        _revertWhenReentrant();
        return _findMax(owner, false);
    }

    /**
     * @notice Returns the max amount shares redeemable by a user
     * @dev EIP4626 states maxRedeem must not revert, but it is possible for `totalAssets` to revert
     * so it does NOT conform to ERC4626 standards.
     * @param owner address to check maxRedeem of.
     * @return the max amount of shares redeemable by `owner`.
     */
    function maxRedeem(address owner) public view override returns (uint256) {
        _revertWhenReentrant();
        return _findMax(owner, true);
    }

    /**
     * @dev Used to more efficiently convert amount of shares to assets using a stored `totalAssets` value.
     */
    function _convertToAssets(
        uint256 shares,
        uint256 _totalAssets,
        uint256 _totalSupply
    ) internal pure returns (uint256 assets) {
        assets = shares.mulDivDown(_totalAssets, _totalSupply);
    }

    /**
     * @dev Used to more efficiently convert amount of assets to shares using a stored `totalAssets` value.
     */
    function _convertToShares(
        uint256 assets,
        uint256 _totalAssets,
        uint256 _totalSupply
    ) internal pure returns (uint256 shares) {
        shares = assets.mulDivDown(_totalSupply, _totalAssets);
    }

    /**
     * @dev Used to more efficiently simulate minting shares using a stored `totalAssets` value.
     */
    function _previewMint(
        uint256 shares,
        uint256 _totalAssets,
        uint256 _totalSupply
    ) internal pure returns (uint256 assets) {
        assets = shares.mulDivUp(_totalAssets, _totalSupply);
    }

    /**
     * @dev Used to more efficiently simulate withdrawing assets using a stored `totalAssets` value.
     */
    function _previewWithdraw(
        uint256 assets,
        uint256 _totalAssets,
        uint256 _totalSupply
    ) internal pure returns (uint256 shares) {
        shares = assets.mulDivUp(_totalSupply, _totalAssets);
    }

    //cap =========================================== AUTOMATION ACTIONS LOGIC ===========================================

    /**
     * Emitted when sender is not approved to call `callOnAdaptor`.
     */
    error Fund__CallerNotApprovedToRebalance();

    /**
     * @notice Emitted when `setAutomationActions` is called.
     */
    event Fund__AutomationActionsUpdated(address indexed newAutomationActions);

    /**
     * @notice The Automation Actions contract that can rebalance this Fund.
     * @dev Set to zero address if not in use.
     */
    address public automationActions;

    /**
     * @notice Set the Automation Actions contract.
     * @param _registryId Registry Id to get the automation action.
     * @param _expectedAutomationActions The registry automation actions differed from the expected automation actions.
     * @dev Callable by the Fund's owner.
     */
    function setAutomationActions(uint256 _registryId, address _expectedAutomationActions) external onlyOwner {
        _checkRegistryAddressAgainstExpected(_registryId, _expectedAutomationActions);
        automationActions = _expectedAutomationActions;
        emit Fund__AutomationActionsUpdated(_expectedAutomationActions);
    }

    // =========================================== ADAPTOR LOGIC ===========================================

    /**
     * @notice Emitted on when the rebalance deviation is changed.
     * @param oldDeviation the old rebalance deviation
     * @param newDeviation the new rebalance deviation
     */
    event RebalanceDeviationChanged(uint256 oldDeviation, uint256 newDeviation);

    /**
     * @notice totalAssets deviated outside the range set by `allowedRebalanceDeviation`.
     * @param assets the total assets in the fund
     * @param min the minimum allowed assets
     * @param max the maximum allowed assets
     */
    error Fund__TotalAssetDeviatedOutsideRange(uint256 assets, uint256 min, uint256 max);

    /**
     * @notice Total shares in a fund changed when they should stay constant.
     * @param current the current amount of total shares
     * @param expected the expected amount of total shares
     */
    error Fund__TotalSharesMustRemainConstant(uint256 current, uint256 expected);

    /**
     * @notice Total shares in a fund changed when they should stay constant.
     * @param requested the requested rebalance  deviation
     * @param max the max rebalance deviation.
     */
    error Fund__InvalidRebalanceDeviation(uint256 requested, uint256 max);

    /**
     * @notice CallOnAdaptor attempted to use an adaptor that is either paused or is not trusted by the Fund.
     * @param adaptor the adaptor address that is paused or not trusted.
     */
    error Fund__CallToAdaptorNotAllowed(address adaptor);

    /**
     * @notice Stores the max possible rebalance deviation for this fund.
     */
    uint256 public constant MAX_REBALANCE_DEVIATION = 0.1e18;

    /**
     * @notice The percent the total assets of a fund may deviate during a `callOnAdaptor`(rebalance) call.
     */
    uint256 public allowedRebalanceDeviation = 0.0003e18;

    /**
     * @notice Allows owner to change this funds rebalance deviation.
     * @param newDeviation the new rebalance deviation value.
     * @dev Callable by the Fund's owner.
     */
    function setRebalanceDeviation(uint256 newDeviation) external onlyOwner {
        if (newDeviation > MAX_REBALANCE_DEVIATION)
            revert Fund__InvalidRebalanceDeviation(newDeviation, MAX_REBALANCE_DEVIATION);

        uint256 oldDeviation = allowedRebalanceDeviation;
        allowedRebalanceDeviation = newDeviation;

        emit RebalanceDeviationChanged(oldDeviation, newDeviation);
    }

    /**
     * @notice Struct used to make calls to adaptors.
     * @param adaptor the address of the adaptor to make calls to
     * @param the abi encoded function calls to make to the `adaptor`
     */
    struct AdaptorCall {
        address adaptor;
        bytes[] callData;
    }

    /**
     * @notice Emitted when adaptor calls are made.
     */
    event AdaptorCalled(address indexed adaptor, bytes data);

    /**
     * @notice Internal helper function that accepts an Adaptor Call array, and makes calls to each adaptor.
     */
    function _makeAdaptorCalls(AdaptorCall[] memory data) internal {
        for (uint256 i; i < data.length; ++i) {
            address adaptor = data[i].adaptor;
            // Revert if adaptor not in catalogue, or adaptor is paused.
            if (!adaptorCatalogue[adaptor]) revert Fund__CallToAdaptorNotAllowed(adaptor);
            for (uint256 j; j < data[i].callData.length; ++j) {
                adaptor.functionDelegateCall(data[i].callData[j]);
                emit AdaptorCalled(adaptor, data[i].callData[j]);
            }
        }
    }

    /**
     * @notice Allows owner or Automation Actions to manage the Fund using arbitrary logic calls to trusted adaptors.
     * @dev There are several safety checks in this function to prevent rebalancers from abusing it.
     *      - `blockExternalReceiver`
     *      - `totalAssets` must not change by much
     *      - `totalShares` must remain constant
     *      - adaptors must be set up to be used with this fund
     * @dev Since `totalAssets` is allowed to deviate slightly, rebalancers could abuse this by sending
     *      multiple `callOnAdaptor` calls rapidly, to gradually change the share price (for example when swapping unfairly).
     *      To mitigate this, a Fund can be limited in the total volume that can be done in a period of time by the Registry.
     * @dev Callable by the Fund's owner, and Automation Actions address.
     */
    function callOnAdaptor(AdaptorCall[] calldata data) external virtual nonReentrant {
        if (msg.sender != owner() && msg.sender != automationActions) revert Fund__CallerNotApprovedToRebalance();
        _whenNotShutdown();
        _whenNotPaused();
        blockExternalReceiver = true;

        // Record `totalAssets` and `totalShares` before making any external calls.
        uint256 minimumAllowedAssets;
        uint256 maximumAllowedAssets;
        uint256 totalShares;
        {
            uint256 assetsBeforeAdaptorCall = _calculateTotalAssets();
            minimumAllowedAssets = assetsBeforeAdaptorCall.mulDivUp((1e18 - allowedRebalanceDeviation), 1e18);
            maximumAllowedAssets = assetsBeforeAdaptorCall.mulDivUp((1e18 + allowedRebalanceDeviation), 1e18);
            totalShares = totalSupply;
        }

        // Run all adaptor calls.
        _makeAdaptorCalls(data);

        // After making every external call, check that the totalAssets has not deviated significantly, and that totalShares is the same.
        uint256 assets = _calculateTotalAssets();
        if (assets < minimumAllowedAssets || assets > maximumAllowedAssets) {
            revert Fund__TotalAssetDeviatedOutsideRange(assets, minimumAllowedAssets, maximumAllowedAssets);
        }
        if (totalShares != totalSupply) revert Fund__TotalSharesMustRemainConstant(totalSupply, totalShares);

        blockExternalReceiver = false;
    }

    // ============================================ LIMITS LOGIC ============================================

    /**
     * @notice Attempted entry would raise totalSupply above Share Supply Cap.
     */
    error Fund__ShareSupplyCapExceeded();

    event ShareSupplyCapChanged(uint192 newShareSupplyCap);

    /**
     * @notice Increases the share supply cap.
     * @dev Callable by the Fund's owner.
     */
    function setShareSupplyCap(uint192 _newShareSupplyCap) public onlyOwner {
        shareSupplyCap = _newShareSupplyCap;
        emit ShareSupplyCapChanged(_newShareSupplyCap);
    }

    /**
     * @notice Total amount of assets that can be deposited for a user.
     * @return assets maximum amount of assets that can be deposited
     */
    function maxDeposit(address) public view override returns (uint256) {
        if (isShutdown) return 0;

        uint192 _cap = shareSupplyCap;
        if (_cap == type(uint192).max) return type(uint256).max;

        (uint256 _totalAssets, uint256 _totalSupply) = _previewTotalAssetsAndTotalSupplyAfterFees(true);

        if (_totalSupply >= _cap) return 0;
        else {
            uint256 shareDelta = _cap - _totalSupply;
            return _convertToAssets(shareDelta, _totalAssets, _totalSupply);
        }
    }

    /**
     * @notice Total amount of shares that can be minted for a user.
     * @return shares maximum amount of shares that can be minted
     */
    function maxMint(address) public view override returns (uint256) {
        if (isShutdown) return 0;

        uint192 _cap;
        if ((_cap = shareSupplyCap) == type(uint192).max) return type(uint256).max;

        uint256 _totalSupply = totalSupply;

        return _totalSupply >= _cap ? 0 : _cap - _totalSupply;
    }

    // ========================================== HELPER FUNCTIONS ==========================================

    /**
     * @dev Deposit into a position according to its position type and update related state.
     * @param position address to deposit funds into
     * @param assets the amount of assets to deposit into the position
     */
    function _depositTo(uint32 position, uint256 assets) internal {
        address adaptor = getPositionData[position].adaptor;
        adaptor.functionDelegateCall(
            abi.encodeWithSelector(
                BaseAdaptor.deposit.selector,
                assets,
                getPositionData[position].adaptorData,
                getPositionData[position].configurationData
            )
        );
    }

    /**
     * @dev Withdraw from a position according to its position type and update related state.
     * @param position address to withdraw funds from
     * @param assets the amount of assets to withdraw from the position
     * @param receiver the address to sent withdrawn assets to
     */
    function _withdrawFrom(uint32 position, uint256 assets, address receiver) internal {
        address adaptor = getPositionData[position].adaptor;
        adaptor.functionDelegateCall(
            abi.encodeWithSelector(
                BaseAdaptor.withdraw.selector,
                assets,
                receiver,
                getPositionData[position].adaptorData,
                getPositionData[position].configurationData
            )
        );
    }

    /**
     * @dev Get the withdrawable balance of a position according to its position type.
     * @param position position to get the withdrawable balance of
     */
    function _withdrawableFrom(uint32 position) internal view returns (uint256) {
        // Debt positions always return 0 for their withdrawable.
        if (getPositionData[position].isDebt) return 0;
        return
            BaseAdaptor(getPositionData[position].adaptor).withdrawableFrom(
                getPositionData[position].adaptorData,
                getPositionData[position].configurationData
            );
    }

    /**
     * @dev Get the balance of a position according to its position type.
     * @dev For ERC4626 position balances, this uses `previewRedeem` as opposed
     *      to `convertToAssets` so that balanceOf ERC4626 positions includes fees taken on withdraw.
     * @param position position to get the balance of
     */
    function _balanceOf(uint32 position) internal view returns (uint256) {
        address adaptor = getPositionData[position].adaptor;
        return BaseAdaptor(adaptor).balanceOf(getPositionData[position].adaptorData);
    }

    /**
     * @dev Get the asset of a position according to its position type.
     * @param position to get the asset of
     */
    function _assetOf(uint32 position) internal view returns (ERC20) {
        address adaptor = getPositionData[position].adaptor;
        return BaseAdaptor(adaptor).assetOf(getPositionData[position].adaptorData);
    }

    /**
     * @notice Attempted to use an address from the registry, but address was not expected.
     */
    error Fund__ExpectedAddressDoesNotMatchActual();

    /**
     * @notice Attempted to set an address to registry Id 0.
     */
    error Fund__SettingValueToRegistryIdZeroIsProhibited();

    /**
     * @notice Verify that `_registryId` in registry corresponds to expected address.
     */
    function _checkRegistryAddressAgainstExpected(uint256 _registryId, address _expected) internal view {
        if (_registryId == 0) revert Fund__SettingValueToRegistryIdZeroIsProhibited();
        if (registry.getAddress(_registryId) != _expected) revert Fund__ExpectedAddressDoesNotMatchActual();
    }

    /**
     * @notice View the amount of assets in each Fund Position.
     */
    function viewPositionBalances()
        external
        view
        returns (ERC20[] memory assets, uint256[] memory balances, bool[] memory isDebt)
    {
        uint256 creditLen = creditPositions.length;
        uint256 debtLen = debtPositions.length;
        uint256 totalLen = creditLen + debtLen;
        assets = new ERC20[](totalLen);
        balances = new uint256[](totalLen);
        isDebt = new bool[](totalLen);
        for (uint256 i; i < creditLen; ++i) {
            assets[i] = _assetOf(creditPositions[i]);
            balances[i] = _balanceOf(creditPositions[i]);
            isDebt[i] = false;
        }

        for (uint256 i; i < debtLen; ++i) {
            // uint256 index;
            uint256 index = i + creditLen;
            assets[index] = _assetOf(debtPositions[i]);
            balances[index] = _balanceOf(debtPositions[i]);
            isDebt[index] = true;
        }
    }
}
