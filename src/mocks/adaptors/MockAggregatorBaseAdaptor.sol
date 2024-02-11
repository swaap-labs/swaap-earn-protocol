// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { AggregatorBaseAdaptor, ERC20 } from "src/modules/adaptors/AggregatorBaseAdaptor.sol";

/**
 * @title Mock Aggregator Adaptor
 * @notice Mocks the Aggregator Adaptor for testing purposes.
 */
contract MockAggregatorBaseAdaptor is AggregatorBaseAdaptor {

    address public immutable target;
    address public immutable spender;

    constructor(address _target, address _spender, address _erc20Adaptor) AggregatorBaseAdaptor(_erc20Adaptor) {
        target = _target;
        spender = _spender;
    }

    function identifier() public pure virtual override returns (bytes32) {
        return keccak256("Mock Aggregator Adaptor V 1.0");
    }

    function swapWithAggregator(
        ERC20 tokenIn,
        ERC20 tokenOut,
        uint256 amount,
        uint32 customSlippage,
        bytes memory swapCallData
    ) external {
        _swapWithAggregator(tokenIn, tokenOut, amount, target, spender, customSlippage, swapCallData);
    }
}