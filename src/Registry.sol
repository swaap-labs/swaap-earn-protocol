// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Fund } from "src/base/Fund.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { BaseAdaptor } from "src/modules/adaptors/BaseAdaptor.sol";
import { PriceRouter } from "src/modules/price-router/PriceRouter.sol";
import { FeesManager } from "src/modules/fees/FeesManager.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

contract Registry is Ownable {
    using Address for address;
    // ============================================= ADDRESS CONFIG =============================================

    /**
     * @notice Emitted when the address of a contract is changed.
     * @param id value representing the unique ID tied to the changed contract
     * @param oldAddress address of the contract before the change
     * @param newAddress address of the contract after the contract
     */
    event AddressChanged(uint256 indexed id, address oldAddress, address newAddress);

    /**
     * @notice Attempted to set the address of a contract that is not registered.
     * @param id id of the contract that is not registered
     */
    error Registry__ContractNotRegistered(uint256 id);

    /**
     * @notice Emitted when depositor privilege changes.
     * @param depositor depositor address
     * @param state the new state of the depositor privilege
     */
    event DepositorOnBehalfChanged(address indexed depositor, bool state);

    /**
     * @notice The unique ID that the next registered contract will have.
     */
    uint256 public nextId;

    /**
     * @notice Get the address associated with an id.
     */
    mapping(uint256 => address) public getAddress;

    /**
     * @notice In order for an address to make deposits on behalf of users they must be approved.
     */
    mapping(address => bool) public approvedForDepositOnBehalf;

    FeesManager public immutable FEES_MANAGER;

    /**
     * @notice Allows caller to call multiple functions in a single TX.
     * @dev Does NOT return the function return values.
     */
    function multicall(bytes[] calldata data) external {
        for (uint256 i; i < data.length; ++i) address(this).functionDelegateCall(data[i]);
    }

    /**
     * @notice toggles a depositors  ability to deposit into funds on behalf of users.
     */
    function setApprovedForDepositOnBehalf(address depositor, bool state) external onlyOwner {
        approvedForDepositOnBehalf[depositor] = state;
        emit DepositorOnBehalfChanged(depositor, state);
    }

    /**
     * @notice Set the address of the contract at a given id.
     */
    function setAddress(uint256 id, address newAddress) external {
        if (id > 0) {
            _checkOwner();
            if (id >= nextId) revert Registry__ContractNotRegistered(id);
        } else {
            if (msg.sender != getAddress[0]) revert Registry__OnlyCallableByZeroId();
        }

        emit AddressChanged(id, getAddress[id], newAddress);

        getAddress[id] = newAddress;
    }

    // ============================================= INITIALIZATION =============================================

    /**
     * @param protocolDAO address of ProtocolDAO contract
     * @param swapRouter address of SwapRouter contract
     * @param priceRouter address of PriceRouter contract
     */
    constructor(address newOwner, address protocolDAO, address swapRouter, address priceRouter) Ownable() {
        _register(protocolDAO);
        _register(swapRouter);
        _register(priceRouter);
        FEES_MANAGER = new FeesManager(address(this), newOwner);
        transferOwnership(newOwner);
    }

    // ============================================ REGISTER CONFIG ============================================

    /**
     * @notice Emitted when a new contract is registered.
     * @param id value representing the unique ID tied to the new contract
     * @param newContract address of the new contract
     */
    event Registered(uint256 indexed id, address indexed newContract);

    /**
     * @notice Register the address of a new contract.
     * @param newContract address of the new contract to register
     */
    function register(address newContract) external onlyOwner {
        _register(newContract);
    }

    function _register(address newContract) internal {
        getAddress[nextId] = newContract;

        emit Registered(nextId, newContract);

        nextId++;
    }

    // ============================================= ADDRESS 0 LOGIC =============================================
    /**
     * Address 0 is the address of the ProtocolDAO, and special abilities that the owner does not have.
     * - It can change what address is stored at address 0.
     * - It can change the owner of this contract.
     */

    /**
     * @notice Emitted when an ownership transition is started.
     */
    event OwnerTransitionStarted(address indexed pendingOwner, uint256 startTime);

    /**
     * @notice Emitted when an ownership transition is cancelled.
     */
    event OwnerTransitionCancelled(address indexed pendingOwner);

    /**
     * @notice Emitted when an ownership transition is completed.
     */
    event OwnerTransitionComplete(address indexed newOwner);

    /**
     * @notice Attempted to call a function intended for Zero Id address.
     */
    error Registry__OnlyCallableByZeroId();

    /**
     * @notice Attempted to transition owner to the zero address.
     */
    error Registry__NewOwnerCanNotBeZero();

    /**
     * @notice Attempted to perform a restricted action while ownership transition is pending.
     */
    error Registry__TransitionPending();

    /**
     * @notice Attempted to cancel or complete a transition when one is not active.
     */
    error Registry__TransitionNotPending();

    /**
     * @notice Attempted to call `completeTransition` from an address that is not the pending owner.
     */
    error Registry__OnlyCallableByPendingOwner();

    /**
     * @notice The amount of time it takes for an ownership transition to work.
     */
    uint256 public constant TRANSITION_PERIOD = 7 days;

    /**
     * @notice The Pending Owner, that becomes the owner after the transition period, and they call `completeTransition`.
     */
    address public pendingOwner;

    /**
     * @notice The starting time stamp of the transition.
     */
    uint256 public transitionStart;

    /**
     * @notice Allows Zero Id address to set a new owner, after the transition period is up.
     */
    function transitionOwner(address newOwner) external {
        if (msg.sender != getAddress[0]) revert Registry__OnlyCallableByZeroId();
        if (pendingOwner != address(0)) revert Registry__TransitionPending();
        if (newOwner == address(0)) revert Registry__NewOwnerCanNotBeZero();

        emit OwnerTransitionStarted(newOwner, transitionStart);

        pendingOwner = newOwner;
        transitionStart = block.timestamp;
    }

    /**
     * @notice Allows Zero Id address to cancel an ongoing owner transition.
     */
    function cancelTransition() external {
        address _pendingOwner = pendingOwner;

        if (msg.sender != getAddress[0]) revert Registry__OnlyCallableByZeroId();
        if (_pendingOwner == address(0)) revert Registry__TransitionNotPending();

        emit OwnerTransitionCancelled(_pendingOwner);

        pendingOwner = address(0);
        transitionStart = 0;
    }

    /**
     * @notice Allows pending owner to complete the ownership transition.
     */
    function completeTransition() external {
        address _pendingOwner = pendingOwner;

        if (msg.sender != _pendingOwner) revert Registry__OnlyCallableByPendingOwner();
        if (block.timestamp < transitionStart + TRANSITION_PERIOD) revert Registry__TransitionPending();

        _transferOwnership(_pendingOwner);

        emit OwnerTransitionComplete(_pendingOwner);

        pendingOwner = address(0);
        transitionStart = 0;
    }

    /**
     * @notice Extends OZ Ownable `_checkOwner` function to block owner calls, if there is an ongoing transition.
     */
    function _checkOwner() internal view override {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        if (transitionStart != 0) revert Registry__TransitionPending();
    }

    // ============================================ PAUSE LOGIC ============================================

    /**
     * @notice Emitted when a target is paused.
     */
    event TargetPaused(address indexed target);

    /**
     * @notice Emitted when a target is unpaused.
     */
    event TargetUnpaused(address indexed target);

    /**
     * @notice Attempted to unpause a target that was not paused.
     */
    error Registry__TargetNotPaused(address target);

    /**
     * @notice Mapping stores whether or not a fund is paused.
     */
    mapping(address => bool) public isCallerPaused;

    /**
     * @notice Allows multisig to pause multiple funds in a single call.
     */
    function batchPause(address[] calldata targets) external onlyOwner {
        for (uint256 i; i < targets.length; ++i) _pauseTarget(targets[i]);
    }

    /**
     * @notice Allows multisig to unpause multiple funds in a single call.
     */
    function batchUnpause(address[] calldata targets) external onlyOwner {
        for (uint256 i; i < targets.length; ++i) _unpauseTarget(targets[i]);
    }

    /**
     * @notice Helper function to pause some target.
     */
    function _pauseTarget(address target) internal {
        isCallerPaused[target] = true;
        emit TargetPaused(target);
    }

    /**
     * @notice Helper function to unpause some target.
     */
    function _unpauseTarget(address target) internal {
        if (!isCallerPaused[target]) revert Registry__TargetNotPaused(target);
        isCallerPaused[target] = false;
        emit TargetUnpaused(target);
    }

    // ============================================ ADAPTOR LOGIC ============================================

    /**
     * @notice Emitted when an adaptor is trusted.
     * @param adaptor address of the trusted adaptor
     */
    event Registry__AdaptorTrusted(address indexed adaptor);

    /**
     * @notice Emitted when an adaptor is not trusted.
     * @param adaptor address of the distrusted adaptor
     */
    event Registry__AdaptorDistrusted(address indexed adaptor);

    /**
     * @notice Attempted to trust an adaptor with non unique identifier.
     */
    error Registry__IdentifierNotUnique();

    /**
     * @notice Attempted to use an untrusted adaptor.
     */
    error Registry__AdaptorNotTrusted(address adaptor);

    /**
     * @notice Attempted to trust an already trusted adaptor.
     */
    error Registry__AdaptorAlreadyTrusted(address adaptor);

    /**
     * @notice Maps an adaptor address to bool indicating whether it has been set up in the registry.
     */
    mapping(address => bool) public isAdaptorTrusted;

    /**
     * @notice Maps an adaptors identfier to bool, to track if the identifier is unique wrt the registry.
     */
    mapping(bytes32 => bool) public isIdentifierUsed;

    /**
     * @notice Trust an adaptor to be used by funds
     * @param adaptor address of the adaptor to trust
     */
    function trustAdaptor(address adaptor) external onlyOwner {
        if (isAdaptorTrusted[adaptor]) revert Registry__AdaptorAlreadyTrusted(adaptor);
        bytes32 identifier = BaseAdaptor(adaptor).identifier();
        if (isIdentifierUsed[identifier]) revert Registry__IdentifierNotUnique();
        isAdaptorTrusted[adaptor] = true;
        isIdentifierUsed[identifier] = true;
        emit Registry__AdaptorTrusted(adaptor);
    }

    /**
     * @notice Allows registry to distrust adaptors.
     * @dev Doing so prevents Funds from adding this adaptor to their catalogue.
     */
    function distrustAdaptor(address adaptor) external onlyOwner {
        if (!isAdaptorTrusted[adaptor]) revert Registry__AdaptorNotTrusted(adaptor);
        // Set trust to false.
        isAdaptorTrusted[adaptor] = false;

        emit Registry__AdaptorDistrusted(adaptor);

        // We are NOT resetting `isIdentifierUsed` because if this adaptor is distrusted, then something needs
        // to change about the new one being re-trusted.
    }

    /**
     * @notice Reverts if `adaptor` is not trusted by the registry.
     */
    function revertIfAdaptorIsNotTrusted(address adaptor) external view {
        if (!isAdaptorTrusted[adaptor]) revert Registry__AdaptorNotTrusted(adaptor);
    }

    // ============================================ POSITION LOGIC ============================================
    /**
     * @notice stores data related to Fund positions.
     * @param adaptors address of the adaptor to use for this position
     * @param isDebt bool indicating whether this position takes on debt or not
     * @param adaptorData arbitrary data needed to correclty set up a position
     * @param configurationData arbitrary data settable by strategist to change fund <-> adaptor interaction
     */
    struct PositionData {
        address adaptor;
        bool isDebt;
        bytes adaptorData;
        bytes configurationData;
    }

    /**
     * @notice Emitted when a new position is added to the registry.
     * @param id the positions id
     * @param adaptor address of the adaptor this position uses
     * @param isDebt bool indicating whether this position takes on debt or not
     * @param adaptorData arbitrary bytes used to configure this position
     */
    event Registry__PositionTrusted(uint32 indexed id, address indexed adaptor, bool isDebt, bytes adaptorData);

    /**
     * @notice Emitted when a position is distrusted.
     * @param id the positions id
     */
    event Registry__PositionDistrusted(uint32 indexed id);

    /**
     * @notice Attempted to trust a position not being used.
     * @param position address of the invalid position
     */
    error Registry__PositionPricingNotSetUp(address position);

    /**
     * @notice Attempted to add a position with bad input values.
     */
    error Registry__InvalidPositionInput();

    /**
     * @notice Attempted to add a position that does not exist.
     */
    error Registry__PositionDoesNotExist();

    /**
     * @notice Attempted to add a position that is not trusted.
     */
    error Registry__PositionIsNotTrusted(uint32 position);

    /**
     * @notice Addresses of the positions currently used by the fund.
     */
    uint256 public constant PRICE_ROUTER_REGISTRY_SLOT = 2;

    /**
     * @notice Maps a position hash to a position Id.
     * @dev can be used by adaptors to verify that a certain position is open during Fund `callOnAdaptor` calls.
     */
    mapping(bytes32 => uint32) public getPositionHashToPositionId;

    /**
     * @notice Maps a position id to its position data.
     * @dev used by Funds when adding new positions.
     */
    mapping(uint32 => PositionData) public getPositionIdToPositionData;

    /**
     * @notice Maps a position to a bool indicating whether or not it is trusted.
     */
    mapping(uint32 => bool) public isPositionTrusted;

    /**
     * @notice Trust a position to be used by the fund.
     * @param positionId the position id of the newly added position
     * @param adaptor the adaptor address this position uses
     * @param adaptorData arbitrary bytes used to configure this position
     */
    function trustPosition(uint32 positionId, address adaptor, bytes memory adaptorData) external onlyOwner {
        bytes32 identifier = BaseAdaptor(adaptor).identifier();
        bool isDebt = BaseAdaptor(adaptor).isDebt();
        bytes32 positionHash = keccak256(abi.encode(identifier, isDebt, adaptorData));

        if (positionId == 0) revert Registry__InvalidPositionInput();
        // Make sure positionId is not already in use.
        PositionData storage pData = getPositionIdToPositionData[positionId];
        if (pData.adaptor != address(0)) revert Registry__InvalidPositionInput();

        // Check that...
        // `adaptor` is a non zero address
        // position has not been already set up
        if (adaptor == address(0) || getPositionHashToPositionId[positionHash] != 0)
            revert Registry__InvalidPositionInput();

        if (!isAdaptorTrusted[adaptor]) revert Registry__AdaptorNotTrusted(adaptor);

        // Set position data.
        pData.adaptor = adaptor;
        pData.isDebt = isDebt;
        pData.adaptorData = adaptorData;
        pData.configurationData = abi.encode(0);

        // Globally trust the position.
        isPositionTrusted[positionId] = true;

        getPositionHashToPositionId[positionHash] = positionId;

        // Check that assets position uses are supported for pricing operations.
        ERC20[] memory assets = BaseAdaptor(adaptor).assetsUsed(adaptorData);
        PriceRouter priceRouter = PriceRouter(getAddress[PRICE_ROUTER_REGISTRY_SLOT]);
        for (uint256 i; i < assets.length; ++i) {
            if (!priceRouter.isSupported(assets[i])) revert Registry__PositionPricingNotSetUp(address(assets[i]));
        }

        emit Registry__PositionTrusted(positionId, adaptor, isDebt, adaptorData);
    }

    /**
     * @notice Allows registry to distrust positions.
     * @dev Doing so prevents Funds from adding this position to their catalogue,
     *      and adding the position to their tracked arrays.
     */
    function distrustPosition(uint32 positionId) external onlyOwner {
        if (!isPositionTrusted[positionId]) revert Registry__PositionIsNotTrusted(positionId);
        isPositionTrusted[positionId] = false;
        emit Registry__PositionDistrusted(positionId);
    }

    /**
     * @notice Called by Funds to add a new position to themselves.
     * @param positionId the id of the position the fund wants to add
     * @return adaptor the address of the adaptor, isDebt bool indicating whether position is
     *         debt or not, and adaptorData needed to interact with position
     */
    function addPositionToFund(
        uint32 positionId
    ) external view returns (address adaptor, bool isDebt, bytes memory adaptorData) {
        if (positionId == 0) revert Registry__PositionDoesNotExist();
        PositionData memory positionData = getPositionIdToPositionData[positionId];
        if (positionData.adaptor == address(0)) revert Registry__PositionDoesNotExist();

        revertIfPositionIsNotTrusted(positionId);

        return (positionData.adaptor, positionData.isDebt, positionData.adaptorData);
    }

    /**
     * @notice Reverts if `positionId` is not trusted by the registry.
     */
    function revertIfPositionIsNotTrusted(uint32 positionId) public view {
        if (!isPositionTrusted[positionId]) revert Registry__PositionIsNotTrusted(positionId);
    }

    // ========================================== LIMIT ADAPTOR SWAP VOLUME LOGIC ==========================================

    event FundTradeVolumeDataUpdated(
        address indexed fund,
        uint48 lastUpdate,
        uint48 periodLength,
        uint80 volumeInUSD,
        uint80 maxVolumeInUSD
    );

    error Registry__FundTradingVolumeExceeded(address fund);
    error Registry__InvalidVolumeInput();

    struct FundVolumeData {
        uint48 lastUpdate;
        uint48 periodLength;
        uint80 volumeInUSD; // volume per period in USD and 8 decimals (80 bits are largely sufficient)
        uint80 maxVolumeInUSD; // volume per period in USD and 8 decimals (80 bits are largely sufficient)
    }

    mapping(address => FundVolumeData) public fundsAdaptorVolumeData;

    /**
     * @notice Updates and checks if the fund's traded volume is violated.
     * @param volumeInUSD the volume in USD to add to the fund's traded volume.
     * @dev If the fund volume parameters were not set, the fund won't be able to trade on reblances.
     */
    function checkAndUpdateFundTradeVolume(uint256 volumeInUSD) external {
        // caller should be the fund through the swap adapters
        FundVolumeData storage fundVolumeData = fundsAdaptorVolumeData[msg.sender];

        if (fundVolumeData.maxVolumeInUSD == type(uint80).max) return;

        // input sanity check
        if (volumeInUSD > type(uint80).max) revert Registry__InvalidVolumeInput();

        uint256 endPeriod;
        unchecked {
            endPeriod = uint256(fundVolumeData.lastUpdate) + uint256(fundVolumeData.periodLength);
        }

        if (block.timestamp > endPeriod) {
            fundVolumeData.lastUpdate = uint48(block.timestamp);
            fundVolumeData.volumeInUSD = uint80(volumeInUSD);
        } else {
            fundVolumeData.volumeInUSD += uint80(volumeInUSD);
        }

        if (fundVolumeData.volumeInUSD > fundVolumeData.maxVolumeInUSD)
            revert Registry__FundTradingVolumeExceeded(msg.sender);

        emit FundTradeVolumeDataUpdated(
            msg.sender,
            fundVolumeData.lastUpdate,
            fundVolumeData.periodLength,
            fundVolumeData.volumeInUSD,
            fundVolumeData.maxVolumeInUSD
        );
    }

    /**
     * @notice Set the max allowed volume for an adaptor to trade in a period.
     * @param fund the address of the fund
     * @param periodLength the length of the period in seconds
     * @param maxVolumeInUSD the max volume an adaptor can trade in a period
     * @param resetVolume reset or not the current volume an adaptor has traded
     */
    function setMaxAllowedAdaptorVolumeParams(
        address fund,
        uint48 periodLength,
        uint80 maxVolumeInUSD,
        bool resetVolume
    ) external onlyOwner {
        // there is no explicit limit on volume since it can depend on the size of the fund,
        // as well as the strategies involved
        FundVolumeData storage fundVolumeData = fundsAdaptorVolumeData[fund];
        fundVolumeData.periodLength = periodLength;
        fundVolumeData.maxVolumeInUSD = maxVolumeInUSD;

        if (resetVolume) {
            fundVolumeData.lastUpdate = uint48(block.timestamp);
            fundVolumeData.volumeInUSD = 0;
        }

        emit FundTradeVolumeDataUpdated(
            fund,
            fundVolumeData.lastUpdate,
            periodLength,
            fundVolumeData.volumeInUSD,
            maxVolumeInUSD
        );
    }
}
