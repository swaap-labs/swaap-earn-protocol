// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ReentrancyERC4626 } from "src/mocks/ReentrancyERC4626.sol";
import { CellarAdaptor } from "src/modules/adaptors/Sommelier/CellarAdaptor.sol";
import { ERC20DebtAdaptor } from "src/mocks/ERC20DebtAdaptor.sol";
import { MockDataFeed } from "src/mocks/MockDataFeed.sol";
import { MockCellar } from "src/mocks/MockCellar.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";

import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";
import { FeesManager } from "src/modules/fees/FeesManager.sol";

contract FeesManagerTest is MainnetStarterTest, AdaptorHelperFunctions {
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using stdStorage for StdStorage;

    Cellar private cellar;
    Cellar private usdcCLR;
    Cellar private wethCLR;
    Cellar private wbtcCLR;

    MockCellar private mockCellar;

    CellarAdaptor private cellarAdaptor;

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
        cellarAdaptor = new CellarAdaptor();

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
        registry.trustAdaptor(address(cellarAdaptor));
        registry.trustPosition(usdcPosition, address(erc20Adaptor), abi.encode(USDC));
        registry.trustPosition(wethPosition, address(erc20Adaptor), abi.encode(WETH));
        registry.trustPosition(wbtcPosition, address(erc20Adaptor), abi.encode(WBTC));
        registry.trustPosition(usdtPosition, address(erc20Adaptor), abi.encode(USDT));

        // Create Dummy Cellars.
        string memory cellarName = "Dummy Cellar V0.0";
        uint256 initialDeposit = 1e6;

        usdcCLR = _createCellar(cellarName, USDC, usdcPosition, abi.encode(true), initialDeposit);
        vm.label(address(usdcCLR), "usdcCLR");

        cellarName = "Dummy Cellar V0.1";
        initialDeposit = 1e12;
        wethCLR = _createCellar(cellarName, WETH, wethPosition, abi.encode(true), initialDeposit);
        vm.label(address(wethCLR), "wethCLR");

        cellarName = "Dummy Cellar V0.2";
        initialDeposit = 1e4;
        wbtcCLR = _createCellar(cellarName, WBTC, wbtcPosition, abi.encode(true), initialDeposit);
        vm.label(address(wbtcCLR), "wbtcCLR");

        // Add Cellar Positions to the registry.
        registry.trustPosition(usdcCLRPosition, address(cellarAdaptor), abi.encode(usdcCLR));
        registry.trustPosition(wethCLRPosition, address(cellarAdaptor), abi.encode(wethCLR));
        registry.trustPosition(wbtcCLRPosition, address(cellarAdaptor), abi.encode(wbtcCLR));

        cellarName = "Cellar V0.0";
        initialDeposit = 1e6;
        cellar = _createCellar(cellarName, USDC, usdcPosition, abi.encode(true), initialDeposit);

        // Set up remaining cellar positions.
        cellar.addPositionToCatalogue(usdcCLRPosition);
        cellar.addPosition(1, usdcCLRPosition, abi.encode(true), false);
        cellar.addPositionToCatalogue(wethCLRPosition);
        cellar.addPosition(2, wethCLRPosition, abi.encode(true), false);
        cellar.addPositionToCatalogue(wbtcCLRPosition);
        cellar.addPosition(3, wbtcCLRPosition, abi.encode(true), false);
        cellar.addPositionToCatalogue(wethPosition);
        cellar.addPosition(4, wethPosition, abi.encode(true), false);
        cellar.addPositionToCatalogue(wbtcPosition);
        cellar.addPosition(5, wbtcPosition, abi.encode(true), false);
        cellar.addAdaptorToCatalogue(address(cellarAdaptor));
        cellar.addPositionToCatalogue(usdtPosition);

        vm.label(address(cellar), "cellar");
        vm.label(strategist, "strategist");

        // Approve cellar to spend all assets.
        USDC.approve(address(cellar), type(uint256).max);

        initialAssets = cellar.totalAssets();
        initialShares = cellar.totalSupply();
    }

    // ========================================= FEES TEST =========================================
    function testManagementFeesEnterHook() external {
        FeesManager feesManager = FeesManager(cellar.FEES_MANAGER());
        uint256 managementFeesPerYear = Math.WAD / 100; // 1%

        feesManager.setManagementFeesPerYear(address(cellar), managementFeesPerYear); // 1%

        assertEq(
            cellar.balanceOf(address(feesManager)),
            0,
            "Fees manager should own 0% of the total supply when setting the management fees initially."
        );

        _moveForwardAndUpdateOracle(365 days);

        // minting new shares should trigger fees.
        uint256 newShares = 1e18;
        deal(address(cellar.asset()), address(this), cellar.previewMint(newShares));
        uint256 totalSupplyBeforeMint = cellar.totalSupply();
        cellar.mint(newShares, address(this));

        uint256 expectedSharesReceived = (totalSupplyBeforeMint * managementFeesPerYear) /
            (Math.WAD - managementFeesPerYear);

        assertApproxEqRel(
            cellar.balanceOf(address(feesManager)),
            expectedSharesReceived,
            1e15,
            "Fees manager should own 1% of the total supply before the mint."
        );

        _moveForwardAndUpdateOracle(365 days);

        // depositing new assets trigger fees.
        uint256 feeManagerSharesBeforeDeposit = cellar.balanceOf(address(feesManager));
        uint256 totalSupplyBeforeDeposit = cellar.totalSupply();

        uint256 newAssets = 1e18;
        deal(address(cellar.asset()), address(this), newAssets);
        newShares = cellar.deposit(newAssets, address(this));

        uint256 feeManageReceivedSharesAfterDeposit = cellar.balanceOf(address(feesManager)) -
            feeManagerSharesBeforeDeposit;

        expectedSharesReceived =
            (totalSupplyBeforeDeposit * managementFeesPerYear) /
            (Math.WAD - managementFeesPerYear);

        assertApproxEqRel(
            feeManageReceivedSharesAfterDeposit,
            expectedSharesReceived,
            1e12,
            "Fees manager should own 1% of the new shares after the deposit."
        );
    }

    function testPerformanceFeesMintHook() external {
        FeesManager feesManager = FeesManager(cellar.FEES_MANAGER());
        uint256 performanceFees = Math.WAD / 5; // 20%

        feesManager.setPerformanceFees(address(cellar), performanceFees); // 1%

        assertEq(
            cellar.balanceOf(address(feesManager)),
            0,
            "Fees manager should own 0% of the cellar when setting performance fees."
        );

        FeesManager.FeesData memory feeData = feesManager.getCellarFeesData(address(cellar));

        assertEq(
            feeData.highWaterMarkPrice,
            cellar.totalAssets().mulDivDown(Math.WAD, cellar.totalSupply()),
            "High watermark price should be set to the initial share price."
        );

        assertEq(feeData.performanceFeesRate, performanceFees, "Performance fees should be set to 20%.");

        // setting the performance to 50%
        uint256 newAssets = cellar.totalAssets() / 2;
        deal(address(cellar.asset()), address(cellar), cellar.asset().balanceOf(address(cellar)) + newAssets);

        // minting new shares should trigger fees.
        uint256 newShares = 1e18;
        deal(address(cellar.asset()), address(this), cellar.previewMint(newShares));
        cellar.mint(newShares, address(this));

        uint256 expectedFeeManagerAssets = (newAssets * performanceFees) / Math.WAD;

        assertApproxEqAbs(
            cellar.maxWithdraw(address(feesManager)),
            expectedFeeManagerAssets,
            1,
            "Fees manager should own 20% of new assets as performance fees."
        );
    }

    function testPerformanceFeesDepositHook() external {
        FeesManager feesManager = FeesManager(cellar.FEES_MANAGER());
        uint256 performanceFees = Math.WAD / 5; // 20%

        feesManager.setPerformanceFees(address(cellar), performanceFees); // 1%

        assertEq(
            cellar.balanceOf(address(feesManager)),
            0,
            "Fees manager should own 0% of the cellar when setting performance fees."
        );

        FeesManager.FeesData memory feeData = feesManager.getCellarFeesData(address(cellar));

        assertEq(
            feeData.highWaterMarkPrice,
            cellar.totalAssets().mulDivDown(Math.WAD, cellar.totalSupply()),
            "High watermark price should be set to the initial share price."
        );

        assertEq(feeData.performanceFeesRate, performanceFees, "Performance fees should be set to 20%.");

        // setting the performance to 50%
        uint256 newAssets = cellar.totalAssets() / 2;
        deal(address(cellar.asset()), address(cellar), cellar.asset().balanceOf(address(cellar)) + newAssets);

        // depositing new shares should trigger fees.
        uint256 depositAssets = 1e18;
        deal(address(cellar.asset()), address(this), depositAssets);
        cellar.deposit(depositAssets, address(this));

        uint256 expectedFeeManagerAssets = (newAssets * performanceFees) / Math.WAD;

        assertApproxEqAbs(
            cellar.maxWithdraw(address(feesManager)),
            expectedFeeManagerAssets,
            1,
            "Fees manager should own 20% of new assets as performance fees."
        );
    }

    function testPerformanceFeesRedeemHook() external {
        FeesManager feesManager = FeesManager(cellar.FEES_MANAGER());
        uint256 performanceFees = Math.WAD / 5; // 20%

        feesManager.setPerformanceFees(address(cellar), performanceFees); // 1%

        assertEq(
            cellar.balanceOf(address(feesManager)),
            0,
            "Fees manager should own 0% of the cellar when setting performance fees."
        );

        FeesManager.FeesData memory feeData = feesManager.getCellarFeesData(address(cellar));

        assertEq(
            feeData.highWaterMarkPrice,
            cellar.totalAssets().mulDivDown(Math.WAD, cellar.totalSupply()),
            "High watermark price should be set to the initial share price."
        );

        assertEq(feeData.performanceFeesRate, performanceFees, "Performance fees should be set to 20%.");

        // setting balances
        deal(address(cellar), address(this), initialShares);
        deal(address(cellar.asset()), address(this), 0);

        // setting the performance to 30%
        uint256 newAssets = (initialAssets * 30) / 100;
        deal(address(cellar.asset()), address(cellar), initialAssets + newAssets);

        // redeeming shares should trigger fees.
        uint256 redeemShares = initialShares / 3;
        cellar.redeem(redeemShares, address(this), address(this));

        uint256 expectedFeeManagerAssets = (newAssets * performanceFees) / Math.WAD;

        assertApproxEqAbs(
            cellar.maxWithdraw(address(feesManager)),
            expectedFeeManagerAssets,
            1,
            "Fees manager should own 20% of new assets as performance fees."
        );

        assertApproxEqAbs(
            cellar.asset().balanceOf(address(this)),
            (((initialAssets + newAssets) - expectedFeeManagerAssets) * redeemShares) / initialShares,
            1,
            "User should receive the correct amount of assets after exit with performance fees on."
        );
    }

    function testPerformanceFeesWithdrawHook() external {
        FeesManager feesManager = FeesManager(cellar.FEES_MANAGER());
        uint256 performanceFees = Math.WAD / 5; // 20%

        feesManager.setPerformanceFees(address(cellar), performanceFees); // 1%

        assertEq(
            cellar.balanceOf(address(feesManager)),
            0,
            "Fees manager should own 0% of the cellar when setting performance fees."
        );

        FeesManager.FeesData memory feeData = feesManager.getCellarFeesData(address(cellar));

        assertEq(
            feeData.highWaterMarkPrice,
            cellar.totalAssets().mulDivDown(Math.WAD, cellar.totalSupply()),
            "High watermark price should be set to the initial share price."
        );

        assertEq(feeData.performanceFeesRate, performanceFees, "Performance fees should be set to 20%.");

        // setting balances
        deal(address(cellar), address(this), initialShares); // giving user cellar shares ownership
        deal(address(cellar.asset()), address(this), 0);

        // setting the performance to 30%
        uint256 newAssets = (initialAssets * 30) / 100;
        deal(address(cellar.asset()), address(cellar), initialAssets + newAssets);

        // cellar new total assets
        uint256 newTotalAssets = initialAssets + newAssets;

        // depositing new shares should trigger fees.
        uint256 withdrawAssets = initialAssets / 3;
        cellar.withdraw(withdrawAssets, address(this), address(this));

        uint256 expectedFeeManagerAssets = (newAssets * performanceFees) / Math.WAD;

        assertApproxEqAbs(
            cellar.maxWithdraw(address(feesManager)),
            expectedFeeManagerAssets,
            1,
            "Fees manager should own 20% of the new assets as performance fees."
        );

        uint256 userBurnedShares = initialShares - cellar.balanceOf(address(this));
        assertApproxEqAbs(
            userBurnedShares,
            (withdrawAssets * (initialShares + cellar.balanceOf(address(feesManager)))) / newTotalAssets,
            1,
            "User should burn the correct amount of shares after exit with performance fees on."
        );
    }

    function testEnterFeesMintHook() external {
        FeesManager feesManager = FeesManager(cellar.FEES_MANAGER());
        uint256 _ONE_HUNDRED_PERCENT = 10000;
        uint16 enterFees = uint16(_ONE_HUNDRED_PERCENT / 100); // 1%

        uint256 sharesToMint = 1e18;
        uint256 depositAssetsWithNoFees = cellar.previewMint(sharesToMint);

        uint256 initUserAssetBalance = depositAssetsWithNoFees * 2;
        deal(address(cellar.asset()), address(this), initUserAssetBalance);

        feesManager.setEnterFees(address(cellar), enterFees); // 1%

        assertEq(
            cellar.balanceOf(address(feesManager)),
            0,
            "Fees manager should own 0% of the cellar when setting enter fees."
        );

        // set address(this) cellar shares balance to 0 for the test
        deal(address(cellar), address(this), 0);

        // minting new shares should trigger fees.
        uint256 totalSupplyBeforeMint = cellar.totalSupply();
        cellar.mint(sharesToMint, address(this));
        uint256 mintedShares = cellar.totalSupply() - totalSupplyBeforeMint;

        assertEq(mintedShares, sharesToMint, "Mint should mint the correct amount of shares when enter fees are on.");

        assertEq(
            cellar.balanceOf(address(this)),
            sharesToMint,
            "Mint should mint the correct amount of shares to the user when enter fees are on."
        );

        assertEq(cellar.balanceOf(address(feesManager)), 0, "Fees manager should not receive the enter fees.");

        assertApproxEqAbs(
            initUserAssetBalance - cellar.asset().balanceOf(address(this)),
            (depositAssetsWithNoFees * (_ONE_HUNDRED_PERCENT + enterFees)) / _ONE_HUNDRED_PERCENT,
            1,
            "Cellar should receive the correct amount of assets after minting with enter fees."
        );
    }

    function testEnterFeesDepositHook() external {
        FeesManager feesManager = FeesManager(cellar.FEES_MANAGER());
        uint256 _ONE_HUNDRED_PERCENT = 1e4;
        uint16 enterFees = uint16(_ONE_HUNDRED_PERCENT / 100); // 1%

        uint256 assetsToDeposit = 1e18;
        uint256 mintedSharesWithNoFees = cellar.previewDeposit(assetsToDeposit);
        deal(address(cellar.asset()), address(this), assetsToDeposit);

        feesManager.setEnterFees(address(cellar), enterFees); // 1%

        assertEq(
            cellar.balanceOf(address(feesManager)),
            0,
            "Fees manager should own 0% of the cellar when setting enter fees."
        );

        // set address(this) cellar shares balance to 0 for the test
        deal(address(cellar), address(this), 0);

        // deposit new shares should trigger fees.
        cellar.deposit(assetsToDeposit, address(this));

        assertEq(
            cellar.asset().balanceOf(address(this)), // if no balance is remaining, the deposit used the correct amount of assets
            0,
            "Deposit should use the correct amount of assets when enter fees are on."
        );

        assertEq(cellar.balanceOf(address(feesManager)), 0, "Fees manager should not receive the enter fees.");

        assertApproxEqAbs(
            cellar.balanceOf(address(this)),
            (mintedSharesWithNoFees * (_ONE_HUNDRED_PERCENT - enterFees)) / _ONE_HUNDRED_PERCENT,
            1,
            "Deposit should mint the correct amount of shares to the user when enter fees are on."
        );
    }

    function testExitFeesRedeemHook() external {
        FeesManager feesManager = FeesManager(cellar.FEES_MANAGER());
        uint256 _ONE_HUNDRED_PERCENT = 10000;
        uint16 enterFees = uint16(_ONE_HUNDRED_PERCENT / 100); // 1%

        uint256 initUserShares = initialShares;
        deal(address(cellar), address(this), initUserShares);
        // make sure initial shares are not 0
        assertGt(initUserShares, 0, "Initial shares should not be 0.");

        uint256 sharesToRedeem = initUserShares / 3;
        uint256 assetsReceivedWithNoFees = cellar.previewRedeem(sharesToRedeem);

        feesManager.setExitFees(address(cellar), enterFees); // 1%

        assertEq(
            cellar.balanceOf(address(feesManager)),
            0,
            "Fees manager should own 0% of the cellar when setting exit fees."
        );

        // set address(this) cellar asset balance to 0 for the test
        deal(address(cellar.asset()), address(this), 0);

        // minting new shares should trigger fees.
        uint256 totalSupplyBeforeRedeem = cellar.totalSupply();
        cellar.redeem(sharesToRedeem, address(this), address(this));
        uint256 burnedShares = totalSupplyBeforeRedeem - cellar.totalSupply();

        assertEq(
            sharesToRedeem,
            burnedShares,
            "Redeem should burn the correct amount of shares when exit fees are on."
        );

        assertEq(
            cellar.balanceOf(address(this)),
            initUserShares - sharesToRedeem,
            "Redeem should burn the correct amount of shares to the user when exit fees are on."
        );

        assertEq(cellar.balanceOf(address(feesManager)), 0, "Fees manager should not receive the exit fees.");

        assertApproxEqAbs(
            cellar.asset().balanceOf(address(this)), // received assets
            (assetsReceivedWithNoFees * (_ONE_HUNDRED_PERCENT - enterFees)) / _ONE_HUNDRED_PERCENT,
            1,
            "User should receive the correct amount of assets after redeem with exit fees."
        );
    }

    function testExitFeesWithdrawHook() external {
        FeesManager feesManager = FeesManager(cellar.FEES_MANAGER());
        uint256 _ONE_HUNDRED_PERCENT = 1e4;
        uint16 exitFees = uint16(_ONE_HUNDRED_PERCENT / 100); // 1%

        uint256 assetsToWithdraw = initialAssets / 3;
        uint256 burnedSharesWithNoFees = initialShares / 3;
        // giving shares ownership to the user
        deal(address(cellar), address(this), initialShares);

        feesManager.setExitFees(address(cellar), exitFees); // 1%

        assertEq(
            cellar.balanceOf(address(feesManager)),
            0,
            "Fees manager should own 0% of the cellar when setting exit fees."
        );

        // withdraw assets should trigger fees.
        cellar.withdraw(assetsToWithdraw, address(this), address(this));

        assertEq(
            cellar.asset().balanceOf(address(cellar)),
            initialAssets - assetsToWithdraw,
            "Withdraw should remove the correct amount of assets from the cellar when exit fees are on."
        );

        assertEq(
            cellar.asset().balanceOf(address(this)),
            assetsToWithdraw,
            "Withdraw should give the correct amount of assets from the user when exit fees are on."
        );

        assertEq(cellar.balanceOf(address(feesManager)), 0, "Fees manager should not receive the exit fees.");

        assertApproxEqAbs(
            initialShares - cellar.balanceOf(address(this)),
            (burnedSharesWithNoFees * (_ONE_HUNDRED_PERCENT + exitFees)) / _ONE_HUNDRED_PERCENT,
            1,
            "Withdraw should burn the correct amount of shares to the user when exit fees are on."
        );
    }

    function _moveForwardAndUpdateOracle(uint256 delayTimestamp) internal {
        skip(delayTimestamp);
        mockUsdcUsd.setMockUpdatedAt(block.timestamp);
        mockWethUsd.setMockUpdatedAt(block.timestamp);
        mockWbtcUsd.setMockUpdatedAt(block.timestamp);
    }
}
