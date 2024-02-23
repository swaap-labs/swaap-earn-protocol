// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { VestingSimple } from "src/modules/vesting/VestingSimple.sol";
import { VestingSimpleAdaptor } from "src/modules/adaptors/VestingSimpleAdaptor.sol";
import { MockDataFeed } from "src/mocks/MockDataFeed.sol";
import "test/resources/MainnetStarter.t.sol"; // Import Everything from Starter file.
import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";

/**
 * @title FundVestingTest
 * @author kvk, crispymangoes, 0xeincodes
 * @notice Test VestingSimple.sol && VestingSimpleAdaptor functionality.
 * @dev Recall that VestingSimple is the implementation contract that the VestingSimpleAdaptor integrates with on-chain. Mockdata feeds are used as per general testing setup procedure in repo, but are effectively actual datafeeds within tests.
 */
contract FundVestingTest is MainnetStarterTest, AdaptorHelperFunctions {
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using stdStorage for StdStorage;

    MockDataFeed private usdcMockFeed;
    VestingSimple private vesting;
    VestingSimpleAdaptor private vestingAdaptor;
    Fund private fund;

    uint32 private usdcPosition = 1;
    uint32 private vestingPosition = 2;

    address private immutable user2 = vm.addr(0xFEED);
    uint256 private constant totalDeposit = 1_000_000e6;
    uint256 private constant vestingPeriod = 1 days;
    uint256 private constant initialDeposit = 1e6;

    function setUp() external {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 16869780;
        _startFork(rpcKey, blockNumber);

        // Run Starter setUp code.
        _setUp();

        usdcMockFeed = new MockDataFeed(USDC_USD_FEED);

        PriceRouter.ChainlinkDerivativeStorage memory stor;

        PriceRouter.AssetSettings memory settings;

        uint256 price = uint256(IChainlinkAggregator(address(usdcMockFeed)).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, address(usdcMockFeed));
        priceRouter.addAsset(USDC, settings, abi.encode(stor), price);

        vestingAdaptor = new VestingSimpleAdaptor();

        // Set up a vesting contract for USDC
        vesting = new VestingSimple(USDC, vestingPeriod, 0.1e6);

        // Add adaptors and positions to the registry.
        registry.trustAdaptor(address(vestingAdaptor));
        registry.trustPosition(usdcPosition, address(erc20Adaptor), abi.encode(USDC));
        registry.trustPosition(vestingPosition, address(vestingAdaptor), abi.encode(vesting));

        string memory fundName = "Multiposition Fund LP Token";

        fund = _createFund(fundName, USDC, usdcPosition, abi.encode(true), initialDeposit);
        fund.addAdaptorToCatalogue(address(erc20Adaptor));
        fund.addAdaptorToCatalogue(address(vestingAdaptor));

        fund.addPositionToCatalogue(usdcPosition);
        fund.addPositionToCatalogue(vestingPosition);
        fund.addPosition(1, vestingPosition, abi.encode(0), false);

        // Deposit funds to fund
        deal(address(USDC), address(this), totalDeposit);
        fund.setRebalanceDeviation(1e17);
        USDC.approve(address(fund), totalDeposit);
        fund.deposit(totalDeposit, address(this));
    }

    // ========================================== POSITION MANAGEMENT TEST ==========================================

    function testCannotTakeUserDeposits(uint256 assets) external {
        // Make the vesting adaptor the first position
        fund.setHoldingPosition(vestingPosition);

        assets = bound(assets, 0.1e6, totalDeposit);
        // Set up user2 with funds and have them attempt to deposit
        deal(address(USDC), user2, assets);
        vm.startPrank(user2);
        USDC.approve(address(fund), type(uint256).max);

        vm.expectRevert(bytes(abi.encodeWithSelector(BaseAdaptor.BaseAdaptor__UserDepositsNotAllowed.selector)));
        fund.deposit(assets, user2);
        vm.stopPrank();

        // Fix positions
        fund.setHoldingPosition(usdcPosition);
    }

    function testDepositToVesting(uint256 assets) external {
        assets = bound(assets, 0.1e6, totalDeposit / 10);
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);

        // Deposit % of holdings, allowed under deviation
        adaptorCalls[0] = _createBytesDataToDeposit(vesting, assets);
        data[0] = Fund.AdaptorCall({ adaptor: address(vestingAdaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        // Check TVL change
        assertEq(
            fund.totalAssets(),
            (totalDeposit - (assets)) + initialDeposit,
            "Fund totalAssets should decrease by right amount"
        );
        // Check state in vesting contract
        assertApproxEqAbs(
            vesting.totalBalanceOf(address(fund)),
            (assets),
            1,
            "Vesting contract should report deposited funds"
        );
        assertApproxEqAbs(
            vesting.vestedBalanceOf(address(fund)),
            0,
            1,
            "Vesting contract should not report vested funds"
        );
    }

    function testFailWithdrawMoreThanVested(uint256 assets) external {
        assets = bound(assets, 0.1e6, totalDeposit / 10);
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);

        // Deposit % of holdings, allowed under deviation
        adaptorCalls[0] = _createBytesDataToDeposit(vesting, assets);
        data[0] = Fund.AdaptorCall({ adaptor: address(vestingAdaptor), callData: adaptorCalls });

        fund.callOnAdaptor(data);

        // Move through half of vesting period
        skip(vestingPeriod / 2);

        // Try to withdraw all funds - should not be vested
        adaptorCalls[0] = _createBytesDataToWithdrawAny(vesting, assets);
        data[0] = Fund.AdaptorCall({ adaptor: address(vestingAdaptor), callData: adaptorCalls });

        // Not looking at specific payload because amount available may be slightly  off
        fund.callOnAdaptor(data);
    }

    function testDepositAndWithdrawReturnsZero(uint256 assets) external {
        assets = bound(assets, 0.1e6, totalDeposit / 10);
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](2);

        // Deposit % of holdings, allowed under deviation
        adaptorCalls[0] = _createBytesDataToDeposit(vesting, assets);
        adaptorCalls[1] = _createBytesDataToWithdrawAll(vesting);
        data[0] = Fund.AdaptorCall({ adaptor: address(vestingAdaptor), callData: adaptorCalls });

        // Do deposit, and withdraw, in same tx. Make sure tokens are not reclaimed
        fund.callOnAdaptor(data);

        // Check state in vesting contract
        assertApproxEqAbs(
            vesting.totalBalanceOf(address(fund)),
            assets,
            1,
            "Vesting contract should report deposited funds"
        );
        assertApproxEqAbs(
            vesting.vestedBalanceOf(address(fund)),
            0,
            1,
            "Vesting contract should not report vested funds"
        );

        // Check tokens are in the right place
        assertEq(USDC.balanceOf(address(fund)), (totalDeposit - assets) + initialDeposit);
        assertEq(USDC.balanceOf(address(vesting)), assets);
    }

    function testUserWithdrawFromVesting(uint256 assets) external {
        assets = bound(assets, 0.1e6, totalDeposit / 10);
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);

        // Deposit % of holdings, allowed under deviation
        adaptorCalls[0] = _createBytesDataToDeposit(vesting, assets);
        data[0] = Fund.AdaptorCall({ adaptor: address(vestingAdaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        // Swap positions so vesting is first, and skip forward
        skip(vestingPeriod + 1);
        usdcMockFeed.setMockUpdatedAt(block.timestamp);
        fund.swapPositions(0, 1, false);

        // Withdraw vested positions
        fund.withdraw(assets, address(this), address(this));

        // Check state - deposited tokens withdrawn
        assertApproxEqAbs(
            vesting.totalBalanceOf(address(fund)),
            0,
            1,
            "Vesting contract should not report deposited funds"
        );
        assertApproxEqAbs(
            vesting.vestedBalanceOf(address(fund)),
            0,
            1,
            "Vesting contract should not report vested funds"
        );

        // Check tokens are in the right place
        assertApproxEqAbs(
            USDC.balanceOf(address(fund)),
            totalDeposit + initialDeposit - assets,
            1,
            "Fund should have 95% of tokens"
        );
        assertApproxEqAbs(USDC.balanceOf(address(this)), assets, 1, "User should withdraw % of tokens");

        // Swap positions back
        fund.swapPositions(0, 1, false);
    }

    function testStrategistWithdrawFromVesting(uint256 assets) external {
        assets = bound(assets, 0.1e6, totalDeposit / 10);
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);

        // Deposit % of holdings, allowed under deviation
        adaptorCalls[0] = _createBytesDataToDeposit(vesting, assets);
        data[0] = Fund.AdaptorCall({ adaptor: address(vestingAdaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        // skip forward
        skip(vestingPeriod + 1);
        usdcMockFeed.setMockUpdatedAt(block.timestamp);

        // Withdraw vested positions as part of strategy 0 - should be deposit 1
        adaptorCalls[0] = _createBytesDataToWithdraw(vesting, 1, assets);
        data[0] = Fund.AdaptorCall({ adaptor: address(vestingAdaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        // Check state - deposited tokens withdrawn
        assertApproxEqAbs(
            vesting.totalBalanceOf(address(fund)),
            0,
            1,
            "Vesting contract should not report deposited funds"
        );
        assertApproxEqAbs(
            vesting.vestedBalanceOf(address(fund)),
            0,
            1,
            "Vesting contract should not report vested funds"
        );

        // Check fund total assets is back to 100%
        assertApproxEqAbs(
            fund.totalAssets(),
            totalDeposit + initialDeposit,
            1,
            "Fund totalAssets should return to original value"
        );
    }

    function testStrategistWithdrawAnyFromVesting(uint256 assets) external {
        assets = bound(assets, 0.1e6, totalDeposit / 10);
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);

        // Deposit % of holdings, allowed under deviation
        adaptorCalls[0] = _createBytesDataToDeposit(vesting, assets);
        data[0] = Fund.AdaptorCall({ adaptor: address(vestingAdaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        // skip forward
        skip(vestingPeriod + 1);
        usdcMockFeed.setMockUpdatedAt(block.timestamp);

        // Withdraw vested positions as part of strategy 0 - no deposit specified
        adaptorCalls[0] = _createBytesDataToWithdrawAny(vesting, assets);
        data[0] = Fund.AdaptorCall({ adaptor: address(vestingAdaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        // Check state - deposited tokens withdrawn
        assertApproxEqAbs(
            vesting.totalBalanceOf(address(fund)),
            0,
            1,
            "Vesting contract should not report deposited funds"
        );
        assertApproxEqAbs(
            vesting.vestedBalanceOf(address(fund)),
            0,
            1,
            "Vesting contract should not report vested funds"
        );
        // Check fund total assets is back to 100%
        assertApproxEqAbs(
            fund.totalAssets(),
            totalDeposit + initialDeposit,
            1,
            "Fund totalAssets should return to original value"
        );
    }

    function testStrategistWithdrawAllFromVesting(uint256 assets) external {
        assets = bound(assets, 0.1e6, totalDeposit / 10);
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);

        // Deposit % of holdings, allowed under deviation
        adaptorCalls[0] = _createBytesDataToDeposit(vesting, assets);
        data[0] = Fund.AdaptorCall({ adaptor: address(vestingAdaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        uint256 totalAssetsBeforeVesting = fund.totalAssets();

        // skip forward, half of vesting period
        skip(vestingPeriod / 2);
        usdcMockFeed.setMockUpdatedAt(block.timestamp);

        // Withdraw vested positions as part of strategy 0 - no deposit specified
        adaptorCalls[0] = _createBytesDataToWithdrawAll(vesting);
        data[0] = Fund.AdaptorCall({ adaptor: address(vestingAdaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        // Check state - deposited tokens withdrawn
        assertApproxEqAbs(
            vesting.totalBalanceOf(address(fund)),
            assets / 2,
            1,
            "Vesting contract should report deposited funds"
        );
        assertApproxEqAbs(
            vesting.vestedBalanceOf(address(fund)),
            0,
            1,
            "Vesting contract should not report vested funds"
        );

        assertApproxEqAbs(
            fund.totalAssets(),
            totalAssetsBeforeVesting + assets.mulDivDown(500, 1000),
            1,
            "Fund totalAssets should regain half of deposit"
        );
    }

    function testStrategistPartialWithdrawFromVesting(uint256 assets) external {
        assets = bound(assets, 0.1e6, totalDeposit / 10);
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);

        // Deposit % of holdings, allowed under deviation
        adaptorCalls[0] = _createBytesDataToDeposit(vesting, assets);
        data[0] = Fund.AdaptorCall({ adaptor: address(vestingAdaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        // skip forward entire vesting period
        skip(vestingPeriod + 1);
        usdcMockFeed.setMockUpdatedAt(block.timestamp);

        // Withdraw vested positions as part of strategy 0 - no deposit specified
        // Only withdraw half available
        adaptorCalls[0] = _createBytesDataToWithdrawAny(vesting, assets / 2);
        data[0] = Fund.AdaptorCall({ adaptor: address(vestingAdaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        // Check state - deposited tokens withdrawn
        assertApproxEqAbs(
            vesting.totalBalanceOf(address(fund)),
            assets / 2,
            1,
            "Vesting contract should report deposited funds"
        );
        assertApproxEqAbs(
            vesting.vestedBalanceOf(address(fund)),
            assets / 2,
            1,
            "Vesting contract should report vested funds"
        );
        // Check fund total assets is back to 100%
        assertApproxEqAbs(
            fund.totalAssets(),
            totalDeposit + initialDeposit,
            1,
            "Fund totalAssets should return to original value"
        );
    }

    // ========================================= HELPER FUNCTIONS =========================================

    function _createBytesDataToDeposit(VestingSimple _vesting, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(VestingSimpleAdaptor.depositToVesting.selector, address(_vesting), amount);
    }

    function _createBytesDataToWithdraw(
        VestingSimple _vesting,
        uint256 depositId,
        uint256 amount
    ) internal pure returns (bytes memory) {
        return
            abi.encodeWithSelector(
                VestingSimpleAdaptor.withdrawFromVesting.selector,
                address(_vesting),
                depositId,
                amount
            );
    }

    function _createBytesDataToWithdrawAny(
        VestingSimple _vesting,
        uint256 amount
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(VestingSimpleAdaptor.withdrawAnyFromVesting.selector, address(_vesting), amount);
    }

    function _createBytesDataToWithdrawAll(VestingSimple _vesting) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(VestingSimpleAdaptor.withdrawAllFromVesting.selector, address(_vesting));
    }

    /// @notice Emitted when tokens are deposited for vesting.
    /// @param user The user making the deposit.
    /// @param receiver The user receiving the shares.
    /// @param amount The amount of tokens deposited.
    event VestingDeposit(address indexed user, address indexed receiver, uint256 amount);

    /// @notice Emitted when vested tokens are withdrawn.
    ///
    /// @param user The owner of the deposit.
    /// @param receiver The user receiving the deposit.
    /// @param depositId The ID of the deposit specified.
    /// @param amount The amount of tokens deposited.
    event VestingWithdraw(address indexed user, address indexed receiver, uint256 depositId, uint256 amount);

    function _emitDeposit(uint256 amount) internal {
        emit VestingDeposit(address(fund), address(fund), amount);
    }

    function _emitWithdraw(address receiver, uint256 amount, uint256 depositId) internal {
        emit VestingWithdraw(address(fund), receiver, depositId, amount);
    }
}
