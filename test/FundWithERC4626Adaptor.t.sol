// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ReentrancyERC4626 } from "src/mocks/ReentrancyERC4626.sol";
import { SwaapFundAdaptor } from "src/modules/adaptors/Swaap/SwaapFundAdaptor.sol";
import { ERC4626Adaptor } from "src/modules/adaptors/ERC4626Adaptor.sol";
import { ERC20DebtAdaptor } from "src/mocks/ERC20DebtAdaptor.sol";
import { MockDataFeed } from "src/mocks/MockDataFeed.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";

import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";

contract FundWithERC4626AdaptorTest is MainnetStarterTest, AdaptorHelperFunctions {
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using stdStorage for StdStorage;

    Fund private fund;
    Fund private usdcCLR;
    Fund private wethCLR;
    Fund private wbtcCLR;

    ERC4626Adaptor private erc4626Adaptor;

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
    uint32 private fundPosition = 8;

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
        erc4626Adaptor = new ERC4626Adaptor();

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
        registry.trustAdaptor(address(erc4626Adaptor));
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
        registry.trustPosition(usdcCLRPosition, address(erc4626Adaptor), abi.encode(usdcCLR));
        registry.trustPosition(wethCLRPosition, address(erc4626Adaptor), abi.encode(wethCLR));
        registry.trustPosition(wbtcCLRPosition, address(erc4626Adaptor), abi.encode(wbtcCLR));

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
        fund.addAdaptorToCatalogue(address(erc4626Adaptor));
        fund.addPositionToCatalogue(usdtPosition);

        vm.label(address(fund), "fund");
        vm.label(strategist, "strategist");

        // Approve fund to spend all assets.
        USDC.approve(address(fund), type(uint256).max);

        initialAssets = fund.totalAssets();
        initialShares = fund.totalSupply();
    }

    // ========================================== REBALANCE TEST ==========================================

    // In the context of using the ERC4626Adaptor, the funds are customized ERC4626s, so they should work in a sense with the ERC4626Adaptor. That is what is being tested.
    function testTotalAssets(
        uint256 usdcAmount,
        uint256 usdcCLRAmount,
        uint256 wethCLRAmount,
        uint256 wbtcCLRAmount,
        uint256 wethAmount
    ) external {
        usdcAmount = bound(usdcAmount, 1e6, 1_000_000e6);
        usdcCLRAmount = bound(usdcCLRAmount, 1e6, 1_000_000e6);
        wethCLRAmount = bound(wethCLRAmount, 1e6, 1_000_000e6);
        wbtcCLRAmount = bound(wbtcCLRAmount, 1e6, 1_000_000e6);
        wethAmount = bound(wethAmount, 1e18, 10_000e18);
        uint256 totalAssets = fund.totalAssets();

        assertEq(totalAssets, initialAssets, "Fund total assets should be initialAssets.");

        deal(address(USDC), address(this), usdcCLRAmount + wethCLRAmount + wbtcCLRAmount + usdcAmount);
        fund.deposit(usdcCLRAmount + wethCLRAmount + wbtcCLRAmount + usdcAmount, address(this));

        _depositToVault(fund, usdcCLR, usdcCLRAmount);
        _depositToVault(fund, wethCLR, wethCLRAmount);
        _depositToVault(fund, wbtcCLR, wbtcCLRAmount);
        deal(address(WETH), address(fund), wethAmount);

        uint256 expectedTotalAssets = usdcAmount +
            usdcCLRAmount +
            priceRouter.getValue(WETH, wethAmount, USDC) +
            wethCLRAmount +
            wbtcCLRAmount +
            initialAssets;

        totalAssets = fund.totalAssets();

        assertApproxEqRel(
            totalAssets,
            expectedTotalAssets,
            0.0001e18,
            "`totalAssets` should equal all asset values summed together."
        );
    }

    // ====================================== PLATFORM FEE TEST ======================================

    // keep
    function testFundWithFundPositions() external {
        // Fund A's asset is USDC, holding position is Fund B shares, whose holding asset is USDC.
        // Initialize test Funds.

        // Create Fund B
        string memory fundName = "Fund B V0.0";
        uint256 initialDeposit = 1e6;
        Fund fundB = _createFund(fundName, USDC, usdcPosition, abi.encode(true), initialDeposit);

        uint32 fundBPosition = 10;
        registry.trustPosition(fundBPosition, address(erc4626Adaptor), abi.encode(fundB));

        // Create Fund A
        fundName = "Fund A V0.0";
        initialDeposit = 1e6;
        Fund fundA = _createFund(fundName, USDC, usdcPosition, abi.encode(true), initialDeposit);

        fundA.addPositionToCatalogue(fundBPosition);
        fundA.addPosition(0, fundBPosition, abi.encode(true), false);
        fundA.setHoldingPosition(fundBPosition);
        fundA.swapPositions(0, 1, false);

        uint256 assets = 100e6;
        deal(address(USDC), address(this), assets);
        USDC.approve(address(fundA), assets);
        fundA.deposit(assets, address(this));

        uint256 withdrawAmount = fundA.maxWithdraw(address(this));
        assertEq(assets, withdrawAmount, "Assets should not have changed.");
        assertEq(fundA.totalAssets(), fundB.totalAssets(), "Total assets should be the same.");

        fundA.withdraw(withdrawAmount, address(this), address(this));
    }

    //============================================ Helper Functions ===========================================

    function _depositToVault(Fund targetFrom, Fund targetTo, uint256 amountIn) internal {
        ERC20 assetIn = targetFrom.asset();
        ERC20 assetOut = targetTo.asset();

        uint256 amountTo = priceRouter.getValue(assetIn, amountIn, assetOut);

        // Update targetFrom ERC20 balances.
        deal(address(assetIn), address(targetFrom), assetIn.balanceOf(address(targetFrom)) - amountIn);
        deal(address(assetOut), address(targetFrom), assetOut.balanceOf(address(targetFrom)) + amountTo);

        // Rebalance into targetTo.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToDepositToERC4626Vault(address(targetTo), amountTo);
            data[0] = Fund.AdaptorCall({ adaptor: address(erc4626Adaptor), callData: adaptorCalls });
        }

        // Perform callOnAdaptor.
        targetFrom.callOnAdaptor(data);
    }

    function testUsingIlliquidFundPosition() external {
        registry.trustPosition(fundPosition, address(erc4626Adaptor), abi.encode(address(fund)));

        string memory fundName = "Meta Fund V0.0";
        uint256 initialDeposit = 1e6;

        Fund metaFund = _createFund(fundName, USDC, usdcPosition, abi.encode(true), initialDeposit);
        initialAssets = metaFund.totalAssets();

        metaFund.addPositionToCatalogue(fundPosition);
        metaFund.addAdaptorToCatalogue(address(erc4626Adaptor));
        metaFund.addPosition(0, fundPosition, abi.encode(false), false);
        metaFund.setHoldingPosition(fundPosition);

        USDC.safeApprove(address(metaFund), type(uint256).max);

        // Deposit into meta fund.
        uint256 assets = 100_000e6;
        deal(address(USDC), address(this), assets);

        metaFund.deposit(assets, address(this));

        uint256 assetsDeposited = fund.totalAssets();
        assertEq(assetsDeposited, assets + initialAssets, "All assets should have been deposited into fund.");

        uint256 liquidAssets = metaFund.maxWithdraw(address(this));
        assertEq(liquidAssets, initialAssets, "Meta Fund only liquid assets should be USDC deposited in constructor.");

        // Check logic in the withdraw function by having strategist call withdraw, passing in isLiquid = false.
        bool isLiquid = false;
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = abi.encodeWithSelector(
            ERC4626Adaptor.withdraw.selector,
            assets,
            address(this),
            abi.encode(fund),
            abi.encode(isLiquid)
        );

        data[0] = Fund.AdaptorCall({ adaptor: address(erc4626Adaptor), callData: adaptorCalls });

        vm.expectRevert(bytes(abi.encodeWithSelector(BaseAdaptor.BaseAdaptor__UserWithdrawsNotAllowed.selector)));
        metaFund.callOnAdaptor(data);
    }
}
