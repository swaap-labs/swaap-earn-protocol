// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ReentrancyERC4626 } from "src/mocks/ReentrancyERC4626.sol";
import { SwaapFundAdaptor } from "src/modules/adaptors/Swaap/SwaapFundAdaptor.sol";
import { ERC20DebtAdaptor } from "src/mocks/ERC20DebtAdaptor.sol";
import { MockDataFeed } from "src/mocks/MockDataFeed.sol";
import { MockFund } from "src/mocks/MockFund.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";

import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";
import { FeesManager } from "src/modules/fees/FeesManager.sol";
import { MockManagementFeesLib } from "src/mocks/MockManagementFeesLib.sol";

contract FeesManagerTest is MainnetStarterTest, AdaptorHelperFunctions {
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using stdStorage for StdStorage;

    Fund private fund;
    Fund private usdcCLR;
    Fund private wethCLR;
    Fund private wbtcCLR;

    MockFund private mockFund;

    SwaapFundAdaptor private swaapFundAdaptor;
    MockManagementFeesLib private mockManagementFeesLib;

    MockDataFeed private mockUsdcUsd;
    MockDataFeed private mockWethUsd;
    MockDataFeed private mockWbtcUsd;
    MockDataFeed private mockUsdtUsd;

    uint32 private usdcPosition = 1;
    uint32 private wethPosition = 2;
    uint32 private wbtcPosition = 3;
    uint32 private usdcCLRPosition = 4;
    uint32 private wethCLRPosition = 5;
    uint32 private wbtcCLRPosition = 6;
    uint32 private usdtPosition = 7;

    uint256 private initialAssets;
    uint256 private initialShares;

    uint256 assetToSharesDecimalsFactor = 10 ** 12;

    function setUp() external {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 16869780;
        _startFork(rpcKey, blockNumber);

        // Run Starter setUp code.
        _setUp();

        mockUsdcUsd = new MockDataFeed(USDC_USD_FEED);
        mockWethUsd = new MockDataFeed(WETH_USD_FEED);
        mockWbtcUsd = new MockDataFeed(WBTC_USD_FEED);
        mockUsdtUsd = new MockDataFeed(USDT_USD_FEED);
        swaapFundAdaptor = new SwaapFundAdaptor();

        // Setup pricing
        PriceRouter.ChainlinkDerivativeStorage memory stor;

        PriceRouter.AssetSettings memory settings;

        uint256 price = uint256(mockUsdcUsd.latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, address(mockUsdcUsd));
        priceRouter.addAsset(USDC, settings, abi.encode(stor), price);

        price = uint256(mockWethUsd.latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, address(mockWethUsd));
        priceRouter.addAsset(WETH, settings, abi.encode(stor), price);

        price = uint256(mockWbtcUsd.latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, address(mockWbtcUsd));
        priceRouter.addAsset(WBTC, settings, abi.encode(stor), price);

        price = uint256(mockUsdtUsd.latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, address(mockUsdtUsd));
        priceRouter.addAsset(USDT, settings, abi.encode(stor), price);

        // Setup exchange rates:
        // USDC Simulated Price: $1
        // WETH Simulated Price: $2000
        // WBTC Simulated Price: $30,000
        mockUsdcUsd.setMockAnswer(1e8);
        mockWethUsd.setMockAnswer(2_000e8);
        mockWbtcUsd.setMockAnswer(30_000e8);
        mockUsdtUsd.setMockAnswer(1e8);

        // Add adaptors and ERC20 positions to the registry.
        registry.trustAdaptor(address(swaapFundAdaptor));
        registry.trustPosition(usdcPosition, address(erc20Adaptor), abi.encode(USDC));
        registry.trustPosition(wethPosition, address(erc20Adaptor), abi.encode(WETH));
        registry.trustPosition(wbtcPosition, address(erc20Adaptor), abi.encode(WBTC));
        registry.trustPosition(usdtPosition, address(erc20Adaptor), abi.encode(USDT));

        // Create Dummy Funds.
        string memory fundName = "Dummy Fund V0.0";
        uint256 initialDeposit = 1e6;

        usdcCLR = _createFund(fundName, USDC, usdcPosition, abi.encode(true), initialDeposit);
        vm.label(address(usdcCLR), "usdcCLR");

        fundName = "Dummy Fund V0.1";
        initialDeposit = 1e12;
        wethCLR = _createFund(fundName, WETH, wethPosition, abi.encode(true), initialDeposit);
        vm.label(address(wethCLR), "wethCLR");

        fundName = "Dummy Fund V0.2";
        initialDeposit = 1e4;
        wbtcCLR = _createFund(fundName, WBTC, wbtcPosition, abi.encode(true), initialDeposit);
        vm.label(address(wbtcCLR), "wbtcCLR");

        // Add Fund Positions to the registry.
        registry.trustPosition(usdcCLRPosition, address(swaapFundAdaptor), abi.encode(usdcCLR));
        registry.trustPosition(wethCLRPosition, address(swaapFundAdaptor), abi.encode(wethCLR));
        registry.trustPosition(wbtcCLRPosition, address(swaapFundAdaptor), abi.encode(wbtcCLR));

        fundName = "Fund V0.0";
        initialDeposit = 1e6;
        fund = _createFund(fundName, USDC, usdcPosition, abi.encode(true), initialDeposit);

        // Set up remaining fund positions.
        fund.addPositionToCatalogue(usdcCLRPosition);
        fund.addPosition(1, usdcCLRPosition, abi.encode(true), false);
        fund.addPositionToCatalogue(wethCLRPosition);
        fund.addPosition(2, wethCLRPosition, abi.encode(true), false);
        fund.addPositionToCatalogue(wbtcCLRPosition);
        fund.addPosition(3, wbtcCLRPosition, abi.encode(true), false);
        fund.addPositionToCatalogue(wethPosition);
        fund.addPosition(4, wethPosition, abi.encode(true), false);
        fund.addPositionToCatalogue(wbtcPosition);
        fund.addPosition(5, wbtcPosition, abi.encode(true), false);
        fund.addAdaptorToCatalogue(address(swaapFundAdaptor));
        fund.addPositionToCatalogue(usdtPosition);

        vm.label(address(fund), "fund");
        vm.label(strategist, "strategist");

        // Approve fund to spend all assets.
        USDC.approve(address(fund), type(uint256).max);

        initialAssets = fund.totalAssets();
        initialShares = fund.totalSupply();

        mockManagementFeesLib = new MockManagementFeesLib();
    }

    // ===================================== FEES SETTERS TEST =====================================
    function testRevertOnWrongFeesInputs() external {
        FeesManager feesManager = FeesManager(fund.FEES_MANAGER());

        vm.expectRevert(FeesManager.FeesManager__InvalidFeesRate.selector);
        feesManager.setManagementFeesPerYear(address(fund), Math.WAD);

        vm.expectRevert(FeesManager.FeesManager__InvalidFeesRate.selector);
        feesManager.setPerformanceFees(address(fund), Math.WAD);

        vm.expectRevert(FeesManager.FeesManager__InvalidFeesRate.selector);
        feesManager.setEnterFees(address(fund), 10000);

        vm.expectRevert(FeesManager.FeesManager__InvalidFeesRate.selector);
        feesManager.setExitFees(address(fund), 10000);

        vm.expectRevert(FeesManager.FeesManager__InvalidFeesCut.selector);
        feesManager.setStrategistPlatformCut(address(fund), uint64(Math.WAD + 1));
    }

    function testRevertOnWrongCaller() external {
        FeesManager feesManager = FeesManager(fund.FEES_MANAGER());

        // set fund owner different than address(this)
        address fundOwner = address(0xa11ce);
        fund.transferOwnership(address(fundOwner));

        vm.expectRevert(FeesManager.FeesManager__OnlyFundOwner.selector);
        feesManager.setManagementFeesPerYear(address(fund), 0);

        vm.expectRevert(FeesManager.FeesManager__OnlyFundOwner.selector);
        feesManager.setPerformanceFees(address(fund), 0);

        vm.expectRevert(FeesManager.FeesManager__OnlyFundOwner.selector);
        feesManager.setEnterFees(address(fund), 0);

        vm.expectRevert(FeesManager.FeesManager__OnlyFundOwner.selector);
        feesManager.setExitFees(address(fund), 0);

        vm.expectRevert(FeesManager.FeesManager__OnlyFundOwner.selector);
        feesManager.setStrategistPayoutAddress(address(fund), address(this));

        vm.prank(fundOwner);
        vm.expectRevert(FeesManager.FeesManager__OnlyRegistryOwner.selector);
        feesManager.setStrategistPlatformCut(address(fund), 0);

        vm.prank(fundOwner);
        vm.expectRevert(FeesManager.FeesManager__OnlyRegistryOwner.selector);
        feesManager.setProtocolPayoutAddress(fundOwner);

        vm.prank(fundOwner);
        vm.expectRevert(FeesManager.FeesManager__OnlyRegistryOwner.selector);
        feesManager.resetHighWaterMark(address(fund));
    }

    function testFeesPayoutWithStrategistAddressAndCutUnset() external {
        FeesManager feesManager = FeesManager(fund.FEES_MANAGER());

        uint256 accruedFees = initialShares / 2;

        // send some shares to the fees manager to simulate already collected fees
        deal(address(fund), address(feesManager), accruedFees, true);

        // do the payout with strategist payout and strategist cut set to 0
        vm.prank(address(0x1)); // any address should be able to start the payout
        feesManager.payoutFees(address(fund));

        assertEq(fund.balanceOf(address(feesManager)), 0, "Fees manager should own 0% of the fund after the payout.");

        assertEq(fund.balanceOf(address(0)), 0, "Address(0) should own 0% of the fund after the payout.");

        assertEq(
            fund.balanceOf(feesManager.protocolPayoutAddress()),
            accruedFees,
            "Protocl should own 100% of the fund fees after the payout."
        );
    }

    function testFeesPayoutWithStrategistAddressUnset() external {
        FeesManager feesManager = FeesManager(fund.FEES_MANAGER());

        uint64 strategistCut = 30e16; // 30%

        feesManager.setStrategistPlatformCut(address(fund), strategistCut);

        uint256 accruedFees = initialShares / 2;

        // send some shares to the fees manager to simulate already collected fees
        deal(address(fund), address(feesManager), accruedFees, true);

        // do the payout with strategist payout and strategist cut set to 0
        vm.prank(address(0x1)); // any address should be able to start the payout
        feesManager.payoutFees(address(fund));

        assertEq(fund.balanceOf(address(feesManager)), 0, "Fees manager should own 0% of the fund after the payout.");

        assertEq(fund.balanceOf(address(0)), 0, "Address(0) should own 0% of the fund after the payout.");

        assertEq(
            fund.balanceOf(feesManager.protocolPayoutAddress()),
            accruedFees,
            "Protocl should own 100% of the fund fees after the payout."
        );
    }

    function testFeesPayoutWithStrategistPayoutAndCutSet() external {
        FeesManager feesManager = FeesManager(fund.FEES_MANAGER());

        uint64 strategistCut = 30e16; // 30%

        address strategistPayoutAddress = address(0xa11ce);

        feesManager.setStrategistPlatformCut(address(fund), strategistCut);
        feesManager.setStrategistPayoutAddress(address(fund), strategistPayoutAddress);

        uint256 accruedFees = initialShares / 2;

        // send some shares to the fees manager to simulate already collected fees
        deal(address(fund), address(feesManager), accruedFees, true);

        // do the payout with strategist payout and strategist cut set to 0
        vm.prank(address(0x1)); // any address should be able to start the payout
        feesManager.payoutFees(address(fund));

        assertEq(fund.balanceOf(address(feesManager)), 0, "Fees manager should own 0% of the fund after the payout.");

        assertEq(fund.balanceOf(address(0)), 0, "Address(0) should own 0% of the fund after the payout.");

        uint256 expectedStrategistPayout = accruedFees.mulDivUp(strategistCut, Math.WAD);

        assertEq(
            fund.balanceOf(strategistPayoutAddress),
            expectedStrategistPayout,
            "Strategist should own 30% of the fund fees after the payout."
        );

        assertEq(
            fund.balanceOf(feesManager.protocolPayoutAddress()),
            accruedFees - expectedStrategistPayout,
            "Protocl should own 70% of the fund fees after the payout."
        );
    }

    function testUpdateFeesRatesCorrectly() external {
        FeesManager feesManager = FeesManager(fund.FEES_MANAGER());

        FeesManager.FeesData memory expectedFeesData = FeesManager.FeesData({
            enterFeesRate: 0, // in bps (max value = 10000)
            exitFeesRate: 0, // in bps (max value = 10000)
            previousManagementFeesClaimTime: 0, // last management fees claim time
            managementFeesRate: 0,
            performanceFeesRate: 0,
            highWaterMarkPrice: 0,
            highWaterMarkResetTime: 0, // the owner can choose to reset the high-water mark (at most every HIGH_WATERMARK_RESET_INTERVAL)
            highWaterMarkResetAssets: 0, // the owner can choose to reset the high-water mark (every HIGH_WATERMARK_RESET_ASSETS changes of tvl)
            strategistPlatformCut: 0, // the platform cut for the strategist in 18 decimals
            strategistPayoutAddress: address(0)
        });

        address expectedProtocolPayoutAddress = registry.owner();

        _assertEqFeesData(
            feesManager.getFundFeesData(address(fund)),
            expectedFeesData,
            feesManager.protocolPayoutAddress(),
            expectedProtocolPayoutAddress
        );

        // setters work well
        feesManager.setManagementFeesPerYear(address(fund), 2.5e16);
        expectedFeesData.managementFeesRate = uint48(mockManagementFeesLib.calcYearlyRate(2.5e16));
        expectedFeesData.previousManagementFeesClaimTime = uint40(block.timestamp);

        _assertEqFeesData(
            feesManager.getFundFeesData(address(fund)),
            expectedFeesData,
            feesManager.protocolPayoutAddress(),
            expectedProtocolPayoutAddress
        );

        feesManager.setPerformanceFees(address(fund), 12e15);
        expectedFeesData.performanceFeesRate = 12e15;
        expectedFeesData.highWaterMarkPrice = uint72(fund.totalAssets().mulDivDown(Math.WAD, fund.totalSupply()));
        expectedFeesData.highWaterMarkResetTime = uint40(block.timestamp);
        _assertEqFeesData(
            feesManager.getFundFeesData(address(fund)),
            expectedFeesData,
            feesManager.protocolPayoutAddress(),
            expectedProtocolPayoutAddress
        );

        feesManager.setEnterFees(address(fund), 6);
        expectedFeesData.enterFeesRate = 6;
        _assertEqFeesData(
            feesManager.getFundFeesData(address(fund)),
            expectedFeesData,
            feesManager.protocolPayoutAddress(),
            expectedProtocolPayoutAddress
        );

        feesManager.setExitFees(address(fund), 7);
        expectedFeesData.exitFeesRate = 7;
        _assertEqFeesData(
            feesManager.getFundFeesData(address(fund)),
            expectedFeesData,
            feesManager.protocolPayoutAddress(),
            expectedProtocolPayoutAddress
        );

        feesManager.setStrategistPlatformCut(address(fund), 30e16);
        expectedFeesData.strategistPlatformCut = 30e16;

        _assertEqFeesData(
            feesManager.getFundFeesData(address(fund)),
            expectedFeesData,
            feesManager.protocolPayoutAddress(),
            expectedProtocolPayoutAddress
        );

        feesManager.setStrategistPayoutAddress(address(fund), address(0x0a11ce));
        expectedFeesData.strategistPayoutAddress = address(0x0a11ce);

        _assertEqFeesData(
            feesManager.getFundFeesData(address(fund)),
            expectedFeesData,
            feesManager.protocolPayoutAddress(),
            expectedProtocolPayoutAddress
        );

        address newPayoutAddress = address(0xb0b);
        feesManager.setProtocolPayoutAddress(newPayoutAddress);

        _assertEqFeesData(
            feesManager.getFundFeesData(address(fund)),
            expectedFeesData,
            newPayoutAddress,
            newPayoutAddress
        );
    }

    function testCollectFeesWhenSettingManagementFees() external {
        FeesManager feesManager = FeesManager(fund.FEES_MANAGER());

        uint256 oldManagementFeesPerYear = Math.WAD / 100; // 1%

        feesManager.setManagementFeesPerYear(address(fund), oldManagementFeesPerYear); // 1%

        assertEq(
            fund.balanceOf(address(feesManager)),
            0,
            "Fees manager should own 0% of the total supply when setting the management fees initially."
        );

        _moveForwardAndUpdateOracle(365 days);

        // set management fees differently from old value for the test
        uint256 newManagementFeesPerYear = oldManagementFeesPerYear * 2;
        feesManager.setManagementFeesPerYear(address(fund), newManagementFeesPerYear); // 1%

        uint256 expectedSharesReceived = (initialShares * oldManagementFeesPerYear) /
            (Math.WAD - oldManagementFeesPerYear);

        assertApproxEqRel(
            fund.balanceOf(address(feesManager)),
            expectedSharesReceived,
            1e12,
            "Fees manager should own 1% of the total supply after collecting fees."
        );

        assertApproxEqRel(
            (fund.balanceOf(address(feesManager)) * Math.WAD) / fund.totalSupply(),
            oldManagementFeesPerYear,
            1e12,
            "Fees manager should own 1% of the total supply after collecting fees."
        );
    }

    function testCollectFeesWhenSettingPerformanceFees() external {
        FeesManager feesManager = FeesManager(fund.FEES_MANAGER());

        uint256 oldPerformanceFees = Math.WAD / 10; // 10%

        feesManager.setPerformanceFees(address(fund), oldPerformanceFees); // 1%

        assertEq(
            fund.balanceOf(address(feesManager)),
            0,
            "Fees manager should own 0% of the total supply when setting the performance fees initially."
        );

        // set performance to 30%
        uint256 performance = 30e16;
        deal(address(fund.asset()), address(fund), initialAssets + initialAssets.mulDivDown(performance, Math.WAD));

        // set performanceFees differently from old value for the test
        uint256 newPerformanceFees = 20e16; // 20%

        feesManager.setPerformanceFees(address(fund), newPerformanceFees); // 1%

        uint256 expectedAssetsReceived = (initialAssets * performance * oldPerformanceFees) / Math.WAD / Math.WAD;

        assertApproxEqAbs(
            fund.maxWithdraw(address(feesManager)),
            expectedAssetsReceived,
            1,
            "Fees manager should own the correct amount of assets after resetting the performance fees."
        );
    }

    // ========================================= FEES TEST =========================================
    function testCollectFeesFromFund() external {
        FeesManager feesManager = FeesManager(fund.FEES_MANAGER());
        uint256 managementFeesPerYear = Math.WAD / 100; // 1%

        feesManager.setManagementFeesPerYear(address(fund), managementFeesPerYear); // 1%

        assertEq(
            fund.balanceOf(address(feesManager)),
            0,
            "Fees manager should own 0% of the total supply when setting the management fees initially."
        );

        _moveForwardAndUpdateOracle(365 days);

        // minting new shares should trigger fees.
        vm.prank(address(0xa11ce)); // anyone should be able to start fees minting
        fund.collectFees();

        uint256 expectedSharesReceived = (initialShares * managementFeesPerYear) / (Math.WAD - managementFeesPerYear);

        assertApproxEqRel(
            fund.balanceOf(address(feesManager)),
            expectedSharesReceived,
            1e12,
            "Fees manager should own 1% of the total supply after collecting fees."
        );

        assertApproxEqRel(
            (fund.balanceOf(address(feesManager)) * Math.WAD) / fund.totalSupply(),
            managementFeesPerYear,
            1e12,
            "Fees manager should own 1% of the total supply after collecting fees."
        );
    }

    function testManagementFeesEnterHook() external {
        uint256 newShares = 1e18;

        FeesManager feesManager = FeesManager(fund.FEES_MANAGER());
        uint256 managementFeesPerYear = (Math.WAD / 100) * 2; // 2%

        uint256 previewMintAssetsWithoutFees = fund.previewMint(newShares);

        feesManager.setManagementFeesPerYear(address(fund), managementFeesPerYear);

        assertEq(
            fund.balanceOf(address(feesManager)),
            0,
            "Fees manager should own 0% of the total supply when setting the management fees initially."
        );

        _moveForwardAndUpdateOracle(365 days);

        // minting new shares should trigger fees.
        uint256 previewMintAssets = fund.previewMint(newShares);
        deal(address(fund.asset()), address(this), previewMintAssets);

        uint256 expectedPreviewMintAssets = (previewMintAssetsWithoutFees * (Math.WAD - managementFeesPerYear)) /
            Math.WAD;

        assertApproxEqRel(
            previewMintAssets,
            expectedPreviewMintAssets,
            1e15,
            "Fees should should own 2% of the total supply before the mint."
        );

        uint256 totalSupplyBeforeMint = fund.totalSupply();
        fund.mint(newShares, address(this));

        uint256 expectedSharesReceived = (totalSupplyBeforeMint * managementFeesPerYear) /
            (Math.WAD - managementFeesPerYear);

        assertApproxEqRel(
            fund.balanceOf(address(feesManager)),
            expectedSharesReceived,
            1e15,
            "Fees manager should own 2% of the total supply before the mint."
        );

        _moveForwardAndUpdateOracle(365 days);

        // depositing new assets trigger fees.
        uint256 feeManagerSharesBeforeDeposit = fund.balanceOf(address(feesManager));
        uint256 totalSupplyBeforeDeposit = fund.totalSupply();

        uint256 newAssets = 1e18;
        deal(address(fund.asset()), address(this), newAssets);
        newShares = fund.deposit(newAssets, address(this));

        uint256 feeManageReceivedSharesAfterDeposit = fund.balanceOf(address(feesManager)) -
            feeManagerSharesBeforeDeposit;

        expectedSharesReceived =
            (totalSupplyBeforeDeposit * managementFeesPerYear) /
            (Math.WAD - managementFeesPerYear);

        assertApproxEqRel(
            feeManageReceivedSharesAfterDeposit,
            expectedSharesReceived,
            1e12,
            "Fees manager should own 2% of the new shares after the deposit."
        );
    }

    function testPerformanceFeesMintHook() external {
        FeesManager feesManager = FeesManager(fund.FEES_MANAGER());
        uint256 performanceFees = Math.WAD / 5; // 20%

        feesManager.setPerformanceFees(address(fund), performanceFees); // 1%

        assertEq(
            fund.balanceOf(address(feesManager)),
            0,
            "Fees manager should own 0% of the fund when setting performance fees."
        );

        FeesManager.FeesData memory feeData = feesManager.getFundFeesData(address(fund));

        assertEq(
            feeData.highWaterMarkPrice,
            fund.totalAssets().mulDivDown(Math.WAD, fund.totalSupply()),
            "high-water mark price should be set to the initial share price."
        );

        assertEq(feeData.performanceFeesRate, performanceFees, "Performance fees should be set to 20%.");

        // setting the performance to 50%
        uint256 newAssets = fund.totalAssets() / 2;
        deal(address(fund.asset()), address(fund), fund.asset().balanceOf(address(fund)) + newAssets);

        // minting new shares should trigger fees.
        uint256 newShares = 1e18;
        deal(address(fund.asset()), address(this), fund.previewMint(newShares));
        fund.mint(newShares, address(this));

        uint256 expectedFeeManagerAssets = (newAssets * performanceFees) / Math.WAD;

        assertApproxEqAbs(
            fund.maxWithdraw(address(feesManager)),
            expectedFeeManagerAssets,
            1,
            "Fees manager should own 20% of new assets as performance fees."
        );
    }

    function testPerformanceFeesDepositHook() external {
        uint256 depositAssets = 1e18;

        FeesManager feesManager = FeesManager(fund.FEES_MANAGER());
        uint256 performanceFees = Math.WAD / 5; // 20%

        feesManager.setPerformanceFees(address(fund), performanceFees);

        assertEq(
            fund.balanceOf(address(feesManager)),
            0,
            "Fees manager should own 0% of the fund when setting performance fees."
        );

        FeesManager.FeesData memory feeData = feesManager.getFundFeesData(address(fund));

        assertEq(
            feeData.highWaterMarkPrice,
            fund.totalAssets().mulDivDown(Math.WAD, fund.totalSupply()),
            "high-water mark price should be set to the initial share price."
        );

        assertEq(feeData.performanceFeesRate, performanceFees, "Performance fees should be set to 20%.");

        uint256 previewDepositSharesBeforePerformance = fund.previewDeposit(depositAssets);
        assertApproxEqAbs(previewDepositSharesBeforePerformance, 10 ** 30, 1, "Expected shares is 10**30");

        // setting the performance to 50%
        uint256 newAssets = fund.totalAssets() / 2;
        deal(address(fund.asset()), address(fund), fund.asset().balanceOf(address(fund)) + newAssets);

        // depositing new shares should trigger fees.
        uint256 totalAssets = fund.asset().balanceOf(address(fund));
        uint256 totalSupply = fund.totalSupply();
        uint256 foo = performanceFees * newAssets;
        uint256 feesAsShares = (foo * totalSupply) / (totalAssets * Math.WAD - foo);

        uint256 previewDepositShares = fund.previewDeposit(depositAssets);

        uint256 expectedPreviewDepositShares = (depositAssets / totalAssets) * (totalSupply + feesAsShares);

        assertApproxEqAbs(
            previewDepositShares,
            expectedPreviewDepositShares,
            1e20,
            "Preview deposit should yield the proper shares number"
        );

        deal(address(fund.asset()), address(this), depositAssets);
        fund.deposit(depositAssets, address(this));

        uint256 expectedFeeManagerAssets = (newAssets * performanceFees) / Math.WAD;

        assertApproxEqAbs(
            fund.maxWithdraw(address(feesManager)),
            expectedFeeManagerAssets,
            1,
            "Fees manager should own 20% of new assets as performance fees."
        );
    }

    function testPerformanceFeesRedeemHook() external {
        FeesManager feesManager = FeesManager(fund.FEES_MANAGER());
        uint256 performanceFees = Math.WAD / 5; // 20%

        feesManager.setPerformanceFees(address(fund), performanceFees); // 1%

        assertEq(
            fund.balanceOf(address(feesManager)),
            0,
            "Fees manager should own 0% of the fund when setting performance fees."
        );

        FeesManager.FeesData memory feeData = feesManager.getFundFeesData(address(fund));

        assertEq(
            feeData.highWaterMarkPrice,
            fund.totalAssets().mulDivDown(Math.WAD, fund.totalSupply()),
            "high-water mark price should be set to the initial share price."
        );

        assertEq(feeData.performanceFeesRate, performanceFees, "Performance fees should be set to 20%.");

        // setting balances
        deal(address(fund), address(this), initialShares);
        deal(address(fund.asset()), address(this), 0);

        // setting the performance to 30%
        uint256 newAssets = (initialAssets * 30) / 100;
        deal(address(fund.asset()), address(fund), initialAssets + newAssets);

        // redeeming shares should trigger fees.
        uint256 redeemShares = initialShares / 3;
        fund.redeem(redeemShares, address(this), address(this));

        uint256 expectedFeeManagerAssets = (newAssets * performanceFees) / Math.WAD;

        assertApproxEqAbs(
            fund.maxWithdraw(address(feesManager)),
            expectedFeeManagerAssets,
            1,
            "Fees manager should own 20% of new assets as performance fees."
        );

        assertApproxEqAbs(
            fund.asset().balanceOf(address(this)),
            (((initialAssets + newAssets) - expectedFeeManagerAssets) * redeemShares) / initialShares,
            1,
            "User should receive the correct amount of assets after exit with performance fees on."
        );
    }

    function testPerformanceFeesWithdrawHook() external {
        FeesManager feesManager = FeesManager(fund.FEES_MANAGER());
        uint256 performanceFees = Math.WAD / 5; // 20%

        feesManager.setPerformanceFees(address(fund), performanceFees); // 1%

        assertEq(
            fund.balanceOf(address(feesManager)),
            0,
            "Fees manager should own 0% of the fund when setting performance fees."
        );

        FeesManager.FeesData memory feeData = feesManager.getFundFeesData(address(fund));

        assertEq(
            feeData.highWaterMarkPrice,
            fund.totalAssets().mulDivDown(Math.WAD, fund.totalSupply()),
            "high-water mark price should be set to the initial share price."
        );

        assertEq(feeData.performanceFeesRate, performanceFees, "Performance fees should be set to 20%.");

        // setting balances
        deal(address(fund), address(this), initialShares); // giving user fund shares ownership
        deal(address(fund.asset()), address(this), 0);

        // setting the performance to 30%
        uint256 newAssets = (initialAssets * 30) / 100;
        deal(address(fund.asset()), address(fund), initialAssets + newAssets);

        // fund new total assets
        uint256 newTotalAssets = initialAssets + newAssets;

        // depositing new shares should trigger fees.
        uint256 withdrawAssets = initialAssets / 3;
        fund.withdraw(withdrawAssets, address(this), address(this));

        uint256 expectedFeeManagerAssets = (newAssets * performanceFees) / Math.WAD;

        assertApproxEqAbs(
            fund.maxWithdraw(address(feesManager)),
            expectedFeeManagerAssets,
            1,
            "Fees manager should own 20% of the new assets as performance fees."
        );

        uint256 userBurnedShares = initialShares - fund.balanceOf(address(this));
        assertApproxEqAbs(
            userBurnedShares,
            (withdrawAssets * (initialShares + fund.balanceOf(address(feesManager)))) / newTotalAssets,
            1,
            "User should burn the correct amount of shares after exit with performance fees on."
        );
    }

    function testEnterFeesMintHook() external {
        FeesManager feesManager = FeesManager(fund.FEES_MANAGER());
        uint256 _ONE_HUNDRED_PERCENT = 10000;
        uint16 enterFees = uint16(_ONE_HUNDRED_PERCENT / 100); // 1%

        uint256 sharesToMint = 1e18;
        uint256 depositAssetsWithNoFees = fund.previewMint(sharesToMint);

        uint256 initUserAssetBalance = depositAssetsWithNoFees * 2;
        deal(address(fund.asset()), address(this), initUserAssetBalance);

        feesManager.setEnterFees(address(fund), enterFees); // 1%

        assertEq(
            fund.balanceOf(address(feesManager)),
            0,
            "Fees manager should own 0% of the fund when setting enter fees."
        );

        // set address(this) fund shares balance to 0 for the test
        deal(address(fund), address(this), 0);

        // minting new shares should trigger fees.
        uint256 totalSupplyBeforeMint = fund.totalSupply();

        uint256 previewDepositedAssets = fund.previewMint(sharesToMint);
        fund.mint(sharesToMint, address(this));

        uint256 mintedShares = fund.totalSupply() - totalSupplyBeforeMint;

        assertEq(mintedShares, sharesToMint, "Mint should mint the correct amount of shares when enter fees are on.");

        assertEq(
            previewDepositedAssets,
            initUserAssetBalance - fund.asset().balanceOf(address(this)),
            "Mint and previewMint should give the same result when enter fees are on."
        );

        assertEq(
            fund.balanceOf(address(this)),
            sharesToMint,
            "Mint should mint the correct amount of shares to the user when enter fees are on."
        );

        assertEq(fund.balanceOf(address(feesManager)), 0, "Fees manager should not receive the enter fees.");

        assertGt(
            initUserAssetBalance - fund.asset().balanceOf(address(this)),
            fund.balanceOf(address(feesManager)),
            "User should deposit more assets after minting with enter fees."
        );

        assertApproxEqAbs(
            initUserAssetBalance - fund.asset().balanceOf(address(this)),
            (depositAssetsWithNoFees * (_ONE_HUNDRED_PERCENT + enterFees)) / _ONE_HUNDRED_PERCENT,
            1,
            "Fund should receive the correct amount of assets after minting with enter fees."
        );
    }

    function testEnterFeesDepositHook() external {
        FeesManager feesManager = FeesManager(fund.FEES_MANAGER());
        uint256 _ONE_HUNDRED_PERCENT = 1e4;
        uint16 enterFees = uint16(_ONE_HUNDRED_PERCENT / 100); // 1%

        uint256 assetsToDeposit = 1e18;
        uint256 mintedSharesWithNoFees = fund.previewDeposit(assetsToDeposit);
        deal(address(fund.asset()), address(this), assetsToDeposit);

        feesManager.setEnterFees(address(fund), enterFees); // 1%

        assertEq(
            fund.balanceOf(address(feesManager)),
            0,
            "Fees manager should own 0% of the fund when setting enter fees."
        );

        // set address(this) fund shares balance to 0 for the test
        deal(address(fund), address(this), 0);

        // deposit new shares should trigger fees.
        uint256 previewMintedShares = fund.previewDeposit(assetsToDeposit);
        fund.deposit(assetsToDeposit, address(this));

        assertEq(
            previewMintedShares,
            fund.balanceOf(address(this)),
            "Deposit and previewDeposit should give the same result when enter fees are on."
        );

        assertEq(
            fund.asset().balanceOf(address(this)), // if no balance is remaining, the deposit used the correct amount of assets
            0,
            "Deposit should use the correct amount of assets when enter fees are on."
        );

        assertEq(fund.balanceOf(address(feesManager)), 0, "Fees manager should not receive the enter fees.");

        assertLt(
            fund.balanceOf(address(this)),
            mintedSharesWithNoFees,
            "Deposit should mint less shares to the user when enter fees are set."
        );

        assertApproxEqAbs(
            fund.balanceOf(address(this)),
            (mintedSharesWithNoFees * _ONE_HUNDRED_PERCENT) / (_ONE_HUNDRED_PERCENT + enterFees),
            1,
            "Deposit should mint the correct amount of shares to the user when enter fees are on."
        );
    }

    function testDepositAndMintSharePriceAreEqualWithEnterFeesOn() external {
        FeesManager feesManager = FeesManager(fund.FEES_MANAGER());
        uint256 _ONE_HUNDRED_PERCENT = 1e4;
        uint16 enterFees = uint16(_ONE_HUNDRED_PERCENT / 100); // 1%

        feesManager.setEnterFees(address(fund), enterFees); // 1%

        uint256 assetsToDeposit = 1e18;
        uint256 mintedSharesOnDeposit = fund.previewDeposit(assetsToDeposit);

        uint256 sharesToMint = mintedSharesOnDeposit;
        uint256 assetsEnteredOnMint = fund.previewMint(sharesToMint);

        assertApproxEqAbs(
            assetsEnteredOnMint,
            assetsToDeposit,
            1,
            "Mint and deposit should have the same bought share price when etner fees are on."
        );
    }

    function testExitFeesRedeemHook(uint16 exitFees) external {
        FeesManager feesManager = FeesManager(fund.FEES_MANAGER());
        uint256 _ONE_HUNDRED_PERCENT = 10000;

        // bound between 0.01% and 10%
        exitFees = uint16(bound(exitFees, _ONE_HUNDRED_PERCENT / 10000, _ONE_HUNDRED_PERCENT / 10));

        uint256 initUserShares = initialShares;
        deal(address(fund), address(this), initUserShares);
        // make sure initial shares are not 0
        assertGt(initUserShares, 0, "Initial shares should not be 0.");

        uint256 sharesToRedeem = initUserShares / 3;
        uint256 assetsReceivedWithNoFees = fund.previewRedeem(sharesToRedeem);

        feesManager.setExitFees(address(fund), exitFees);

        assertEq(
            fund.balanceOf(address(feesManager)),
            0,
            "Fees manager should own 0% of the fund when setting exit fees."
        );

        // set address(this) fund asset balance to 0 for the test
        deal(address(fund.asset()), address(this), 0);

        // minting new shares should trigger fees.
        uint256 totalSupplyBeforeRedeem = fund.totalSupply();
        uint256 previewReceivedAssets = fund.previewRedeem(sharesToRedeem);

        fund.redeem(sharesToRedeem, address(this), address(this));
        uint256 burnedShares = totalSupplyBeforeRedeem - fund.totalSupply();

        assertEq(
            previewReceivedAssets,
            fund.asset().balanceOf(address(this)),
            "Redeem and previewRedeem should give the same result with exit fees on."
        );

        assertEq(
            sharesToRedeem,
            burnedShares,
            "Redeem should burn the correct amount of shares when exit fees are on."
        );

        assertEq(
            fund.balanceOf(address(this)),
            initUserShares - sharesToRedeem,
            "Redeem should burn the correct amount of shares to the user when exit fees are on."
        );

        assertEq(fund.balanceOf(address(feesManager)), 0, "Fees manager should not receive the exit fees.");

        assertLt(
            fund.asset().balanceOf(address(this)),
            assetsReceivedWithNoFees,
            "User should receive less assets after redeem with exit fees."
        );

        assertApproxEqAbs(
            fund.asset().balanceOf(address(this)), // received assets
            (assetsReceivedWithNoFees * (_ONE_HUNDRED_PERCENT - exitFees)) / _ONE_HUNDRED_PERCENT,
            1,
            "User should receive the correct amount of assets after redeem with exit fees."
        );
    }

    function testExitFeesWithdrawHook(uint16 exitFees) external {
        FeesManager feesManager = FeesManager(fund.FEES_MANAGER());
        uint256 _ONE_HUNDRED_PERCENT = 1e4;

        // bound between 0.01% and 10%
        exitFees = uint16(bound(exitFees, _ONE_HUNDRED_PERCENT / 10000, _ONE_HUNDRED_PERCENT / 10));

        uint256 assetsToWithdraw = initialAssets / 3;
        // giving shares ownership to the user
        deal(address(fund), address(this), initialShares);

        feesManager.setExitFees(address(fund), exitFees);

        assertEq(
            fund.balanceOf(address(feesManager)),
            0,
            "Fees manager should own 0% of the fund when setting exit fees."
        );

        // withdraw assets should trigger fees.
        uint256 previewBurnedShares = fund.previewWithdraw(assetsToWithdraw);
        fund.withdraw(assetsToWithdraw, address(this), address(this));

        assertEq(
            previewBurnedShares,
            initialShares - fund.balanceOf(address(this)),
            "Withdraw and previewWithdraw should give the same result when exit fees are on."
        );

        assertEq(
            fund.asset().balanceOf(address(fund)),
            initialAssets - assetsToWithdraw,
            "Withdraw should remove the correct amount of assets from the fund when exit fees are on."
        );

        assertEq(
            fund.asset().balanceOf(address(this)),
            assetsToWithdraw,
            "Withdraw should give the correct amount of assets from the user when exit fees are on."
        );

        assertEq(fund.balanceOf(address(feesManager)), 0, "Fees manager should not receive the exit fees.");

        assertGt(
            initialShares - fund.balanceOf(address(this)),
            (assetsToWithdraw * initialShares) / initialAssets,
            "User should burn more shares during withdraw when exit fees are set."
        );

        assertApproxEqRel(
            initialShares - fund.balanceOf(address(this)),
            (assetsToWithdraw * initialShares * _ONE_HUNDRED_PERCENT) /
                (initialAssets * (_ONE_HUNDRED_PERCENT - exitFees)),
            1e1,
            "Withdraw should burn the correct amount of shares to the user when exit fees are on."
        );
    }

    function testWithdrawAndRedeemSharePriceAreEqualWithExitFeesOn(
        uint256 receivedAssetsOnWithdraw,
        uint16 exitFees
    ) external {
        FeesManager feesManager = FeesManager(fund.FEES_MANAGER());
        uint256 _ONE_HUNDRED_PERCENT = 1e4;

        // bound between 0.01% and 10%
        exitFees = uint16(bound(exitFees, _ONE_HUNDRED_PERCENT / 10000, _ONE_HUNDRED_PERCENT / 10));
        receivedAssetsOnWithdraw = bound(receivedAssetsOnWithdraw, 1, initialAssets);

        feesManager.setExitFees(address(fund), exitFees);

        uint256 burnedSharesOnWithdraw = fund.previewWithdraw(receivedAssetsOnWithdraw);

        uint256 burnedSharesOnRedeem = burnedSharesOnWithdraw;
        uint256 receivedAssetsOnRedeem = fund.previewRedeem(burnedSharesOnRedeem);

        assertApproxEqAbs(
            burnedSharesOnRedeem,
            burnedSharesOnWithdraw,
            1,
            "Burned shares should be the same on redeem and withdraw when exit fees are on."
        );

        assertApproxEqAbs(
            receivedAssetsOnRedeem,
            receivedAssetsOnWithdraw,
            1,
            "Received assets should be the same on redeem and withdraw when exit fees are on."
        );
    }

    function _moveForwardAndUpdateOracle(uint256 delayTimestamp) internal {
        skip(delayTimestamp);
        mockUsdcUsd.setMockUpdatedAt(block.timestamp);
        mockWethUsd.setMockUpdatedAt(block.timestamp);
        mockWbtcUsd.setMockUpdatedAt(block.timestamp);
    }

    function _assertEqFeesData(
        FeesManager.FeesData memory data,
        FeesManager.FeesData memory expectedData,
        address protocolPayoutAddress,
        address expectedProtocolPayoutAddress
    ) internal {
        assertEq(data.enterFeesRate, expectedData.enterFeesRate, "Enter fees does not match with expected.");
        assertEq(data.exitFeesRate, expectedData.exitFeesRate, "Exit fees does not match with expected.");
        assertEq(
            data.previousManagementFeesClaimTime,
            expectedData.previousManagementFeesClaimTime,
            "Previous management fees claim time does not match with expected."
        );
        assertEq(
            data.managementFeesRate,
            expectedData.managementFeesRate,
            "Management fees does not match with expected."
        );
        assertEq(
            data.highWaterMarkPrice,
            expectedData.highWaterMarkPrice,
            "high-water mark price does not match with expected."
        );
        assertEq(
            data.performanceFeesRate,
            expectedData.performanceFeesRate,
            "Performance fees does not match with expected."
        );
        assertEq(
            data.highWaterMarkResetTime,
            expectedData.highWaterMarkResetTime,
            "Watermark reset time does not match with expected."
        );
        assertEq(
            data.strategistPlatformCut,
            expectedData.strategistPlatformCut,
            "Strategist platform cut is not set correctly."
        );
        assertEq(
            data.strategistPayoutAddress,
            expectedData.strategistPayoutAddress,
            "Strategist payout address is not set correctly."
        );
        assertEq(protocolPayoutAddress, expectedProtocolPayoutAddress, "Protocol payout address is not set correctly.");
    }

    function testHighWaterMarkReset() external {
        FeesManager feesManager = FeesManager(fund.FEES_MANAGER());

        uint256 performanceFeesRate = Math.WAD / 100; // 1%

        feesManager.setPerformanceFees(address(fund), performanceFeesRate);

        uint256 prevHighWaterMarkPrice = feesManager.getFundFeesData(address(fund)).highWaterMarkPrice;

        uint256 perfFactor = Math.WAD / 10; // 10% performance
        deal(address(USDC), address(fund), (initialAssets * (Math.WAD + perfFactor)) / Math.WAD);

        // is expected to fail as we just updated the highWaterMarkPrice state
        vm.expectRevert(FeesManager.FeesManager__HighWaterMarkNotYetExpired.selector);
        feesManager.resetHighWaterMark(address(fund));

        _moveForwardAndUpdateOracle(91 days);

        // is expected to work just fine as enough time has passed
        feesManager.resetHighWaterMark(address(fund));
        assertEq(
            feesManager.getFundFeesData(address(fund)).highWaterMarkPrice,
            ((prevHighWaterMarkPrice * (Math.WAD + perfFactor - (perfFactor * performanceFeesRate) / Math.WAD)) /
                Math.WAD),
            "Water mark price should reset after taking the fees into account."
        );

        assertEq(
            feesManager.getFundFeesData(address(fund)).highWaterMarkResetTime,
            block.timestamp,
            "Water mark reset time should be updated."
        );

        perfFactor = Math.WAD; // 100% performance
        deal(address(USDC), address(fund), (fund.totalAssets() * (Math.WAD + perfFactor)) / Math.WAD);
        prevHighWaterMarkPrice = feesManager.getFundFeesData(address(fund)).highWaterMarkPrice;

        _moveForwardAndUpdateOracle(1 days);

        // is expected to work just fine as total assets increased significantly
        feesManager.resetHighWaterMark(address(fund));
        assertApproxEqAbs(
            feesManager.getFundFeesData(address(fund)).highWaterMarkPrice,
            ((prevHighWaterMarkPrice * (Math.WAD + perfFactor - (perfFactor * performanceFeesRate) / Math.WAD)) /
                Math.WAD),
            1,
            "Water mark price should reset after taking the fees into account."
        );

        assertEq(
            feesManager.getFundFeesData(address(fund)).highWaterMarkResetTime,
            block.timestamp,
            "Water mark reset time should be updated."
        );

        // is expected to fail as we just updated the highWaterMarkPrice state
        vm.expectRevert(FeesManager.FeesManager__HighWaterMarkNotYetExpired.selector);
        feesManager.resetHighWaterMark(address(fund));

        _moveForwardAndUpdateOracle(91 days);

        // is expected to work just fine as we passed HIGH_WATERMARK_RESET_INTERVAL
        feesManager.resetHighWaterMark(address(fund));

        // is expected to fail as we just updated the highWaterMarkPrice state
        vm.expectRevert(FeesManager.FeesManager__HighWaterMarkNotYetExpired.selector);
        feesManager.resetHighWaterMark(address(fund));

        deal(address(USDC), address(fund), (fund.totalAssets() * 2), true);
        // is expected to work just fine as we passed HIGH_WATERMARK_RESET_INTERVAL
        feesManager.resetHighWaterMark(address(fund));

        vm.expectRevert(FeesManager.FeesManager__HighWaterMarkNotYetExpired.selector);
        feesManager.resetHighWaterMark(address(fund));

        // is expected to fail as we just updated the highWaterMarkPrice state
        vm.expectRevert(FeesManager.FeesManager__HighWaterMarkNotYetExpired.selector);
        feesManager.resetHighWaterMark(address(fund));
    }
}
