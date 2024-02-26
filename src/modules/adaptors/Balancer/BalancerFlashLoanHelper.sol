// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { IVault, IERC20, IAsset, IFlashLoanRecipient } from "src/interfaces/external/Balancer/IVault.sol";

/**
 * @title Balancer FlashLoan Adaptor
 * @notice Allows Funds to initiate a flashloan with balancer's vault.
 */
abstract contract BalancerFlashLoanHelper {
    //==================== Adaptor Data Specification ====================
    // NOT USED
    //================= Configuration Data Specification =================
    // NOT USED
    //====================================================================

    //============================================ Global Vars && Specific Adaptor Constants ===========================================

    /**
     * @notice The Balancer Vault contract
     * @notice For mainnet use 0xBA12222222228d8Ba445958a75a0704d566BF2C8
     */
    IVault public immutable vault;

    //============================================ Constructor ===========================================

    constructor(address _vault) {
        vault = IVault(_vault);
    }

    //============================================ Global Functions ===========================================
    /**
     * @notice Start a flash loan using Balancer.
     */
    function makeFlashLoan(IERC20[] memory tokens, uint256[] memory amounts, bytes memory data) public {
        vault.flashLoan(IFlashLoanRecipient(address(this)), tokens, amounts, data);
    }

}
