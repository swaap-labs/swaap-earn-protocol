// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BaseAdaptor, ERC20, SafeTransferLib, Cellar, Registry, PriceRouter } from "src/modules/adaptors/BaseAdaptor.sol";
import { IVault, IERC20, IAsset, IFlashLoanRecipient } from "src/interfaces/external/Balancer/IVault.sol";
import { IStakingLiquidityGauge } from "src/interfaces/external/Balancer/IStakingLiquidityGauge.sol";
import { ILiquidityGaugev3Custom } from "src/interfaces/external/Balancer/ILiquidityGaugev3Custom.sol";
import { IBasePool } from "src/interfaces/external/Balancer/typically-npm/IBasePool.sol";
import { ILiquidityGauge } from "src/interfaces/external/Balancer/ILiquidityGauge.sol";
import { Math } from "src/utils/Math.sol";

/**
 * @title Swaap Pool Adaptor
 * @notice Allows Cellars to interact with Swaap Safeguard Pools.
 */
contract SwaapPoolAdaptor is BaseAdaptor {
    using SafeTransferLib for ERC20;
    using Math for uint256;

    //==================== Adaptor Data Specification ====================
    // adaptorData = abi.encode(ERC20 _bpt, address _liquidityGauge)
    // Where:
    // `_bpt` is the Balancer pool token of the Balancer LP market this adaptor is working with
    // `_liquidityGauge` is the balancer gauge corresponding to the specified bpt
    //================= Configuration Data Specification =================
    // NOT USED
    // **************************** IMPORTANT ****************************
    // This adaptor has the `assetOf` as a bpt, and thus relies on the `PriceRouterv2` Balancer
    // Extensions corresponding with the type of bpt the Cellar is working with.
    //====================================================================

    //============================================ Error Statements ===========================================

    /**
     * @notice Tried using a bpt and/or liquidityGauge that is not setup as a position.
     */
    error BalancerPoolAdaptor__BptAndGaugeComboMustBeTracked(address bpt, address liquidityGauge);

    /**
     * @notice Constructor param for slippage too high
     */
    error BalancerPoolAdaptor___InvalidConstructorSlippage();

    /**
     * @notice Provided swap array length differs from expected tokens array length.
     */
    error SwaapPoolAdaptor___LengthMismatch();

    error SwaapPoolAdaptor___PoolTokenAndExpectedTokenMismatch();

    /**
     * @notice Provided swap information chose to keep an asset that is not supported
     *         for pricing.
     */
    error BalancerPoolAdaptor___UnsupportedTokenNotSwapped();

    //============================================ Global Vars && Specific Adaptor Constants ===========================================

    /**
     * @notice The Swaap Vault contract
     * @notice For mainnet use 0xd315a9C38eC871068FEC378E4Ce78AF528C76293
     */
    IVault public immutable swaapVault;

    /**
     * @notice The enum value needed to specify the join and exit type on Safeguard pools.
     */
    enum JoinKind {
        INIT,
        ALL_TOKENS_IN_FOR_EXACT_BPT_OUT,
        EXACT_TOKENS_IN_FOR_BPT_OUT
    }
    enum ExitKind {
        EXACT_BPT_IN_FOR_TOKENS_OUT,
        BPT_IN_FOR_EXACT_TOKENS_OUT
    }

    //============================================ Constructor ===========================================

    constructor(address _swaapVault) {
        swaapVault = IVault(_swaapVault);
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
     * @notice If a user withdraw needs more BPTs than what is in the Cellar's
     *         wallet, then the Cellar will unstake BPTs from the gauge.
     */
    function withdraw(
        uint256 _amountBPTToSend,
        address _recipient,
        bytes memory _adaptorData,
        bytes memory
    ) public override {
        // Run external receiver check.
        _externalReceiverCheck(_recipient);
        (ERC20 bpt, address liquidityGauge) = abi.decode(_adaptorData, (ERC20, address));
        uint256 liquidBptBeforeWithdraw = bpt.balanceOf(address(this));
        if (_amountBPTToSend > liquidBptBeforeWithdraw) {
            uint256 amountToUnstake = _amountBPTToSend - liquidBptBeforeWithdraw;
            unstakeBPT(bpt, liquidityGauge, amountToUnstake);
        }
        bpt.safeTransfer(_recipient, _amountBPTToSend);
    }

    /**
     * @notice Accounts for BPTs in the Cellar's wallet, and staked in gauge.
     * @dev See `balanceOf`.
     */
    function withdrawableFrom(bytes memory _adaptorData, bytes memory) public view override returns (uint256) {
        return balanceOf(_adaptorData);
    }

    /**
     * @notice Calculates the Cellar's balance of the positions creditAsset, a specific bpt.
     * @param _adaptorData encoded data for trusted adaptor position detailing the bpt and liquidityGauge address (if it exists)
     * @return total balance of bpt for Cellar, including liquid bpt and staked bpt
     */
    function balanceOf(bytes memory _adaptorData) public view override returns (uint256) {
        (ERC20 bpt, address liquidityGauge) = abi.decode(_adaptorData, (ERC20, address));
        if (liquidityGauge == address(0)) return ERC20(bpt).balanceOf(msg.sender);
        ERC20 liquidityGaugeToken = ERC20(liquidityGauge);
        uint256 stakedBPT = liquidityGaugeToken.balanceOf(msg.sender);
        return ERC20(bpt).balanceOf(msg.sender) + stakedBPT;
    }

    /**
     * @notice Returns the positions underlying assets.
     * @param _adaptorData encoded data for trusted adaptor position detailing the bpt and liquidityGauge address (if it exists)
     * @return bpt for Cellar's respective balancer pool position
     */
    function assetOf(bytes memory _adaptorData) public pure override returns (ERC20) {
        return ERC20(abi.decode(_adaptorData, (address)));
    }

    /**
     * @notice When positions are added to the Registry, this function can be used in order to figure out
     *         what assets this adaptor needs to price, and confirm pricing is properly setup.
     * @param _adaptorData specified bpt of interest
     * @return assets for Cellar's respective balancer pool position
     * @dev all breakdowns of bpt pricing and its underlying assets are done through the PriceRouter extension (in accordance to PriceRouterv2 architecture)
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
        uint256 length = expectedTokensIn.length;
        if (length != maxAmountsIn.length) revert SwaapPoolAdaptor___LengthMismatch();

        bytes32 poolId = IBasePool(address(targetPool)).getPoolId();

        // Start formulating request.
        IVault.JoinPoolRequest memory request;

        (IERC20[] memory poolTokens, , ) = swaapVault.getPoolTokens(poolId);

        // Ensure pool tokens has the same length as expectedTokensIn.
        if (poolTokens.length != expectedTokensIn.length) revert SwaapPoolAdaptor___LengthMismatch();

        request.assets = new IAsset[](length);

        for (uint256 i; i < length; ++i) {
            if (address(poolTokens[i]) != address(expectedTokensIn[i]))
                revert SwaapPoolAdaptor___PoolTokenAndExpectedTokenMismatch();
            request.assets[i] = IAsset(address(poolTokens[i]));
            expectedTokensIn[i].safeApprove(address(swaapVault), maxAmountsIn[i]);
        }

        request.maxAmountsIn = maxAmountsIn;
        request.userData = abi.encode(JoinKind.ALL_TOKENS_IN_FOR_EXACT_BPT_OUT, requestedSpt);

        swaapVault.joinPool(poolId, address(this), address(this), request);

        // If we had to swap for an asset, revoke any unused approval from join.
        for (uint256 i; i < length; ++i) {
            // Revoke input asset approval.
            _revokeExternalApproval(expectedTokensIn[i], address(swaapVault));
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

        (IERC20[] memory poolTokens, , ) = swaapVault.getPoolTokens(poolId);

        // Ensure pool tokens has the same length as expectedTokensOut.
        if (poolTokens.length != expectedTokensOut.length) revert SwaapPoolAdaptor___LengthMismatch();

        request.assets = new IAsset[](length);

        for (uint256 i; i < length; ++i) {
            if (address(poolTokens[i]) != address(expectedTokensOut[i]))
                revert SwaapPoolAdaptor___PoolTokenAndExpectedTokenMismatch();
            request.assets[i] = IAsset(address(poolTokens[i]));
        }

        request.minAmountsOut = minAmountsOut;
        request.userData = abi.encode(ExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT, burnSpt);

        swaapVault.exitPool(poolId, address(this), payable(address(this)), request);
    }

    /**
     * @notice stake (deposit) BPTs into respective pool gauge
     * @param _bpt address of BPTs to stake
     * @param _amountIn number of BPTs to stake
     * @dev Interface custom as Balancer/Curve do not provide for liquidityGauges.
     */
    function stakeBPT(ERC20 _bpt, address _liquidityGauge, uint256 _amountIn) external {
        _validateBptAndGauge(address(_bpt), _liquidityGauge);
        uint256 amountIn = _maxAvailable(_bpt, _amountIn);
        ILiquidityGaugev3Custom liquidityGauge = ILiquidityGaugev3Custom(_liquidityGauge);
        _bpt.approve(_liquidityGauge, amountIn);
        liquidityGauge.deposit(amountIn, address(this));
        _revokeExternalApproval(_bpt, _liquidityGauge);
    }

    /**
     * @notice unstake (withdraw) BPT from respective pool gauge
     * @param _bpt address of BPTs to unstake
     * @param _amountOut number of BPTs to unstake
     * @dev Interface custom as Balancer/Curve do not provide for liquidityGauges.
     */
    function unstakeBPT(ERC20 _bpt, address _liquidityGauge, uint256 _amountOut) public {
        _validateBptAndGauge(address(_bpt), _liquidityGauge);
        ILiquidityGaugev3Custom liquidityGauge = ILiquidityGaugev3Custom(_liquidityGauge);
        _amountOut = _maxAvailable(ERC20(_liquidityGauge), _amountOut);
        liquidityGauge.withdraw(_amountOut);
    }

    /**
     * @notice Start a flash loan using Swaap.
     */
    function makeFlashLoan(IERC20[] memory tokens, uint256[] memory amounts, bytes memory data) public {
        swaapVault.flashLoan(IFlashLoanRecipient(address(this)), tokens, amounts, data);
    }

    //============================================ Helper Functions ===========================================

    /**
     * @notice Validates that a given bpt and liquidityGauge is set up as a position in the Cellar
     * @dev This function uses `address(this)` as the address of the Cellar
     * @param _bpt of interest
     * @param _liquidityGauge corresponding to _bpt
     * NOTE: _liquidityGauge can be zeroAddress in cases where Cellar doesn't want to stake or there are no gauges yet available for respective bpt
     */
    function _validateBptAndGauge(address _bpt, address _liquidityGauge) internal view {
        bytes32 positionHash = keccak256(abi.encode(identifier(), false, abi.encode(_bpt, _liquidityGauge)));
        uint32 positionId = Cellar(address(this)).registry().getPositionHashToPositionId(positionHash);
        if (!Cellar(address(this)).isPositionUsed(positionId))
            revert BalancerPoolAdaptor__BptAndGaugeComboMustBeTracked(_bpt, _liquidityGauge);
    }
}
