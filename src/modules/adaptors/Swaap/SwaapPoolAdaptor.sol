// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BaseAdaptor, ERC20, SafeTransferLib, Cellar, Registry, PriceRouter } from "src/modules/adaptors/BaseAdaptor.sol";
import { IVault, IERC20, IAsset, IFlashLoanRecipient } from "src/interfaces/external/Balancer/IVault.sol";
import { IBasePool } from "src/interfaces/external/Balancer/typically-npm/IBasePool.sol";
import { Math } from "src/utils/Math.sol";

/**
 * @title Swaap Pool Adaptor
 * @notice Allows Cellars to interact with Swaap Safeguard Pools.
 */
contract SwaapPoolAdaptor is BaseAdaptor {
    using SafeTransferLib for ERC20;
    using Math for uint256;

    //==================== Adaptor Data Specification ====================
    // adaptorData = abi.encode(ERC20 _spt)
    // Where:
    // `_spt` is the Swaap pool token of the Swaap LP market this adaptor is working with
    //================= Configuration Data Specification =================
    // NOT USED
    // **************************** IMPORTANT ****************************
    // This adaptor has the `assetOf` as a spt, and thus relies on the `PriceRouterv2` Swaap
    // Extensions corresponding with the type of spt the Cellar is working with.
    //====================================================================

    //============================================ Error Statements ===========================================

    /**
     * @notice Provided swap array length differs from expected tokens array length.
     */
    error SwaapPoolAdaptor___LengthMismatch();

    /**
     * @notice Provided pool token and expected token do not match.
     */
    error SwaapPoolAdaptor___PoolTokenAndExpectedTokenMismatch();

    //============================================ Global Vars && Specific Adaptor Constants ===========================================

    /**
     * @notice The Swaap Vault contract
     * @notice For mainnet use 0xd315a9C38eC871068FEC378E4Ce78AF528C76293
     */
    IVault public immutable SWAAP_VAULT;

    /**
     * @notice The enum value needed to specify the join and exit type on Safeguard pools.
     */
    enum JoinKind {
        INIT,
        ALL_TOKENS_IN_FOR_EXACT_SPT_OUT,
        EXACT_TOKENS_IN_FOR_SPT_OUT
    }
    enum ExitKind {
        EXACT_SPT_IN_FOR_TOKENS_OUT,
        SPT_IN_FOR_EXACT_TOKENS_OUT
    }

    //============================================ Constructor ===========================================

    constructor(address _swaapVault) {
        SWAAP_VAULT = IVault(_swaapVault);
    }

    //============================================ Global Functions ===========================================

    /**
     * @notice Identifier unique to this adaptor for a shared registry.
     * Normally the identifier would just be the address of this contract, but this identifier is needed during Cellar Delegate Call Operations, so getting the address of the adaptor is more difficult.
     * @return encoded adaptor identifier
     */
    function identifier() public pure virtual override returns (bytes32) {
        return keccak256(abi.encode("Swaap Pool Adaptor V 1.0"));
    }

    //============================================ Implement Base Functions ===========================================

    /**
     * @notice User deposits are allowed into this position.
     */
    function deposit(uint256, bytes memory, bytes memory) public pure override {}

    /**
     * @notice If a user withdraw needs more SPTs than what is in the Cellar's
     *         wallet, then the function should revert.
     */
    function withdraw(
        uint256 _amountSPTToSend,
        address _recipient,
        bytes memory _adaptorData,
        bytes memory
    ) public override {
        // Run external receiver check.
        _externalReceiverCheck(_recipient);

        ERC20 spt = abi.decode(_adaptorData, (ERC20));

        spt.safeTransfer(_recipient, _amountSPTToSend);
    }

    /**
     * @notice Accounts for SPTs in the Cellar's wallet
     * @dev See `balanceOf`.
     */
    function withdrawableFrom(bytes memory _adaptorData, bytes memory) public view override returns (uint256) {
        return balanceOf(_adaptorData);
    }

    /**
     * @notice Calculates the Cellar's balance of the positions creditAsset, a specific spt.
     * @param _adaptorData encoded data for trusted adaptor position detailing the spt
     * @return total balance of spt for Cellar
     */
    function balanceOf(bytes memory _adaptorData) public view override returns (uint256) {
        ERC20 spt = abi.decode(_adaptorData, (ERC20));
        return ERC20(spt).balanceOf(msg.sender);
    }

    /**
     * @notice Returns the positions underlying assets.
     * @param _adaptorData encoded data for trusted adaptor position detailing the spt
     * @return spt for Cellar's respective balancer pool position
     */
    function assetOf(bytes memory _adaptorData) public pure override returns (ERC20) {
        return ERC20(abi.decode(_adaptorData, (address)));
    }

    /**
     * @notice When positions are added to the Registry, this function can be used in order to figure out
     *         what assets this adaptor needs to price, and confirm pricing is properly setup.
     * @param _adaptorData specified spt of interest
     * @return assets for Cellar's respective balancer pool position
     * @dev all breakdowns of spt pricing and its underlying assets are done through the PriceRouter extension (in accordance to PriceRouterv2 architecture)
     */
    function assetsUsed(bytes memory _adaptorData) public pure override returns (ERC20[] memory assets) {
        assets = new ERC20[](1);
        assets[0] = assetOf(_adaptorData);
    }

    /**
     * @notice This adaptor returns collateral, and not debt.
     * @return whether adaptor returns debt or not
     */
    function isDebt() public pure override returns (bool) {
        return false;
    }

    //============================================ Strategist Functions ===========================================

    /**
     * @notice Allows strategists to join Swaap pools using all tokens (without swaps).
     */
    function joinPool(
        ERC20 targetPool,
        ERC20[] memory expectedTokensIn,
        uint256[] memory maxAmountsIn,
        uint256 requestedSpt
    ) external {
        // verify that the spt is used and tracked in the calling cellar
        _validateSpt(targetPool);

        uint256 length = expectedTokensIn.length;
        if (length != maxAmountsIn.length) revert SwaapPoolAdaptor___LengthMismatch();

        bytes32 poolId = IBasePool(address(targetPool)).getPoolId();

        // Start formulating request.
        IVault.JoinPoolRequest memory request;

        (IERC20[] memory poolTokens, , ) = SWAAP_VAULT.getPoolTokens(poolId);

        // Ensure pool tokens has the same length as expectedTokensIn.
        if (poolTokens.length != expectedTokensIn.length) revert SwaapPoolAdaptor___LengthMismatch();

        request.assets = new IAsset[](length);

        for (uint256 i; i < length; ++i) {
            if (address(poolTokens[i]) != address(expectedTokensIn[i]))
                revert SwaapPoolAdaptor___PoolTokenAndExpectedTokenMismatch();
            request.assets[i] = IAsset(address(poolTokens[i]));
            expectedTokensIn[i].safeApprove(address(SWAAP_VAULT), maxAmountsIn[i]);
        }

        request.maxAmountsIn = maxAmountsIn;
        request.userData = abi.encode(JoinKind.ALL_TOKENS_IN_FOR_EXACT_SPT_OUT, requestedSpt);

        SWAAP_VAULT.joinPool(poolId, address(this), address(this), request);

        // If we had to swap for an asset, revoke any unused approval from join.
        for (uint256 i; i < length; ++i) {
            // Revoke input asset approval.
            _revokeExternalApproval(expectedTokensIn[i], address(SWAAP_VAULT));
        }
    }

    /**
     * @notice Allows strategists to exit Swaap pools with all tokens (no swaps).
     */
    function exitPool(
        ERC20 targetPool,
        ERC20[] memory expectedTokensOut,
        uint256[] memory minAmountsOut,
        uint256 burnSpt
    ) external {
        uint256 length = expectedTokensOut.length;
        if (length != minAmountsOut.length) revert SwaapPoolAdaptor___LengthMismatch();

        bytes32 poolId = IBasePool(address(targetPool)).getPoolId();

        // Start formulating request.
        IVault.ExitPoolRequest memory request;

        (IERC20[] memory poolTokens, , ) = SWAAP_VAULT.getPoolTokens(poolId);

        // Ensure pool tokens has the same length as expectedTokensOut.
        if (poolTokens.length != expectedTokensOut.length) revert SwaapPoolAdaptor___LengthMismatch();

        request.assets = new IAsset[](length);

        for (uint256 i; i < length; ++i) {
            if (address(poolTokens[i]) != address(expectedTokensOut[i]))
                revert SwaapPoolAdaptor___PoolTokenAndExpectedTokenMismatch();
            request.assets[i] = IAsset(address(poolTokens[i]));
        }

        request.minAmountsOut = minAmountsOut;
        request.userData = abi.encode(ExitKind.EXACT_SPT_IN_FOR_TOKENS_OUT, burnSpt);

        SWAAP_VAULT.exitPool(poolId, address(this), payable(address(this)), request);
    }

    /**
     * @notice Start a flash loan using Swaap.
     */
    function makeFlashLoan(IERC20[] memory tokens, uint256[] memory amounts, bytes memory data) public {
        SWAAP_VAULT.flashLoan(IFlashLoanRecipient(address(this)), tokens, amounts, data);
    }

    //============================================ Helper Functions ===========================================

    /**
     * @notice Validates that a given spt is set up as a position in the Cellar
     * @dev This function uses `address(this)` as the address of the Cellar
     * @param _spt of interest
     */
    function _validateSpt(ERC20 _spt) internal view {
        _verifyUsedPosition(abi.encode(_spt));
    }
}
