// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import "src/base/Fund.sol";

contract MockFund is Fund {
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
    )
        Fund(
            _owner,
            _registry,
            _asset,
            _name,
            _symbol,
            _holdingPosition,
            _holdingPositionConfig,
            _initialDeposit,
            _shareSupplyCap
        )
    {}

    function getDelayUntilEndPause() public pure returns (uint256) {
        return DELAY_UNTIL_END_PAUSE;
    }
}
