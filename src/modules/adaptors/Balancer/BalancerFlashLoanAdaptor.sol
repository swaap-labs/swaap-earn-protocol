// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BalancerFlashLoanHelper } from "src/modules/adaptors/Balancer/BalancerFlashLoanHelper.sol";
import { PositionlessAdaptor } from "src/modules/adaptors/PositionlessAdaptor.sol";

/**
 * @title Balancer FlashLoan Adaptor
 * @notice Allows Funds to initiate a flashloan with balancer's vault.
 */
contract BalancerFlashLoanAdaptor is BalancerFlashLoanHelper, PositionlessAdaptor {
    //==================== Adaptor Data Specification ====================
    // NOT USED
    //================= Configuration Data Specification =================
    // NOT USED
    //====================================================================

    constructor(address _vault) BalancerFlashLoanHelper(_vault) {}

    //============================================ Global Functions ===========================================

    /**
     * @notice Identifier unique to this adaptor for a shared registry.
     * Normally the identifier would just be the address of this contract, but this identifier is needed during Fund Delegate Call Operations, so getting the address of the adaptor is more difficult.
     * @return encoded adaptor identifier
     */
    function identifier() public pure virtual override returns (bytes32) {
        return keccak256(abi.encode("Balancer FlashLoan Adaptor V 1.0"));
    }
}
