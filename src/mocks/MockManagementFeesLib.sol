// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ManagementFeesLib } from "src/modules/fees/ManagementFeesLib.sol";

contract MockManagementFeesLib {

    function calcYearlyRate(uint256 yearlyFees) external pure returns (uint256) {
        return ManagementFeesLib._calcYearlyRate(yearlyFees);
    }

    function calcAccumulatedManagementFees(
        uint256 currentTime,
        uint256 lastClaim,
        uint256 feesRate,
        uint256 currentSupply
    ) external pure returns (uint256) {
        return ManagementFeesLib._calcAccumulatedManagementFees(currentTime, lastClaim, feesRate, currentSupply);
    }

}
