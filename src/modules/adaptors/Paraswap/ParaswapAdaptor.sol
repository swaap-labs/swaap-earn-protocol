// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { AggregatorBaseAdaptor, ERC20 } from "src/modules/adaptors/AggregatorBaseAdaptor.sol";

/**
 * @title Paraswap Adaptor
 * @notice Allows Funds to swap with Paraswap.
 */
contract ParaswapAdaptor is AggregatorBaseAdaptor {
    //==================== Adaptor Data Specification ====================
    // NOT USED
    //================= Configuration Data Specification =================
    // NOT USED
    // **************************** IMPORTANT ****************************
    // This adaptor has NO underlying position, its only purpose is to
    // expose the swap function to strategists during rebalances.
    //====================================================================

    /**
     * @notice The paraswap swap target contract on current network.
     * @notice For mainnet use 0xDEF171Fe48CF0115B1d80b88dc8eAB59176FEe57.
     */
    address public immutable target;

    /**
     * @notice The paraswap spender contract on current network that should be approved.
     * @notice For mainnet use 0x216B4B4Ba9F3e719726886d34a177484278Bfcae.
     */
    address public immutable spender;

    constructor(address _target, address _spender, address _erc20Adaptor) AggregatorBaseAdaptor(_erc20Adaptor) {
        target = _target;
        spender = _spender;
    }

    //============================================ Global Functions ===========================================
    /**
     * @dev Identifier unique to this adaptor for a shared registry.
     * Normally the identifier would just be the address of this contract, but this
     * Identifier is needed during Fund Delegate Call Operations, so getting the address
     * of the adaptor is more difficult.
     */
    function identifier() public pure virtual override returns (bytes32) {
        return keccak256(abi.encode("Paraswap Adaptor V 1.0"));
    }

    //============================================ Strategist Functions ===========================================
    /**
     * @notice Allows strategists to make ERC20 swaps using paraswap.
     */
    function swapWithParaswap(
        ERC20 tokenIn,
        ERC20 tokenOut,
        uint256 amount,
        uint32 customSlippage,
        bytes memory swapCallData
    ) external {
        _swapWithAggregator(tokenIn, tokenOut, amount, target, spender, customSlippage, swapCallData);
    }
}
