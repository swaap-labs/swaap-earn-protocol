// SPDX-License-Identifier: MIT
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

import { ManagementFeesLib } from "src/modules/fees/ManagementFeesLib.sol";
import { PerformanceFeesLib } from "src/modules/fees/PerformanceFeesLib.sol";
import { Cellar } from "src/base/Cellar.sol";

contract FeesManager {
    /// @notice Throws when the caller is not the cellar owner.
    error FeesManager__OnlyCellarOwner();

    /// @notice Throws when the fee cut is above the authorized limit.
    error FeesManager__InvalidFeeCut();

    /// @notice Throws when the fees are above authorized limit.
    error FeesManager__InvalidFeesRate();

    /// @notice Sets the max possible fee cut for cellars.
    uint256 public constant MAX_FEE_CUT = 1e18;

    /// @notice Sets the max possible management fees for cellars.
    uint256 public constant MAX_MANAGEMENT_FEES = 50e16; // 50%

    /// @notice Sets the max possible performance fees for cellars.
    uint256 public constant MAX_PERFORMANCE_FEES = 50e16; // 50%

    // Enter and exit fees are expressed in basis points (1e4 = 100%)
    uint256 internal constant _BPS_ONE_HUNDRED_PER_CENT = 1e4;

    /// @notice Sets the max possible enter fees for cellars.
    uint256 public constant MAX_ENTER_FEES = _BPS_ONE_HUNDRED_PER_CENT / 10; // 10%

    /// @notice Sets the max possible exit fees for cellars.
    uint256 public constant MAX_EXIT_FEES = _BPS_ONE_HUNDRED_PER_CENT / 10; // 10%

    /// @notice Sets the high watermark reset interval for cellars.
    uint256 public constant HIGH_WATERMARK_RESET_INTERVAL = 3 * 30 days; // 3 months

    modifier onlyCellarOwner(address cellar) {
        if (msg.sender != Cellar(cellar).owner()) {
            revert FeesManager__OnlyCellarOwner();
        }
        _;
    }

    address public protocolPayoutAddress;

    struct FeesData {
        uint16 enterFeesRate; // in bps (max value = 10000)
        uint16 exitFeesRate; // in bps (max value = 10000)
        uint40 previousManagementFeesClaimTime; // last management fees claim time
        uint48 managementFeesRate;
        uint64 performanceFeesRate;
        uint72 highWaterMarkPrice;
        uint40 highWaterMarkResetTime; // the owner can choose to reset the high watermark (at most every HIGH_WATERMARK_RESET_INTERVAL)
        uint64 strategistPlatformCut;
        address strategistPayoutAddress;
    }

    mapping(address => FeesData) internal cellarFeesData;

    function getCellarFeesData(address cellar) external view returns (FeesData memory) {
        return cellarFeesData[cellar];
    }

    event CellarFeesDataUpdated(
        address indexed cellar,
        address protocolPayoutAddress,
        uint256 highWaterMarkPrice,
        uint256 highWaterMarkResetTime,
        uint256 performanceFeesRate,
        uint256 highWaterMarkVariationTrigger,
        uint256 managementFeesRate
    );

    /**
     * @notice Called by cellars to compute the fees to apply before depositing assets (or minting shares).
     * @param totalAssets total assets in the cellar
     * @param totalSupply total shares in the cellar
     * @return enterOrExitFeesRate enter or exit fees rate
     * @return mintSharesAsFees minted shares to be used as fees
     */
    function applyFeesBeforeJoinExit(
        uint256 totalAssets,
        uint256 totalSupply,
        bool isEntering
    ) external returns (uint16, uint256) {
        FeesData storage feeData = cellarFeesData[msg.sender];

        (uint256 managementFees, uint256 performanceFees, uint256 highWaterMarkPrice) = _getUnclaimedFees(
            feeData,
            totalAssets,
            totalSupply
        );

        if (managementFees > 0) {
            feeData.previousManagementFeesClaimTime = uint40(block.timestamp);
        }

        if (performanceFees > 0) {
            feeData.highWaterMarkPrice = uint72(highWaterMarkPrice);
        }

        uint16 enterOrExitFeesRate = isEntering ? feeData.enterFeesRate : feeData.exitFeesRate;

        uint256 mintSharesAsFees = performanceFees + managementFees;

        return (enterOrExitFeesRate, mintSharesAsFees);
    }

    /**
     * @notice Get total supply after applying unclaimed fees.
     */
    function getTotalSupplyAfterFees(
        address cellar,
        uint256 totalAssets,
        uint256 totalSupply
    ) external view returns (uint256) {
        FeesData storage feeData = cellarFeesData[cellar];

        (uint256 managementFees, uint256 performanceFees, ) = _getUnclaimedFees(feeData, totalAssets, totalSupply);

        return (totalSupply + managementFees + performanceFees);
    }

    function _getUnclaimedFees(
        FeesData storage feeData,
        uint256 totalAssets,
        uint256 totalSupply
    ) internal view returns (uint256, uint256, uint256) {
        // management fees
        uint256 managementFees = ManagementFeesLib._calcAccumulatedManagementFees(
            block.timestamp,
            feeData.previousManagementFeesClaimTime,
            feeData.managementFeesRate,
            totalSupply
        );

        // performance fees
        (uint256 performanceFees, uint256 highWaterMarkPrice) = PerformanceFeesLib._calcPerformanceFees(
            totalAssets,
            totalSupply + managementFees,
            feeData.highWaterMarkPrice,
            feeData.performanceFeesRate // performanceFees
        );

        return (managementFees, performanceFees, highWaterMarkPrice);
    }

    // =============================================== FEES CONFIG ===============================================

    /**
     * @notice Emitted when strategist platform fee cut is changed.
     * @param oldPlatformCut value strategist platform fee cut was changed from
     * @param newPlatformCut value strategist platform fee cut was changed to
     */
    event StrategistPlatformCutChanged(uint64 oldPlatformCut, uint64 newPlatformCut);

    /**
     * @notice Emitted when strategists payout address is changed.
     * @param oldPayoutAddress value strategists payout address was changed from
     * @param newPayoutAddress value strategists payout address was changed to
     */
    event StrategistPayoutAddressChanged(address oldPayoutAddress, address newPayoutAddress);

    /**
     * @notice Sets the Strategists cut of platform fees
     * @param cut the platform cut for the strategist
     * @dev Callable by Sommelier Governance.
     */
    function setStrategistPlatformCut(address cellar, uint64 cut) external onlyCellarOwner(cellar) {
        if (cut > MAX_FEE_CUT) revert FeesManager__InvalidFeeCut();

        FeesData storage feeData = cellarFeesData[cellar];
        // TODO - send pending protocol fees before changing the cut

        emit StrategistPlatformCutChanged(feeData.strategistPlatformCut, cut);
        feeData.strategistPlatformCut = cut;
    }

    /**
     * @notice Sets the Strategists payout address
     * @param payout the new strategist payout address
     * @dev Callable by Sommelier Strategist.
     */
    function setStrategistPayoutAddress(address cellar, address payout) external onlyCellarOwner(cellar) {
        FeesData storage feeData = cellarFeesData[cellar];
        emit StrategistPayoutAddressChanged(feeData.strategistPayoutAddress, payout);

        feeData.strategistPayoutAddress = payout;
    }

    /**
     * @notice Sets the management fees per year for this cellar.
     * @param cellar the cellar to set the management fees for
     * @param managementFeesPerYear the management fees per year (1e18 = 100% per year)
     */
    function setManagementFeesPerYear(address cellar, uint256 managementFeesPerYear) external onlyCellarOwner(cellar) {
        if (managementFeesPerYear > MAX_MANAGEMENT_FEES) revert FeesManager__InvalidFeesRate();

        // TODO claim pending fees before changing the rate
        FeesData storage feeData = cellarFeesData[cellar];
        feeData.managementFeesRate = uint48(ManagementFeesLib._calcYearlyRate(managementFeesPerYear));
        feeData.previousManagementFeesClaimTime = uint40(block.timestamp);
    }

    /**
     * @notice Sets the performance fees for this cellar.
     * @param cellar the cellar to set the performance fees for
     * @param performanceFeesRate the performance fees (1e18 = 100%)
     */
    function setPerformanceFees(address cellar, uint256 performanceFeesRate) external onlyCellarOwner(cellar) {
        if (performanceFeesRate > MAX_PERFORMANCE_FEES) revert FeesManager__InvalidFeesRate();

        FeesData storage feeData = cellarFeesData[cellar];

        // TODO claim pending fees before changing the rate
        feeData.performanceFeesRate = uint64(performanceFeesRate);
        if (feeData.highWaterMarkPrice == 0) {
            // initialize the high watermark
            // note that the cellar will revert if we are calling totalAssets() when it's locked (nonReentrantView)
            cellarFeesData[cellar].highWaterMarkPrice = uint72(
                PerformanceFeesLib._calcSharePrice(Cellar(cellar).totalAssets(), Cellar(cellar).totalSupply())
            );
        }
    }

    /**
     * @notice Sets the enter fees for this cellar.
     * @param cellar the cellar to set the performance fees for
     * @param enterFeesRate the enter fees (10000 = 100%)
     */
    function setEnterFees(address cellar, uint16 enterFeesRate) external onlyCellarOwner(cellar) {
        if (enterFeesRate > MAX_ENTER_FEES) {
            revert FeesManager__InvalidFeesRate();
        }

        cellarFeesData[cellar].enterFeesRate = enterFeesRate;
    }

    /**
     * @notice Sets the exit fees for this cellar.
     * @param cellar the cellar to set the performance fees for
     * @param exitFeesRate the exit fees (10000 = 100%)
     */
    function setExitFees(address cellar, uint16 exitFeesRate) external onlyCellarOwner(cellar) {
        if (exitFeesRate > MAX_EXIT_FEES) {
            revert FeesManager__InvalidFeesRate();
        }

        cellarFeesData[cellar].exitFeesRate = exitFeesRate;
    }
}
