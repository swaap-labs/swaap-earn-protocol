// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ERC20, SafeTransferLib, Cellar, PriceRouter, Math } from "src/modules/adaptors/BaseAdaptor.sol";
import { IPoolV3 } from "src/interfaces/external/IPoolV3.sol";
import { IAaveToken } from "src/interfaces/external/IAaveToken.sol";
import { IAaveOracle } from "src/interfaces/external/IAaveOracle.sol";
import { ICreditDelegationToken } from "src/interfaces/external/ICreditDelegationToken.sol";

/**
 * @title Aave Account Adaptor
 * @notice Allows Cellars to create multiple aave accounts and interact with Aave positions.
 * @dev This adaptor should be used in conjunction with the AaveV3AccountDeployer and is not
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

    address public immutable cellar;

    IPoolV3 public immutable pool;

    constructor(address v3Pool) {
        cellar = msg.sender;
        pool = IPoolV3(v3Pool);
    }

    error AaveV3AccountExtension__CallerNotCellar();

    modifier onlyCellar() {
        if (msg.sender != cellar) {
            revert AaveV3AccountExtension__CallerNotCellar();
        }
        _;
    }

    //============================================ Global Functions ===========================================

    function approveATokenToCellar(address token) external onlyCellar {
        ERC20(token).safeApprove(cellar, type(uint256).max);
    }

    function approveDebtDelegationToCellar(address token) external onlyCellar {
        ICreditDelegationToken(token).approveDelegation(cellar, type(uint256).max);
    }

    /**
     * @notice Allows strategists to adjust an asset's isolation mode.
     */
    function adjustIsolationModeAssetAsCollateral(address asset, bool useAsCollateral) external onlyCellar {
        pool.setUserUseReserveAsCollateral(asset, useAsCollateral);
    }

    /**
     * @notice Allows strategists to enter different EModes.
     */
    function changeEMode(uint8 categoryId) external onlyCellar {
        pool.setUserEMode(categoryId);
    }

    /**
     * @notice Allows strategist to use aTokens to repay debt tokens with the same underlying.
     */
    function repayWithATokens(ERC20 underlying, uint256 amount) public onlyCellar {
        pool.repayWithATokens(address(underlying), amount, 2);
    }
}
