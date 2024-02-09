// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ParaswapAdaptor } from "src/modules/adaptors/Paraswap/ParaswapAdaptor.sol";

contract MockParaswapAdaptor is ParaswapAdaptor {
    constructor(address _target, address _spender, address _erc20Adaptor) ParaswapAdaptor(_target, _spender, _erc20Adaptor) {}

    /**
     * @notice Override the ZeroX adaptors identifier so both adaptors can be added to the same registry.
     */
    function identifier() public pure override returns (bytes32) {
        return keccak256(abi.encode("Mock Paraswap Adaptor V 1.0"));
    }
}
