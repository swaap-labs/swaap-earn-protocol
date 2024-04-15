// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ERC20, SafeTransferLib, Fund, PriceRouter, Registry, Math } from "src/modules/adaptors/BaseAdaptor.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { PositionlessAdaptor } from "src/modules/adaptors/PositionlessAdaptor.sol";
import { BaseAdaptor } from "src/modules/adaptors/BaseAdaptor.sol";

/**
 * @title Aggregator Adaptor Contract
 * @notice Allows Funds to swap with aggregators.
 */
contract AggregatorAdaptor is PositionlessAdaptor {
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using Address for address;

    //==================== Adaptor Data Specification ====================
    // NOT USED
    //================= Configuration Data Specification =================
    // NOT USED
    // **************************** IMPORTANT ****************************
    // This adaptor has NO underlying position, its only purpose is to
    // expose the swap function to strategists during rebalances.
    //====================================================================

    /**
     * @notice Emitted when an aggregator's spender is not set in the Registry (not approved)
     */
    error AggregatorAdaptor__AggregatorSpenderNotSet(address aggregator);

    /**
     * @notice The erc20 adaptor contract used by the funds on the current network.
     */
    bytes32 public immutable erc20AdaptorIdentifier;

    /// @dev Represents 100% in basis points, where 1 basis point is 1/100th of 1%. Used for slippage
    uint256 internal constant _BPS_ONE_HUNDRED_PER_CENT = 1e4;

    /// @dev Default slippage tolerance for swaps.
    uint32 internal constant _DEFAULT_SLIPPAGE = 0.96e4; // 4%

    constructor(address _erc20Adaptor) {
        erc20AdaptorIdentifier = BaseAdaptor(_erc20Adaptor).identifier();
    }

    //============================================ Global Functions ===========================================
    /**
     * @dev Identifier unique to this adaptor for a shared registry.
     * Normally the identifier would just be the address of this contract, but this
     * Identifier is needed during Fund Delegate Call Operations, so getting the address
     * of the adaptor is more difficult.
     */
    function identifier() public pure virtual override returns (bytes32) {
        return keccak256("Aggregator Adaptor V 1.0");
    }

    //============================================ Strategist Functions ===========================================

    /**
     * @notice Allows strategists to make ERC20 swaps using an aggregator.
     * @param aggregator The aggregator's address
     * @param tokenIn The sold token
     * @param tokenOut The bought token
     * @param amount The maximum amount sold
     * @param customSlippage The custom slippage allowed with the trade
     * @param swapCallData The calldata used to trade via the aggregator
     */
    function swapWithAggregator(
        address aggregator,
        ERC20 tokenIn,
        ERC20 tokenOut,
        uint256 amount,
        uint32 customSlippage,
        bytes memory swapCallData
    ) external {
        _validateTokenOutIsUsed(address(tokenOut));

        address spender = Fund(address(this)).registry().aggregatorSpender(aggregator);

        if (spender == address(0)) revert AggregatorAdaptor__AggregatorSpenderNotSet(aggregator);

        tokenIn.safeApprove(spender, amount);

        // Save token balances.
        uint256 tokenInBalance = tokenIn.balanceOf(address(this));
        uint256 tokenOutBalance = tokenOut.balanceOf(address(this));

        // Perform Swap.
        aggregator.functionCall(swapCallData);

        uint256 tokenInAmountIn = tokenInBalance - tokenIn.balanceOf(address(this));
        uint256 tokenOutAmountOut = tokenOut.balanceOf(address(this)) - tokenOutBalance;

        (uint256 tokenInPriceInUSD, uint256 tokenOutPriceInUSD) = _getTokenPricesInUSD(tokenIn, tokenOut);

        {
            uint8 tokenInDecimals = tokenIn.decimals();
            uint8 tokenOutDecimals = tokenOut.decimals();

            // get the value of token out received in tokenIn terms
            uint256 valueOutInTokenIn = _getValueInQuote(
                tokenOutPriceInUSD,
                tokenInPriceInUSD,
                tokenOutDecimals,
                tokenInDecimals,
                tokenOutAmountOut
            );

            // check if the trade slippage is within the limit
            uint256 maxSlippage = customSlippage < slippage() ? slippage() : customSlippage;
            if (valueOutInTokenIn < tokenInAmountIn.mulDivDown(maxSlippage, _BPS_ONE_HUNDRED_PER_CENT))
                revert BaseAdaptor__Slippage();

            // check that the permitted volume per period was not surpassed
            uint256 swapVolumeInUSD = _getSwapValueInUSD(tokenInPriceInUSD, tokenInAmountIn, tokenInDecimals);
            Registry(Fund(address(this)).registry()).checkAndUpdateFundTradeVolume(swapVolumeInUSD);
        }

        // Ensure spender has zero approval.
        _revokeExternalApproval(tokenIn, spender);
    }

    function _validateTokenOutIsUsed(address tokenOut) internal view {
        bytes memory adaptorData = abi.encode(tokenOut);
        // This adaptor has no underlying position, so no need to validate token out.
        bytes32 positionHash = keccak256(abi.encode(erc20AdaptorIdentifier, false, adaptorData));
        uint32 positionId = Fund(address(this)).registry().getPositionHashToPositionId(positionHash);
        if (!Fund(address(this)).isPositionUsed(positionId)) revert BaseAdaptor__PositionNotUsed(adaptorData);
    }

    //============================================ Price Functions ===========================================
    function _getTokenPricesInUSD(ERC20 tokenIn, ERC20 tokenOut) internal view returns (uint256, uint256) {
        PriceRouter priceRouter = Fund(address(this)).priceRouter();
        uint256 tokenInPriceInUSD = priceRouter.getPriceInUSD(tokenIn);
        uint256 tokenOutPriceInUSD = priceRouter.getPriceInUSD(tokenOut);
        return (tokenInPriceInUSD, tokenOutPriceInUSD);
    }

    /**
     * @notice math function that preserves precision by multiplying the amountBase before dividing.
     * @param priceBaseUSD the base asset price in USD
     * @param priceQuoteUSD the quote asset price in USD
     * @param baseDecimals the base asset decimals
     * @param quoteDecimals the quote asset decimals
     * @param amountBase the amount of base asset
     */
    function _getValueInQuote(
        uint256 priceBaseUSD,
        uint256 priceQuoteUSD,
        uint8 baseDecimals,
        uint8 quoteDecimals,
        uint256 amountBase
    ) internal pure returns (uint256 valueInQuote) {
        // Get value in quote asset, but maintain as much precision as possible.
        // Cleaner equations below.
        // baseToUSD = amountBase * priceBaseUSD / 10**baseDecimals.
        // valueInQuote = baseToUSD * 10**quoteDecimals / priceQuoteUSD
        valueInQuote = amountBase.mulDivDown(
            (priceBaseUSD * 10 ** quoteDecimals),
            (10 ** baseDecimals * priceQuoteUSD)
        );
    }

    /**
     * @notice Returns the swap value in USD.
     */
    function _getSwapValueInUSD(
        uint256 priceIn,
        uint256 amountIn,
        uint8 tokenInDecimals
    ) internal pure returns (uint256) {
        return priceIn.mulDivDown(amountIn, 10 ** tokenInDecimals);
    }

    // =============================================== Slippage ===============================================
    /**
     * @notice Slippage tolerance for swaps.
     * @return slippage in basis points.
     */
    function slippage() public pure virtual override returns (uint32) {
        return _DEFAULT_SLIPPAGE; // 4%
    }
}
