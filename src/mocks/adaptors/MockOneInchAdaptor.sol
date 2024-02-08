// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { OneInchAdaptor } from "src/modules/adaptors/OneInch/OneInchAdaptor.sol";

contract MockOneInchAdaptor is OneInchAdaptor {
    constructor(address _target, address _erc20Adaptor) OneInchAdaptor(_target, _erc20Adaptor) {}

    /**
     * @notice Override the ZeroX adaptors identifier so both adaptors can be added to the same registry.
     */
    function identifier() public pure override returns (bytes32) {
        return keccak256(abi.encode("Mock 1Inch Adaptor V 1.0"));
    }
}
