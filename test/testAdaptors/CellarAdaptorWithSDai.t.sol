// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { SwaapFundAdaptor } from "src/modules/adaptors/Swaap/SwaapFundAdaptor.sol";
import { MockDataFeed } from "src/mocks/MockDataFeed.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";

import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";

contract SwaapFundAdaptorWithSDaiTest is MainnetStarterTest, AdaptorHelperFunctions {
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using stdStorage for StdStorage;

    SwaapFundAdaptor private swaapFundAdaptor;
    ERC4626 public sDai = ERC4626(savingsDaiAddress);
    Fund private fund;
    MockDataFeed public mockDaiUsd;

    uint32 private daiPosition = 1;
    uint32 private wethPosition = 2;
    uint32 private sDaiPosition = 3;

    uint256 public initialAssets;

    function setUp() external {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 16869780;
        _startFork(rpcKey, blockNumber);

        // Run Starter setUp code.
        _setUp();

        swaapFundAdaptor = new SwaapFundAdaptor();

        mockDaiUsd = new MockDataFeed(DAI_USD_FEED);

        PriceRouter.ChainlinkDerivativeStorage memory stor;

        PriceRouter.AssetSettings memory settings;

        uint256 price = uint256(IChainlinkAggregator(WETH_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, WETH_USD_FEED);
        priceRouter.addAsset(WETH, settings, abi.encode(stor), price);

        price = uint256(IChainlinkAggregator(address(mockDaiUsd)).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, address(mockDaiUsd));
        priceRouter.addAsset(DAI, settings, abi.encode(stor), price);

        // Setup Fund:

        // Add adaptors and positions to the registry.
        registry.trustAdaptor(address(swaapFundAdaptor));

        registry.trustPosition(daiPosition, address(erc20Adaptor), abi.encode(DAI));
        registry.trustPosition(sDaiPosition, address(swaapFundAdaptor), abi.encode(sDai));

        string memory fundName = "Savings DAI Fund V0.0";
        uint256 initialDeposit = 1e18;

        fund = _createFund(fundName, DAI, daiPosition, abi.encode(0), initialDeposit);

        fund.setRebalanceDeviation(0.01e18);

        fund.addAdaptorToCatalogue(address(swaapFundAdaptor));
        fund.addPositionToCatalogue(sDaiPosition);

        fund.addPosition(0, sDaiPosition, abi.encode(true), false);

        fund.setHoldingPosition(sDaiPosition);

        DAI.safeApprove(address(fund), type(uint256).max);

        initialAssets = fund.totalAssets();
    }

    function testDeposit(uint256 assets) external {
        assets = bound(assets, 0.1e18, 1_000_000_000e18);
        deal(address(DAI), address(this), assets);
        fund.deposit(assets, address(this));

        uint256 assetsInSDai = sDai.maxWithdraw(address(fund));
        assertApproxEqAbs(assetsInSDai, assets, 2, "Assets should have been deposited into sDai.");

        assertApproxEqAbs(
            fund.totalAssets(),
            initialAssets + assets,
            2,
            "Fund totalAssets should equal assets + initial assets"
        );
    }

    function testWithdraw(uint256 assets) external {
        assets = bound(assets, 0.1e18, 1_000_000_000e18);
        deal(address(DAI), address(this), assets);
        fund.deposit(assets, address(this));

        uint256 maxRedeem = fund.maxRedeem(address(this));

        assets = fund.redeem(maxRedeem, address(this), address(this));

        assertApproxEqAbs(DAI.balanceOf(address(this)), assets, 2, "User should have been sent DAI.");
    }

    function testInterestAccrual(uint256 assets) external {
        assets = bound(assets, 0.1e18, 1_000_000_000e18);
        deal(address(DAI), address(this), assets);
        fund.deposit(assets, address(this));

        uint256 assetsBefore = fund.totalAssets();

        vm.warp(block.timestamp + 1 days);
        mockDaiUsd.setMockUpdatedAt(block.timestamp);

        assertGt(
            fund.totalAssets(),
            assetsBefore,
            "Assets should have increased because sDAI calculates pending interest."
        );
    }

    function testUsersGetPendingInterest(uint256 assets) external {
        assets = bound(assets, 0.1e18, 1_000_000_000e18);
        deal(address(DAI), address(this), assets);
        fund.deposit(assets, address(this));

        uint256 assetsBefore = fund.totalAssets();

        vm.warp(block.timestamp + 10 days);
        mockDaiUsd.setMockUpdatedAt(block.timestamp);

        assertGt(
            fund.totalAssets(),
            assetsBefore,
            "Assets should have increased because sDAI calculates pending interest."
        );

        uint256 maxRedeem = fund.maxRedeem(address(this));
        fund.redeem(maxRedeem, address(this), address(this));

        assertGt(DAI.balanceOf(address(this)), assets, "Should have sent more DAI to the user than they put in.");
    }

    function testStrategistFunctions(uint256 assets) external {
        fund.setHoldingPosition(daiPosition);

        assets = bound(assets, 0.1e18, 1_000_000_000e18);
        deal(address(DAI), address(this), assets);
        fund.deposit(assets, address(this));

        // Deposit half the DAI into DSR.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToDepositToFund(address(sDai), assets / 2);
            data[0] = Fund.AdaptorCall({ adaptor: address(swaapFundAdaptor), callData: adaptorCalls });
        }
        fund.callOnAdaptor(data);

        uint256 assetsInSDai = sDai.maxWithdraw(address(fund));

        assertApproxEqAbs(assetsInSDai, assets / 2, 2, "Should have deposited half the assets into the DSR.");

        // Advance some time.
        vm.warp(block.timestamp + 1 days);
        mockDaiUsd.setMockUpdatedAt(block.timestamp);

        // Deposit remaining assets into DSR.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToDepositToFund(address(sDai), type(uint256).max);
            data[0] = Fund.AdaptorCall({ adaptor: address(swaapFundAdaptor), callData: adaptorCalls });
        }
        fund.callOnAdaptor(data);

        assetsInSDai = sDai.maxWithdraw(address(fund));
        assertGt(assetsInSDai, assets + initialAssets, "Should have deposited all the assets into the DSR.");

        // Advance some time.
        vm.warp(block.timestamp + 10 days);
        mockDaiUsd.setMockUpdatedAt(block.timestamp);

        // Withdraw half the assets.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToWithdrawFromFund(address(sDai), assets / 2);
            data[0] = Fund.AdaptorCall({ adaptor: address(swaapFundAdaptor), callData: adaptorCalls });
        }
        fund.callOnAdaptor(data);

        assertApproxEqAbs(
            DAI.balanceOf(address(fund)),
            assets / 2,
            1,
            "Should have withdrawn half the assets from the DSR."
        );

        // Withdraw remaining  assets.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToWithdrawFromFund(address(sDai), type(uint256).max);
            data[0] = Fund.AdaptorCall({ adaptor: address(swaapFundAdaptor), callData: adaptorCalls });
        }
        fund.callOnAdaptor(data);

        assertGt(
            DAI.balanceOf(address(fund)),
            assets + initialAssets,
            "Should have withdrawn all the assets from the DSR."
        );

        assetsInSDai = sDai.maxWithdraw(address(fund));
        assertEq(assetsInSDai, 0, "No assets should be left in DSR.");
    }
}
