// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ERC20, SafeTransferLib, Fund, PriceRouter, Math } from "src/modules/adaptors/BaseAdaptor.sol";
import { IPoolV3 } from "src/interfaces/external/IPoolV3.sol";
import { IAaveToken } from "src/interfaces/external/IAaveToken.sol";
import { IAaveOracle } from "src/interfaces/external/IAaveOracle.sol";
import { ICreditDelegationToken } from "src/interfaces/external/ICreditDelegationToken.sol";

/**
 * @title Aave Account Adaptor
 * @notice Allows Funds to create multiple aave accounts and interact with Aave positions.
 * @dev This adaptor should be used in conjunction with the AaveV3AccountManager and is not
 * meant to be used as a standalone contract.
 */
contract AaveV3AccountExtension {
    using SafeTransferLib for ERC20;

    //==================== Adaptor Data Specification ====================
    // NOT USED
    //================= Configuration Data Specification =================
    // NOT USED
    // **************************** IMPORTANT ****************************
    // NOT USED
    //====================================================================

    address public immutable fund;

    IPoolV3 public immutable pool;

    constructor(address v3Pool) {
        fund = msg.sender;
        pool = IPoolV3(v3Pool);
    }

    error AaveV3AccountExtension__CallerNotFund();

    modifier onlyFund() {
        if (msg.sender != fund) {
            revert AaveV3AccountExtension__CallerNotFund();
        }
        _;
    }

    //============================================ Global Functions ===========================================

    function approveATokenToFund(address aToken) external onlyFund {
        ERC20(aToken).safeApprove(fund, type(uint256).max);
    }

    function approveDebtDelegationToFund(address debtToken) external onlyFund {
        ICreditDelegationToken(debtToken).approveDelegation(fund, type(uint256).max);
    }

    /**
     * @notice Allows strategists to adjust an asset's isolation mode.
     */
    function adjustIsolationModeAssetAsCollateral(address underlyingToken, bool useAsCollateral) external onlyFund {
        pool.setUserUseReserveAsCollateral(underlyingToken, useAsCollateral);
    }

    /**
     * @notice Allows strategists to enter different EModes.
     */
    function changeEMode(uint8 categoryId) external onlyFund {
        pool.setUserEMode(categoryId);
    }

    /**
     * @notice Allows strategist to use aTokens to repay debt tokens with the same underlying.
     */
    function repayWithATokens(ERC20 underlying, uint256 amount) public onlyFund {
        pool.repayWithATokens(address(underlying), amount, 2);
    }

    /**
     * @notice Allows strategist to withdraw assets from Aave.
     * @param receiver the address to receive the withdrawed assets
     * @param amount the amount of `underlyingToken` to withdraw from Aave.
     */
    function withdrawFromAave(address receiver, address underlyingToken, uint256 amount) external onlyFund {
        pool.withdraw(underlyingToken, amount, receiver);
    }
}
