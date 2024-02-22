// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import { ManagementFeesLib } from "src/modules/fees/ManagementFeesLib.sol";
import { PerformanceFeesLib } from "src/modules/fees/PerformanceFeesLib.sol";
import { Cellar } from "src/base/Cellar.sol";
import { Registry } from "src/Registry.sol";
import { Math } from "src/utils/Math.sol";
import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";

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
     * @notice Emitted when a cellar's fees are paid out.
     * @param cellar the cellar that had fees paid out
     * @param strategistPayoutAddress the address that the strategist's fees were paid to
     * @param protocolPayoutAddress the address that the protocol's fees were paid to
     * @param strategistPayout the amount of fees paid to the strategist
     * @param protocolPayout the amount of fees paid to the protocol
     */
    event Payout(
        address indexed cellar,
        address indexed strategistPayoutAddress,
        uint256 strategistPayout,
        address indexed protocolPayoutAddress,
        uint256 protocolPayout
    );

    /**
     * @notice Emitted when management fees are claimed.
     * @param cellar the cellar that had management fees claimed
     * @param fees the amount of management fees claimed
     * @param timestamp the time the fees were claimed
     */
    event ManagementFeesClaimed(address indexed cellar, uint256 fees, uint256 timestamp);

    /**
     * @notice Emitted when performance fees are claimed.
     * @param cellar the cellar that had performance fees claimed
     * @param fees the amount of performance fees claimed
     * @param timestamp the time the fees were claimed
     */
    event PerformanceFeesClaimed(address indexed cellar, uint256 fees, uint256 highWaterMarkPrice, uint256 timestamp);

    // =============================================== ERRORS ===============================================

    /// @notice Throws when the caller is not the cellar owner.
    error FeesManager__OnlyCellarOwner();

    /// @notice Throws when the caller is not the registry owner.
    error FeesManager__OnlyRegistryOwner();

    /// @notice Throws when the fee cut is above the authorized limit.
    error FeesManager__InvalidFeesCut();

    /// @notice Throws when the fees are above authorized limit.
    error FeesManager__InvalidFeesRate();

    /// @notice Throws when the protocol payout address is invalid.
    error FeesManager__InvalidProtocolPayoutAddress();

    // =============================================== CONSTANTS ===============================================

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

    // =============================================== MODIFIERS ===============================================

    modifier onlyCellarOwner(address cellar) {
        if (msg.sender != Cellar(cellar).owner()) {
            revert FeesManager__OnlyCellarOwner();
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
        uint48 managementFeesRate;
        uint64 performanceFeesRate;
        uint72 highWaterMarkPrice;
        uint40 highWaterMarkResetTime; // the owner can choose to reset the high watermark (at most every HIGH_WATERMARK_RESET_INTERVAL)
        uint64 strategistPlatformCut; // the platform cut for the strategist in 18 decimals
        address strategistPayoutAddress;
    }

    mapping(address => FeesData) internal cellarFeesData;

    function getCellarFeesData(address cellar) external view returns (FeesData memory) {
        return cellarFeesData[cellar];
    }

    /**
     * @notice Called by cellars to compute the fees to apply before depositing assets (or minting shares).
     * @param totalAssets total assets in the cellar
     * @param totalSupply total shares in the cellar
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
        FeesData storage feeData = cellarFeesData[msg.sender];

        (uint256 managementFees, uint256 performanceFees, uint256 highWaterMarkPrice) = _getUnclaimedFees(
            feeData,
            totalAssets,
            totalSupply
        );

        uint16 enterOrExitFeesRate = isEntering ? feeData.enterFeesRate : feeData.exitFeesRate;

        return (enterOrExitFeesRate, performanceFees, managementFees, highWaterMarkPrice, feeData);
    }

    /**
     * @notice Called by cellars to compute the fees to apply before depositing assets (or minting shares).
     * @param totalAssets total assets in the cellar
     * @param totalSupply total shares in the cellar
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
            emit ManagementFeesClaimed(msg.sender, managementFees, block.timestamp);
        }

        if (performanceFees > 0) {
            feeData.highWaterMarkPrice = uint72(highWaterMarkPrice);
            emit PerformanceFeesClaimed(msg.sender, performanceFees, highWaterMarkPrice, block.timestamp);
        }

        return (enterOrExitFeesRate, performanceFees + managementFees);
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

    // =============================================== PAYOUT FUNCTIONS ===============================================

    /**
     * @notice Payout the fees to the protocol and the strategist (permissionless, anyone can call it)
     * @param cellar the cellar to payout the fees for
     */
    function payoutFees(address cellar) public {
        uint256 totalFees = ERC20(cellar).balanceOf(address(this));

        if (totalFees == 0) {
            return;
        }

        FeesData storage feeData = cellarFeesData[cellar];

        // if the strategist payout address is not set, the strategist doesn't get any fees
        address strategistPayoutAddress = feeData.strategistPayoutAddress;
        uint256 strategistPayout = strategistPayoutAddress == address(0)
            ? 0
            : (totalFees.mulDivUp(feeData.strategistPlatformCut, Math.WAD));

        strategistPayout = strategistPayout > totalFees ? totalFees : strategistPayout;

        // Send the strategist's cut
        if (strategistPayout > 0) {
            ERC20(cellar).safeTransfer(strategistPayoutAddress, strategistPayout);
        }

        // Send the protocol's cut
        uint256 protocolPayout = totalFees - strategistPayout;
        if (protocolPayout > 0) {
            ERC20(cellar).safeTransfer(protocolPayoutAddress, protocolPayout);
        }

        emit Payout(cellar, strategistPayoutAddress, strategistPayout, protocolPayoutAddress, protocolPayout);
    }

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
    function setStrategistPayoutAddress(address cellar, address newPayoutAddress) external onlyCellarOwner(cellar) {
        emit StrategistPayoutAddressChanged(newPayoutAddress);
        FeesData storage feeData = cellarFeesData[cellar];
        // no need to check if the address is not valid, the owner can set it to any address
        feeData.strategistPayoutAddress = newPayoutAddress;
    }

    // =============================================== FEES CONFIG ===============================================

    /**
     * @notice Sets the Strategists cut of platform fees
     * @param cut the platform cut for the strategist
     * @dev Callable by Swaap Governance.
     */
    function setStrategistPlatformCut(address cellar, uint64 cut) external onlyCellarOwner(cellar) {
        if (cut > MAX_FEE_CUT) revert FeesManager__InvalidFeesCut();

        payoutFees(cellar);

        FeesData storage feeData = cellarFeesData[cellar];

        emit StrategistPlatformCutChanged(cut);
        feeData.strategistPlatformCut = cut;
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
