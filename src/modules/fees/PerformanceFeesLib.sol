// SPDX-License-Identifier: Apache-2.0
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
