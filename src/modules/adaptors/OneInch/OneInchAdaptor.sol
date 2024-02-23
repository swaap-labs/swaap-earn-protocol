// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { AggregatorBaseAdaptor, ERC20 } from "src/modules/adaptors/AggregatorBaseAdaptor.sol";

/**
 * @title 1inch Adaptor
 * @notice Allows Funds to swap with 1Inch.
 */
contract OneInchAdaptor is AggregatorBaseAdaptor {
    //==================== Adaptor Data Specification ====================
    // NOT USED
    //================= Configuration Data Specification =================
    // NOT USED
    // **************************** IMPORTANT ****************************
    // This adaptor has NO underlying position, its only purpose is to
    // expose the swap function to strategists during rebalances.
    //====================================================================

    /**
     * @notice The 1inch swap target contract on current network.
     * @notice For mainnet use 0x1111111254EEB25477B68fb85Ed929f73A960582.
     */
    address public immutable target;

    constructor(address _target, address _erc20Adaptor) AggregatorBaseAdaptor(_erc20Adaptor) {
        target = _target;
    }

    //============================================ Global Functions ===========================================
    /**
     * @dev Identifier unique to this adaptor for a shared registry.
     * Normally the identifier would just be the address of this contract, but this
     * Identifier is needed during Fund Delegate Call Operations, so getting the address
     * of the adaptor is more difficult.
     */
    function identifier() public pure virtual override returns (bytes32) {
        return keccak256(abi.encode("1Inch Adaptor V 1.0"));
    }

    //============================================ Strategist Functions ===========================================
    function swapWithOneInch(
        ERC20 tokenIn,
        ERC20 tokenOut,
        uint256 amount,
        uint32 customSlippage,
        bytes memory swapCallData
    ) external {
        _swapWithAggregator(tokenIn, tokenOut, amount, target, target, customSlippage, swapCallData);
    }
}
