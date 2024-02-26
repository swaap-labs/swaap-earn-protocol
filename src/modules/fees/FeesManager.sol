// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import { ManagementFeesLib } from "src/modules/fees/ManagementFeesLib.sol";
import { PerformanceFeesLib } from "src/modules/fees/PerformanceFeesLib.sol";
import { Fund } from "src/base/Fund.sol";
import { Registry } from "src/Registry.sol";
import { Math } from "src/utils/Math.sol";
import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";

/**
 * @title Handles Fees collection and distribution for Funds
 */
contract FeesManager {
    using Math for uint256;
    using SafeTransferLib for ERC20;

    // =============================================== EVENTS ===============================================
    /**
     * @notice Emitted when strategist platform fee cut is changed.
     * @param newPlatformCut value strategist platform fee cut was changed to
     */
    event StrategistPlatformCutChanged(uint64 newPlatformCut);

    /**
     * @notice Emitted when strategists payout address is changed.
     * @param newPayoutAddress value strategists payout address was changed to
     */
    event StrategistPayoutAddressChanged(address newPayoutAddress);

    /**
     * @notice Emitted when protocol payout address is changed.
     * @param newPayoutAddress value protocol payout address was changed to
     */
    event ProtocolPayoutAddressChanged(address newPayoutAddress);

    /**
     * @notice Emitted when a fund's fees are paid out.
     * @param fund the fund that had fees paid out
     * @param strategistPayoutAddress the address that the strategist's fees were paid to
     * @param protocolPayoutAddress the address that the protocol's fees were paid to
     * @param strategistPayout the amount of fees paid to the strategist
     * @param protocolPayout the amount of fees paid to the protocol
     */
    event Payout(
        address indexed fund,
        address indexed strategistPayoutAddress,
        uint256 strategistPayout,
        address indexed protocolPayoutAddress,
        uint256 protocolPayout
    );

    /**
     * @notice Emitted when management fees are claimed.
     * @param fund the fund that had management fees claimed
     * @param fees the amount of management fees claimed
     */
    event ManagementFeesClaimed(address indexed fund, uint256 fees);

    /**
     * @notice Emitted when management fees rate is updated.
     * @param fund the fund that had management fees rate updated
     * @param managementFeesPerYear the new management fees yearly fees (1e18 = 100% per year)
     * @param managementFeesRate the new management fees rate
     */
    event ManagementFeesRateUpdated(address indexed fund, uint256 managementFeesPerYear, uint256 managementFeesRate);

    /**
     * @notice Emitted when performance fees are claimed.
     * @param fund the fund that had performance fees claimed
     * @param fees the amount of performance fees claimed
     */
    event PerformanceFeesClaimed(address indexed fund, uint256 fees, uint256 highWaterMarkPrice);

    /**
     * @notice Emitted when performance fees rate is updated.
     * @param fund the fund that had performance fees rate updated
     * @param performanceFeesRate the new performance fees rate
     * @param highWaterMarkPrice the high-water mark price at the time of the update
     */
    event PerformanceFeesRateUpdated(address indexed fund, uint256 performanceFeesRate, uint256 highWaterMarkPrice);

    // =============================================== ERRORS ===============================================

    /// @notice Throws when the caller is not the fund owner.
    error FeesManager__OnlyFundOwner();

    /// @notice Throws when the caller is not the registry owner.
    error FeesManager__OnlyRegistryOwner();

    /// @notice Throws when the fee cut is above the authorized limit.
    error FeesManager__InvalidFeesCut();

    /// @notice Throws when the fees are above authorized limit.
    error FeesManager__InvalidFeesRate();

    /// @notice Throws when the protocol payout address is invalid.
    error FeesManager__InvalidProtocolPayoutAddress();

    /// @notice Throws when the high-water mark has not yet expired.
    error FeesManager__HighWaterMarkNotYetExpired();

    /// @notice Throws when the high-water mark price overflows. (unlikely scenario)
    error FeesManager__WaterMarkPriceOverflow();

    // =============================================== CONSTANTS ===============================================

    /// @notice Sets the max possible fee cut for funds.
    uint256 public constant MAX_FEE_CUT = 1e18;

    /// @notice Sets the max possible management fees for funds.
    uint256 public constant MAX_MANAGEMENT_FEES = 50e16; // 50%

    /// @notice Sets the max possible performance fees for funds.
    uint256 public constant MAX_PERFORMANCE_FEES = 50e16; // 50%

    // Enter and exit fees are expressed in basis points (1e4 = 100%)
    uint256 internal constant _BPS_ONE_HUNDRED_PER_CENT = 1e4;

    /// @notice Sets the max possible enter fees for funds.
    uint256 public constant MAX_ENTER_FEES = _BPS_ONE_HUNDRED_PER_CENT / 10; // 10%

    /// @notice Sets the max possible exit fees for funds.
    uint256 public constant MAX_EXIT_FEES = _BPS_ONE_HUNDRED_PER_CENT / 10; // 10%

    /// @notice Sets the high-water mark reset interval for funds.
    uint256 public constant HIGH_WATERMARK_RESET_INTERVAL = 1 * 30 days; // 1 months

    /// @notice Sets the high-water mark reset interval for funds.
    uint256 public constant HIGH_WATERMARK_RESET_ASSET_THRESHOLD = Math.WAD + Math.WAD / 2; // 50%

    // =============================================== MODIFIERS ===============================================

    modifier onlyFundOwner(address fund) {
        if (msg.sender != Fund(fund).owner()) {
            revert FeesManager__OnlyFundOwner();
        }
        _;
    }

    modifier onlyRegistryOwner() {
        if (msg.sender != registry.owner()) {
            revert FeesManager__OnlyRegistryOwner();
        }
        _;
    }

    // =============================================== STATE VARIABLES ===============================================

    /**
     * @notice Address of the platform's protocol payout address. Used to send protocol fees.
     */
    address public protocolPayoutAddress;

    /**
     * @notice Address of the platform's registry contract. Used to get the latest address of modules.
     */
    Registry public immutable registry;

    constructor(address _registry, address _protocolPayoutAddress) {
        registry = Registry(_registry);
        _setProtocolPayoutAddress(_protocolPayoutAddress);
    }

    struct FeesData {
        uint16 enterFeesRate; // in bps (max value = 10000)
        uint16 exitFeesRate; // in bps (max value = 10000)
        uint40 previousManagementFeesClaimTime; // last management fees claim time
        uint48 managementFeesRate; // in 18 decimals
        uint64 performanceFeesRate; // in 18 decimals (100% corresponds to 1e18)
        uint72 highWaterMarkPrice; // the high-water mark price
        uint40 highWaterMarkResetTime; // the owner can choose to reset the high-water mark (at most every HIGH_WATERMARK_RESET_INTERVAL)
        uint256 highWaterMarkResetAssets; // the owner can choose to reset the high-water mark (at most every HIGH_WATERMARK_RESET_ASSETS_TOLERANCE)
        uint64 strategistPlatformCut; // the platform cut for the strategist in 18 decimals
        address strategistPayoutAddress; // the address to send the strategist's fees to
    }

    mapping(address => FeesData) internal fundFeesData;

    function getFundFeesData(address fund) external view returns (FeesData memory) {
        return fundFeesData[fund];
    }

    /**
     * @notice Called by funds to compute the fees to apply before depositing assets (or minting shares).
     * @param totalAssets total assets in the fund
     * @param totalSupply total shares in the fund
     * @return enterOrExitFeesRate enter or exit fees rate
     * @return mintFeesAsShares minted shares to be used as fees
     */
    function previewApplyFeesBeforeJoinExit(
        uint256 totalAssets,
        uint256 totalSupply,
        bool isEntering
    ) external view returns (uint16, uint256) {
        (
            uint16 enterOrExitFeesRate,
            uint256 performanceFees,
            uint256 managementFees,
            ,

        ) = _previewApplyFeesBeforeJoinExit(totalAssets, totalSupply, isEntering);
        return (enterOrExitFeesRate, performanceFees + managementFees);
    }

    function _previewApplyFeesBeforeJoinExit(
        uint256 totalAssets,
        uint256 totalSupply,
        bool isEntering
    ) internal view returns (uint16, uint256, uint256, uint256, FeesData storage) {
        FeesData storage feeData = fundFeesData[msg.sender];

        (uint256 managementFees, uint256 performanceFees, uint256 highWaterMarkPrice) = _getUnclaimedFees(
            feeData,
            totalAssets,
            totalSupply
        );

        uint16 enterOrExitFeesRate = isEntering ? feeData.enterFeesRate : feeData.exitFeesRate;

        return (enterOrExitFeesRate, performanceFees, managementFees, highWaterMarkPrice, feeData);
    }

    /**
     * @notice Called by funds to compute the fees to apply before depositing assets (or minting shares).
     * @param totalAssets total assets in the fund
     * @param totalSupply total shares in the fund
     * @return enterOrExitFeesRate enter or exit fees rate
     * @return mintFeesAsShares minted shares to be used as fees
     */
    function applyFeesBeforeJoinExit(
        uint256 totalAssets,
        uint256 totalSupply,
        bool isEntering
    ) external returns (uint16, uint256) {
        (
            uint16 enterOrExitFeesRate,
            uint256 performanceFees,
            uint256 managementFees,
            uint256 highWaterMarkPrice,
            FeesData storage feeData
        ) = _previewApplyFeesBeforeJoinExit(totalAssets, totalSupply, isEntering);

        if (managementFees > 0) {
            feeData.previousManagementFeesClaimTime = uint40(block.timestamp);
            emit ManagementFeesClaimed(msg.sender, managementFees);
        }

        if (performanceFees > 0) {
            if(highWaterMarkPrice > type(uint72).max) revert FeesManager__WaterMarkPriceOverflow();
            
            feeData.highWaterMarkPrice = uint72(highWaterMarkPrice);
            emit PerformanceFeesClaimed(msg.sender, performanceFees, highWaterMarkPrice);
        }

        return (enterOrExitFeesRate, performanceFees + managementFees);
    }

    /**
     * @notice Get total supply after applying unclaimed fees.
     */
    function getTotalSupplyAfterFees(
        address fund,
        uint256 totalAssets,
        uint256 totalSupply
    ) external view returns (uint256) {
        FeesData storage feeData = fundFeesData[fund];

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

    // =============================================== PAYOUT FUNCTIONS ===============================================

    /**
     * @notice Payout the fees to the protocol and the strategist (permissionless, anyone can call it)
     * @param fund the fund to payout the fees for
     */
    function payoutFees(address fund) public {
        uint256 totalFees = ERC20(fund).balanceOf(address(this));

        if (totalFees == 0) {
            return;
        }

        FeesData storage feeData = fundFeesData[fund];

        // if the strategist payout address is not set, the strategist doesn't get any fees
        address strategistPayoutAddress = feeData.strategistPayoutAddress;
        uint256 strategistPayout = strategistPayoutAddress == address(0)
            ? 0
            : (totalFees.mulDivUp(feeData.strategistPlatformCut, Math.WAD));

        strategistPayout = strategistPayout > totalFees ? totalFees : strategistPayout;

        // Send the strategist's cut
        if (strategistPayout > 0) {
            ERC20(fund).safeTransfer(strategistPayoutAddress, strategistPayout);
        }

        // Send the protocol's cut
        uint256 protocolPayout = totalFees - strategistPayout;
        if (protocolPayout > 0) {
            ERC20(fund).safeTransfer(protocolPayoutAddress, protocolPayout);
        }

        emit Payout(fund, strategistPayoutAddress, strategistPayout, protocolPayoutAddress, protocolPayout);
    }

    /**
     * @notice Sets the protocol payout address
     * @param newPayoutAddress the new protocol payout address
     */
    function setProtocolPayoutAddress(address newPayoutAddress) external onlyRegistryOwner {
        _setProtocolPayoutAddress(newPayoutAddress);
    }

    function _setProtocolPayoutAddress(address newPayoutAddress) internal {
        if (newPayoutAddress == address(0)) revert FeesManager__InvalidProtocolPayoutAddress();
        emit ProtocolPayoutAddressChanged(newPayoutAddress);
        protocolPayoutAddress = newPayoutAddress;
    }

    /**
     * @notice Sets the Strategists payout address
     * @param newPayoutAddress the new strategist payout address
     * @dev Callable by Swaap Strategist.
     */
    function setStrategistPayoutAddress(address fund, address newPayoutAddress) external onlyFundOwner(fund) {
        emit StrategistPayoutAddressChanged(newPayoutAddress);
        FeesData storage feeData = fundFeesData[fund];
        // no need to check if the address is not valid, the owner can set it to any address
        feeData.strategistPayoutAddress = newPayoutAddress;
    }

    // =============================================== FEES CONFIG ===============================================

    /**
     * @notice Sets the Strategists cut of platform fees
     * @param cut the platform cut for the strategist
     * @dev Callable by Swaap Governance.
     */
    function setStrategistPlatformCut(address fund, uint64 cut) external onlyFundOwner(fund) {
        if (cut > MAX_FEE_CUT) revert FeesManager__InvalidFeesCut();

        payoutFees(fund);

        FeesData storage feeData = fundFeesData[fund];

        emit StrategistPlatformCutChanged(cut);
        feeData.strategistPlatformCut = cut;
    }

    /**
     * @notice Sets the management fees per year for this fund.
     * @param fund the fund to set the management fees for
     * @param managementFeesPerYear the management fees per year (1e18 = 100% per year)
     */
    function setManagementFeesPerYear(address fund, uint256 managementFeesPerYear) external onlyFundOwner(fund) {
        if (managementFeesPerYear > MAX_MANAGEMENT_FEES) revert FeesManager__InvalidFeesRate();

        Fund(fund).collectFees(); // collectFees is nonReetrant, which makes setManagementFeesPerYear nonReetrant

        FeesData storage feeData = fundFeesData[fund];
        uint256 managementFeesRate = ManagementFeesLib._calcYearlyRate(managementFeesPerYear);
        feeData.managementFeesRate = uint48(managementFeesRate);

        // the management fees time is not guaranteed to be updated when collecting fees if the fees are 0
        // so we update it here to make sure it's always up to date when changing the rate
        feeData.previousManagementFeesClaimTime = uint40(block.timestamp);

        emit ManagementFeesRateUpdated(fund, managementFeesPerYear, managementFeesRate);
    }

    /**
     * @notice Sets the performance fees for this fund.
     * @param fund the fund to set the performance fees for
     * @param performanceFeesRate the performance fees (1e18 = 100%)
     */
    function setPerformanceFees(address fund, uint256 performanceFeesRate) external onlyFundOwner(fund) {
        if (performanceFeesRate > MAX_PERFORMANCE_FEES) revert FeesManager__InvalidFeesRate();

        FeesData storage feeData = fundFeesData[fund];

        // if the high-water mark is not set, set it and do not collect fees potential pending management fees
        // as the function is most likely called during the setup of the fund.
        if (feeData.highWaterMarkPrice == 0) {
            feeData.performanceFeesRate = uint64(performanceFeesRate);
            // initialize the high-water mark
            // note that the fund will revert if we are calling totalAssets() when it's locked (nonReentrantView)
            uint256 totalAssets = Fund(fund).totalAssets();
            uint256 highWaterMarkPrice = PerformanceFeesLib._calcSharePrice(totalAssets, Fund(fund).totalSupply());
            if(highWaterMarkPrice > type(uint72).max) revert FeesManager__WaterMarkPriceOverflow();

            fundFeesData[fund].highWaterMarkPrice = uint72(highWaterMarkPrice);
            fundFeesData[fund].highWaterMarkResetTime = uint40(block.timestamp);
            fundFeesData[fund].highWaterMarkResetAssets = uint256(totalAssets);

            emit PerformanceFeesRateUpdated(fund, performanceFeesRate, highWaterMarkPrice);
            return;
        }

        // collect fees before updating the rate
        Fund(fund).collectFees(); // collectFees is nonReetrant, which makes setPerformanceFees nonReetrant

        emit PerformanceFeesRateUpdated(fund, performanceFeesRate, feeData.highWaterMarkPrice);
        feeData.performanceFeesRate = uint64(performanceFeesRate);
    }

    /**
     * @notice Sets the enter fees for this fund.
     * @param fund the fund to set the performance fees for
     * @param enterFeesRate the enter fees (10000 = 100%)
     */
    function setEnterFees(address fund, uint16 enterFeesRate) external onlyFundOwner(fund) {
        if (enterFeesRate > MAX_ENTER_FEES) {
            revert FeesManager__InvalidFeesRate();
        }

        fundFeesData[fund].enterFeesRate = enterFeesRate;
    }

    /**
     * @notice Sets the exit fees for this fund.
     * @param fund the fund to set the performance fees for
     * @param exitFeesRate the exit fees (10000 = 100%)
     */
    function setExitFees(address fund, uint16 exitFeesRate) external onlyFundOwner(fund) {
        if (exitFeesRate > MAX_EXIT_FEES) {
            revert FeesManager__InvalidFeesRate();
        }

        fundFeesData[fund].exitFeesRate = exitFeesRate;
    }

    /**
     * @notice Resets the high-water mark for this fund.
     * @param fund the fund to reset the high-water mark state for
     */
    function resetHighWaterMark(address fund) external onlyRegistryOwner {
        Fund c = Fund(fund);
        FeesData storage feeData = fundFeesData[fund];
        uint256 totalAssets = c.totalAssets();

        // checks high-water mark reset conditions
        if (
            (feeData.highWaterMarkPrice > 0) && // unset condition
            (block.timestamp < feeData.highWaterMarkResetTime + HIGH_WATERMARK_RESET_INTERVAL) && // time condition
            (totalAssets < (feeData.highWaterMarkResetAssets * HIGH_WATERMARK_RESET_ASSET_THRESHOLD) / Math.WAD) // assets condition
        ) {
            revert FeesManager__HighWaterMarkNotYetExpired();
        }

        // calculates the new high-water mark
        uint256 highWaterMarkPrice = PerformanceFeesLib._calcSharePrice(totalAssets, c.totalSupply());
        if(highWaterMarkPrice > type(uint72).max) revert FeesManager__WaterMarkPriceOverflow();

        // updates the high-water mark state
        feeData.highWaterMarkPrice = uint72(highWaterMarkPrice);
        feeData.highWaterMarkResetTime = uint40(block.timestamp);
        feeData.highWaterMarkResetAssets = uint256(totalAssets);
    }
}
