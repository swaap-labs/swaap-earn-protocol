// SPDX-License-Identifier: Apache-2.0
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
// documentation files (the “Software”), to deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
// Software.

// THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
// WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
// OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

pragma solidity ^0.8.0;

import { Math } from "src/utils/Math.sol";

library PerformanceFeesLib {
    using Math for uint256;

    function _calcSharePrice(uint256 totalAssets, uint256 totalSupply) internal pure returns (uint256) {
        return totalAssets.mulDivDown(Math.WAD, totalSupply);
    }

    /**
     * @param totalAssets The current total assets
     * @param totalSupply The total supply of shares
     * @param highWatermarkPrice The high watermark share price (in 18 decimals)
     * @param performanceFeesRate The performance fees rate (in 18 decimals)
     * @return sharesAsFees The shares that should be minted as fees
     * @return highWaternarmPrice The updated high watermark price
     */
    function _calcPerformanceFees(
        uint256 totalAssets,
        uint256 totalSupply,
        uint256 highWatermarkPrice,
        uint256 performanceFeesRate
    ) internal pure returns (uint256, uint256) {
        uint256 currentSharePrice = _calcSharePrice(totalAssets, totalSupply);

        if (highWatermarkPrice == 0) {
            // the first time the high watermark is set
            return (0, currentSharePrice);
        }

        if (performanceFeesRate == 0) {
            return (0, currentSharePrice);
        }

        // Calculate the high watermark total assets (in asset decimals)
        uint256 highWatermarkTotalAssets = totalSupply.mulDivDown(highWatermarkPrice, Math.WAD);

        if (totalAssets <= highWatermarkTotalAssets) {
            // no positive performance
            return (0, highWatermarkPrice);
        }

        // Calculate the increase in totalAssets (in asset decimals)
        uint256 assetsIncrease;
        unchecked {
            assetsIncrease = totalAssets - highWatermarkTotalAssets;
        }

        // the ownership that the protocol must have to get the fees (in 18 decimals)
        uint256 ownershipAsFees = assetsIncrease.mulDivDown(Math.WAD, totalAssets).mulDivDown(
            performanceFeesRate,
            Math.WAD
        );

        // the shares needed to be minted to pay the fees (in cellar token decimals)
        uint256 sharesAsFees = totalSupply.mulDivDown(ownershipAsFees, Math.WAD - ownershipAsFees);

        // it can return sharesAsFees = 0 if the price increase is too small
        return (sharesAsFees, currentSharePrice);
    }
}
