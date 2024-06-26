// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Fund, Registry, ERC20, Math, SafeTransferLib } from "src/base/Fund.sol";

contract FundWithAaveFlashLoans is Fund {
    using Math for uint256;
    using SafeTransferLib for ERC20;

    /**
     * @notice The Aave V2 Pool contract on current network.
     * @dev For mainnet use 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9.
     */
    address public immutable aavePool;

    constructor(
        address _owner,
        Registry _registry,
        ERC20 _asset,
        string memory _name,
        string memory _symbol,
        uint32 _holdingPosition,
        bytes memory _holdingPositionConfig,
        uint256 _initialDeposit,
        uint192 _shareSupplyCap,
        address _aavePool
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
    {
        aavePool = _aavePool;
    }

    // ========================================= Aave Flash Loan Support =========================================
    /**
     * @notice External contract attempted to initiate a flash loan.
     */
    error Fund__ExternalInitiator();

    /**
     * @notice executeOperation was not called by the Aave Pool.
     */
    error Fund__CallerNotAavePool();

    /**
     * @notice Allows rebalancers to utilize Aave flashloans while rebalancing the fund.
     */
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        if (initiator != address(this)) revert Fund__ExternalInitiator();
        if (msg.sender != aavePool) revert Fund__CallerNotAavePool();

        AdaptorCall[] memory data = abi.decode(params, (AdaptorCall[]));

        // Run all adaptor calls.
        _makeAdaptorCalls(data);

        // Approve pool to repay all debt.
        for (uint256 i = 0; i < amounts.length; ++i) {
            ERC20(assets[i]).safeApprove(aavePool, (amounts[i] + premiums[i]));
        }

        return true;
    }
}
