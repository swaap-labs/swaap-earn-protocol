// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.21;

import "src/utils/LogExpMathv08.sol";
import "src/utils/Math.sol";

library ManagementFeesLib {
    using Math for uint256;

    uint256 internal constant _ONE_YEAR = 365 days;

    error ManagementFees__ExponentInputInvalid();

    /**********************************************************************************************
    // f = yearly management fees percentage          /  ln(1 - f) \                             //
    // 1y = 1 year                             a = - | ------------ |                            //
    // a = yearly rate constant                       \     1y     /                             //
    **********************************************************************************************/
    function _calcYearlyRate(uint256 yearlyFees) internal pure returns (uint256) {
        uint256 logInput = Math.WAD - yearlyFees;
        // Since 0 < logInput <= 1 => logResult <= 0
        int256 logResult = LogExpMathv08.ln(int256(logInput));
        return (uint256(-logResult) / _ONE_YEAR);
    }

    /**********************************************************************************************
    // SF = shares to be minted as fees                                                          //
    // TS = total supply                                   SF = TS * (e^(a*dT) -1)               //
    // a = fees rate                                                                             //
    // dT = elapsed time between the previous and current claim                                  //
    **********************************************************************************************/
    function _calcAccumulatedManagementFees(
        uint256 currentTime,
        uint256 lastClaim,
        uint256 feesRate,
        uint256 currentSupply
    ) internal pure returns (uint256) {
        if (feesRate == 0) {
            return 0;
        }

        if (currentTime == lastClaim) {
            return 0;
        }

        uint256 elapsedTime = currentTime - lastClaim;

        uint256 expInput = feesRate * elapsedTime;

        if (expInput > uint256(type(int256).max)) {
            // it should never happen but just in case
            revert ManagementFees__ExponentInputInvalid();
        }

        uint256 expResult = uint256(LogExpMathv08.exp(int256(expInput)));
        return currentSupply.mulDivDown(expResult - Math.WAD, Math.WAD);
    }
}
