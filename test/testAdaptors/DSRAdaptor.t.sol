// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

// Import Adaptors
import { DSRAdaptor, DSRManager, Pot } from "src/modules/adaptors/Maker/DSRAdaptor.sol";

import { MockDataFeed } from "src/mocks/MockDataFeed.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";

import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";
import { SwaapFundAdaptor } from "src/modules/adaptors/Swaap/SwaapFundAdaptor.sol";

contract FundDSRTest is MainnetStarterTest, AdaptorHelperFunctions {
    using SafeTransferLib for ERC20;
    DSRAdaptor public dsrAdaptor;

    Fund public fund;
    MockDataFeed public mockDaiUsd;

    uint256 initialAssets;

    DSRManager public manager = DSRManager(dsrManager);

    uint32 daiPosition = 1;
    uint32 dsrPosition = 2;

    function setUp() public {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 17914165;
        _startFork(rpcKey, blockNumber);

        // Run Starter setUp code.
        _setUp();

        dsrAdaptor = new DSRAdaptor(dsrManager);

        mockDaiUsd = new MockDataFeed(DAI_USD_FEED);

        PriceRouter.ChainlinkDerivativeStorage memory stor;
        PriceRouter.AssetSettings memory settings;
        uint256 price = uint256(IChainlinkAggregator(address(mockDaiUsd)).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, address(mockDaiUsd));
        priceRouter.addAsset(DAI, settings, abi.encode(stor), price);

        registry.trustAdaptor(address(dsrAdaptor));

        registry.trustPosition(daiPosition, address(erc20Adaptor), abi.encode(DAI));
        registry.trustPosition(dsrPosition, address(dsrAdaptor), abi.encode(0));

        string memory fundName = "DSR Fund V0.0";
        uint256 initialDeposit = 1e18;

        fund = _createFund(fundName, DAI, daiPosition, abi.encode(0), initialDeposit);

        fund.addAdaptorToCatalogue(address(dsrAdaptor));
        fund.addPositionToCatalogue(dsrPosition);

        fund.addPosition(0, dsrPosition, abi.encode(0), false);
        fund.setHoldingPosition(dsrPosition);

        DAI.safeApprove(address(fund), type(uint256).max);

        initialAssets = fund.totalAssets();
    }

    function testDeposit(uint256 assets) external {
        assets = bound(assets, 0.1e18, 1_000_000_000e18);
        deal(address(DAI), address(this), assets);
        fund.deposit(assets, address(this));

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

        console.log("TA", fund.totalAssets());

        uint256 assetsBefore = fund.totalAssets();

        vm.warp(block.timestamp + 1 days);
        mockDaiUsd.setMockUpdatedAt(block.timestamp);

        assertEq(
            fund.totalAssets(),
            assetsBefore,
            "Assets should not have increased because nothing has interacted with dsr."
        );

        uint256 bal = manager.daiBalance(address(fund));
        assertGt(bal, assets, "Balance should have increased.");

        uint256 assetsAfter = fund.totalAssets();

        assertGt(assetsAfter, assetsBefore, "Total Assets should have increased.");
    }

    function testUsersDoNotGetPendingInterest(uint256 assets) external {
        assets = bound(assets, 0.1e18, 1_000_000_000e18);
        deal(address(DAI), address(this), assets);
        fund.deposit(assets, address(this));

        uint256 assetsBefore = fund.totalAssets();

        vm.warp(block.timestamp + 1 days);
        mockDaiUsd.setMockUpdatedAt(block.timestamp);

        assertEq(
            fund.totalAssets(),
            assetsBefore,
            "Assets should not have increased because nothing has interacted with dsr."
        );

        uint256 maxRedeem = fund.maxRedeem(address(this));
        fund.redeem(maxRedeem, address(this), address(this));

        assertApproxEqAbs(DAI.balanceOf(address(this)), assets, 3, "Should have sent DAI to the user.");

        uint256 bal = manager.daiBalance(address(fund));
        assertGt(bal, 0, "Balance should have left pending yield in DSR.");
    }

    function testStrategistFunctions(uint256 assets) external {
        fund.setHoldingPosition(daiPosition);

        fund.setRebalanceDeviation(0.005e18);

        assets = bound(assets, 0.1e18, 1_000_000_000e18);
        deal(address(DAI), address(this), assets);
        fund.deposit(assets, address(this));

        // Deposit half the DAI into DSR.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToJoinDsr(assets / 2);
            data[0] = Fund.AdaptorCall({ adaptor: address(dsrAdaptor), callData: adaptorCalls });
        }
        fund.callOnAdaptor(data);

        uint256 fundDsrBalance = manager.daiBalance(address(fund));

        assertApproxEqAbs(fundDsrBalance, assets / 2, 2, "Should have deposited half the assets into the DSR.");

        // Advance some time.
        vm.warp(block.timestamp + 1 days);
        mockDaiUsd.setMockUpdatedAt(block.timestamp);

        // Deposit remaining assets into DSR.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToJoinDsr(type(uint256).max);
            data[0] = Fund.AdaptorCall({ adaptor: address(dsrAdaptor), callData: adaptorCalls });
        }
        fund.callOnAdaptor(data);

        // console.log(Pot(manager.pot()).chi());

        fundDsrBalance = manager.daiBalance(address(fund));
        assertGt(fundDsrBalance, assets + initialAssets, "Should have deposited all the assets into the DSR.");

        // Advance some time.
        vm.warp(block.timestamp + 10 days);
        mockDaiUsd.setMockUpdatedAt(block.timestamp);

        // Withdraw half the assets.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToExitDsr(assets / 2);
            data[0] = Fund.AdaptorCall({ adaptor: address(dsrAdaptor), callData: adaptorCalls });
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
            adaptorCalls[0] = _createBytesDataToExitDsr(type(uint256).max);
            data[0] = Fund.AdaptorCall({ adaptor: address(dsrAdaptor), callData: adaptorCalls });
        }
        fund.callOnAdaptor(data);

        assertGt(
            DAI.balanceOf(address(fund)),
            assets + initialAssets,
            "Should have withdrawn all the assets from the DSR."
        );
    }

    function testDrip(uint256 assets) external {
        assets = bound(assets, 0.1e18, 1_000_000_000e18);
        deal(address(DAI), address(this), assets);
        fund.deposit(assets, address(this));

        uint256 assetsBefore = fund.totalAssets();

        vm.warp(block.timestamp + 1 days);
        mockDaiUsd.setMockUpdatedAt(block.timestamp);

        assertEq(
            fund.totalAssets(),
            assetsBefore,
            "Assets should not have increased because nothing has interacted with dsr."
        );

        // Strategist calls drip.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToDrip();
            data[0] = Fund.AdaptorCall({ adaptor: address(dsrAdaptor), callData: adaptorCalls });
        }
        fund.callOnAdaptor(data);

        uint256 assetsAfter = fund.totalAssets();

        assertGt(assetsAfter, assetsBefore, "Total Assets should have increased.");
    }
}
