// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import "src/base/Cellar.sol";

contract MockCellar is Cellar {
    constructor(
        address _owner,
        Registry _registry,
        ERC20 _asset,
        string memory _name,
        string memory _symbol,
        uint32 _holdingPosition,
        bytes memory _holdingPositionConfig,
        uint256 _initialDeposit,
        uint64 _strategistPlatformCut,
        uint192 _shareSupplyCap
    )

    Cellar(
        _owner,
        _registry,
        _asset,
        _name,
        _symbol,
        _holdingPosition,
        _holdingPositionConfig,
        _initialDeposit,
        _strategistPlatformCut,
        _shareSupplyCap
    ) {}

    function getDelayUntilEndPause() public pure returns (uint256) {
        return DELAY_UNTIL_END_PAUSE;
    }
}