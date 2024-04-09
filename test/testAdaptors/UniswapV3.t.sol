// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { UniswapV3Adaptor } from "src/modules/adaptors/Uniswap/UniswapV3Adaptor.sol";
import { TickMath } from "@uniswapV3C/libraries/TickMath.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { PoolAddress } from "@uniswapV3P/libraries/PoolAddress.sol";
import { IUniswapV3Factory } from "@uniswapV3C/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@uniswapV3C/interfaces/IUniswapV3Pool.sol";
import { INonfungiblePositionManager } from "@uniswapV3P/interfaces/INonfungiblePositionManager.sol";
import "@uniswapV3C/libraries/FixedPoint128.sol";
import "@uniswapV3C/libraries/FullMath.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { UniswapV3PositionTracker } from "src/modules/adaptors/Uniswap/UniswapV3PositionTracker.sol";
import { ERC721Holder } from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import { IUniswapV3Router } from "src/interfaces/external/IUniswapV3Router.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";

import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";

// Will test the swapping and fund position management using adaptors
contract UniswapV3AdaptorTest is MainnetStarterTest, AdaptorHelperFunctions, ERC721Holder {
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using stdStorage for StdStorage;
    using Address for address;

    Fund private fund;

    IUniswapV3Factory internal factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    INonfungiblePositionManager internal positionManager =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    UniswapV3Adaptor private uniswapV3Adaptor;
    UniswapV3PositionTracker private tracker;

    IUniswapV3Router public uniswapV3Router = IUniswapV3Router(uniV3Router);

    uint32 private usdcPosition = 1;
    uint32 private wethPosition = 2;
    uint32 private daiPosition = 3;
    uint32 private usdcDaiPosition = 4;
    uint32 private usdcWethPosition = 5;

    function setUp() external {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 16869780;
        _startFork(rpcKey, blockNumber);

        // Run Starter setUp code.
        _setUp();

        tracker = new UniswapV3PositionTracker(positionManager);
        uniswapV3Adaptor = new UniswapV3Adaptor(address(positionManager), address(tracker));

        PriceRouter.ChainlinkDerivativeStorage memory stor;

        PriceRouter.AssetSettings memory settings;

        uint256 price = uint256(IChainlinkAggregator(WETH_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, WETH_USD_FEED);
        priceRouter.addAsset(WETH, settings, abi.encode(stor), price);

        price = uint256(IChainlinkAggregator(USDC_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, USDC_USD_FEED);
        priceRouter.addAsset(USDC, settings, abi.encode(stor), price);

        price = uint256(IChainlinkAggregator(DAI_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, DAI_USD_FEED);
        priceRouter.addAsset(DAI, settings, abi.encode(stor), price);

        // Add adaptors and positions to the registry.
        registry.trustAdaptor(address(uniswapV3Adaptor));

        registry.trustPosition(usdcPosition, address(erc20Adaptor), abi.encode(USDC));
        registry.trustPosition(daiPosition, address(erc20Adaptor), abi.encode(DAI));
        registry.trustPosition(wethPosition, address(erc20Adaptor), abi.encode(WETH));
        registry.trustPosition(usdcDaiPosition, address(uniswapV3Adaptor), abi.encode(DAI, USDC));
        registry.trustPosition(usdcWethPosition, address(uniswapV3Adaptor), abi.encode(USDC, WETH));

        string memory fundName = "UniswapV3 Fund V0.0";
        uint256 initialDeposit = 1e6;

        fund = _createFund(fundName, USDC, usdcPosition, abi.encode(true), initialDeposit);

        vm.label(address(fund), "fund");
        vm.label(strategist, "strategist");

        fund.addPositionToCatalogue(daiPosition);
        fund.addPositionToCatalogue(wethPosition);
        fund.addPositionToCatalogue(usdcDaiPosition);
        fund.addPositionToCatalogue(usdcWethPosition);

        fund.addPosition(1, daiPosition, abi.encode(true), false);
        fund.addPosition(1, wethPosition, abi.encode(true), false);
        fund.addPosition(1, usdcDaiPosition, abi.encode(true), false);
        fund.addPosition(1, usdcWethPosition, abi.encode(true), false);

        fund.addAdaptorToCatalogue(address(uniswapV3Adaptor));
        fund.addAdaptorToCatalogue(address(swapWithUniswapAdaptor));

        fund.setRebalanceDeviation(0.003e18);

        // Approve fund to spend all assets.
        USDC.approve(address(fund), type(uint256).max);
    }

    // ========================================== POSITION MANAGEMENT TEST ==========================================
    function testOpenUSDC_DAIPosition() external {
        deal(address(USDC), address(this), 101_000e6);
        fund.deposit(101_000e6, address(this));

        // Use `callOnAdaptor` to swap 50,000 USDC for DAI, and enter UniV3 position.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](2);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv3(USDC, DAI, 100, 50_500e6);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }

        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToOpenLP(DAI, USDC, 100, 50_000e18, 50_000e6, 10);
            data[1] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        }

        fund.callOnAdaptor(data);

        uint256[] memory positions = tracker.getTokens(address(fund), DAI, USDC);

        assertEq(positions.length, 1, "Tracker should only have 1 position.");
        assertEq(
            positions[0],
            positionManager.tokenOfOwnerByIndex(address(fund), 0),
            "Tracker should be tracking funds first Uni NFT."
        );
    }

    function testOpenUSDC_WETHPosition() external {
        deal(address(USDC), address(this), 101_000e6);
        fund.deposit(101_000e6, address(this));

        // Use `callOnAdaptor` to swap 50,000 USDC for DAI, and enter UniV3 position.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](2);
        uint24 fee = 500;
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv3(USDC, WETH, fee, 50_500e6);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }
        uint256 wethOut = priceRouter.getValue(USDC, 50_000e6, WETH);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToOpenLP(USDC, WETH, fee, 50_000e6, wethOut, 222);
            data[1] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        }
        fund.callOnAdaptor(data);

        uint256[] memory positions = tracker.getTokens(address(fund), USDC, WETH);

        assertEq(positions.length, 1, "Tracker should only have 1 position.");
        assertEq(
            positions[0],
            positionManager.tokenOfOwnerByIndex(address(fund), 0),
            "Tracker should be tracking funds first Uni NFT."
        );
    }

    function testOpeningAndClosingUniV3Position() external {
        deal(address(USDC), address(this), 101_000e6);
        fund.deposit(101_000e6, address(this));

        // Use `callOnAdaptor` to swap 50,000 USDC for DAI, and enter UniV3 position.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](2);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv3(USDC, DAI, 100, 50_500e6);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }

        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToOpenLP(DAI, USDC, 100, 50_000e18, 50_000e6, 2);
            data[1] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        }

        fund.callOnAdaptor(data);

        data = new Fund.AdaptorCall[](1);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToCloseLP(address(fund), 0);
            data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
            fund.callOnAdaptor(data);
        }

        uint256[] memory positions = tracker.getTokens(address(fund), DAI, USDC);
        assertEq(positions.length, 0, "Tracker should have zero positions.");
    }

    function testAddingToExistingPosition() external {
        deal(address(USDC), address(this), 201_000e6);
        fund.deposit(201_000e6, address(this));

        // Use `callOnAdaptor` to swap 50,000 USDC for DAI, and enter UniV3 position.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](2);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv3(USDC, DAI, 100, 100_500e6);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }

        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToOpenLP(DAI, USDC, 100, 50_000e18, 50_000e6, 100_000);
            data[1] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        }

        fund.callOnAdaptor(data);

        uint256[] memory positions = tracker.getTokens(address(fund), DAI, USDC);

        assertEq(positions.length, 1, "Tracker should only have 1 position.");
        assertEq(
            positions[0],
            positionManager.tokenOfOwnerByIndex(address(fund), 0),
            "Tracker should be tracking funds first Uni NFT."
        );

        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToAddLP(address(fund), 0, 50_000e18, 50_000e6);
            data = new Fund.AdaptorCall[](1);
            data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
            fund.callOnAdaptor(data);
        }

        positions = tracker.getTokens(address(fund), DAI, USDC);

        assertEq(positions.length, 1, "Tracker should only have 1 position.");
    }

    function testTakingFromExistingPosition() external {
        deal(address(USDC), address(this), 101_000e6);
        fund.deposit(101_000e6, address(this));

        // Use `callOnAdaptor` to swap 50,000 USDC for DAI, and enter UniV3 position.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](2);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv3(USDC, DAI, 100, 50_500e6);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToOpenLP(DAI, USDC, 100, 50_000e18, 50_000e6, 10);
            data[1] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        }

        fund.callOnAdaptor(data);

        data = new Fund.AdaptorCall[](1);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToTakeLP(address(fund), 0, 0.5e18, true);
            data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
            fund.callOnAdaptor(data);
        }

        uint256[] memory positions = tracker.getTokens(address(fund), DAI, USDC);

        assertEq(positions.length, 1, "Tracker should not have removed the position.");
    }

    function testTakingFees() external {
        deal(address(USDC), address(this), 101_000e6);
        fund.deposit(101_000e6, address(this));

        // Add liquidity to low liquidity DAI/USDC 0.3% fee pool.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](2);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv3(USDC, DAI, 100, 50_500e6);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }

        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToOpenLP(DAI, USDC, 3000, 50_000e18, 50_000e6, 100);
            data[1] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        }

        fund.callOnAdaptor(data);

        data = new Fund.AdaptorCall[](1);
        {
            bytes[] memory adaptorCalls = new bytes[](2);
            // Have Fund make several terrible swaps
            fund.setRebalanceDeviation(0.1e18);
            deal(address(USDC), address(fund), 1_000_000e6);
            deal(address(DAI), address(fund), 1_000_000e18);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv3(USDC, DAI, 3000, 10_000e6);
            adaptorCalls[1] = _createBytesDataForSwapWithUniv3(DAI, USDC, 3000, 10_000e18);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
            fund.callOnAdaptor(data);
        }

        // Check that fund did receive some fees.
        deal(address(USDC), address(fund), 1_000_000e6);
        deal(address(DAI), address(fund), 1_000_000e18);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToCollectFees(address(fund), 0, type(uint128).max, type(uint128).max);
            data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
            fund.callOnAdaptor(data);
        }

        assertTrue(USDC.balanceOf(address(fund)) > 1_000_000e6, "Fund should have earned USDC fees.");
        assertTrue(DAI.balanceOf(address(fund)) > 1_000_000e18, "Fund should have earned DAI fees.");
    }

    function testRangeOrders() external {
        uint256 assets = 100_000e6;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        // Use `callOnAdaptor` to swap 50,000 USDC for DAI, and enter UniV3 position.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _createBytesDataToOpenRangeOrder(DAI, USDC, 100, 0, type(uint256).max);

        data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        assertEq(USDC.balanceOf(address(fund)), 0, "Fund should have put all USDC in a UniV3 range order.");
    }

    function testFundWithSmorgasbordOfUniV3Positions() external {
        uint256 assets = 1_000_000e6;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        // Use `callOnAdaptor` to swap and enter 6 different UniV3 positions.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](2);
        {
            bytes[] memory adaptorCalls = new bytes[](2);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv3(USDC, WETH, 500, assets / 4);
            adaptorCalls[1] = _createBytesDataForSwapWithUniv3(USDC, DAI, 100, assets / 4);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }

        {
            bytes[] memory adaptorCalls = new bytes[](6);
            adaptorCalls[0] = _createBytesDataToOpenLP(DAI, USDC, 100, 50_000e18, 50_000e6, 30);
            adaptorCalls[1] = _createBytesDataToOpenLP(DAI, USDC, 500, 50_000e18, 50_000e6, 40);
            adaptorCalls[2] = _createBytesDataToOpenLP(DAI, USDC, 100, 50_000e18, 50_000e6, 100);

            adaptorCalls[3] = _createBytesDataToOpenLP(USDC, WETH, 500, 50_000e6, 36e18, 20);
            adaptorCalls[4] = _createBytesDataToOpenLP(USDC, WETH, 3000, 50_000e6, 36e18, 18);
            adaptorCalls[5] = _createBytesDataToOpenLP(USDC, WETH, 500, 50_000e6, 36e18, 200);
            data[1] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        }

        fund.callOnAdaptor(data);

        uint256[] memory positions = tracker.getTokens(address(fund), DAI, USDC);

        assertEq(positions.length, 3, "Tracker should have 3 DAI USDC positions.");
        for (uint256 i; i < 3; ++i) {
            assertEq(
                positions[i],
                positionManager.tokenOfOwnerByIndex(address(fund), i),
                "Tracker should be tracking funds ith Uni NFT."
            );
        }

        positions = tracker.getTokens(address(fund), USDC, WETH);

        assertEq(positions.length, 3, "Tracker should have 3 USDC WETH positions.");
        for (uint256 i; i < 3; ++i) {
            assertEq(
                positions[i],
                positionManager.tokenOfOwnerByIndex(address(fund), i + 3),
                "Tracker should be tracking funds ith Uni NFT."
            );
        }
    }

    function testIsDebtReturnsFalse() external {
        assertTrue(!uniswapV3Adaptor.isDebt(), "Adaptor does not report debt.");
    }

    function testHandlingUnusedApprovals() external {
        // Open a position, but manipulate state so that router does not use full allowance
        uint256 assets = 200_000e6;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        // Simulate a swap by setting Fund USDC and DAI balances.
        deal(address(USDC), address(fund), 100_000e6);
        deal(address(DAI), address(fund), 100_000e18);

        // Use `callOnAdaptor` to swap and enter 6 different UniV3 positions.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);

        adaptorCalls[0] = _createBytesDataToOpenLP(DAI, USDC, 100, 50_000e18, 50_000e6, 30);

        data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        assertTrue(
            USDC.balanceOf(address(fund)) > 50_000e6 || DAI.balanceOf(address(fund)) > 50_000e18,
            "One of that assets should not have been fully used."
        );

        // Make sure that approvals are zero.
        assertEq(USDC.allowance(address(fund), address(positionManager)), 0, "USDC allowance should be zero.");
        assertEq(DAI.allowance(address(fund), address(positionManager)), 0, "DAI allowance should be zero.");

        // Set balances to 50k each.
        deal(address(USDC), address(fund), 50_000e6);
        deal(address(DAI), address(fund), 50_000e18);

        // Make sure addToPosition revokes unused approvals.
        adaptorCalls[0] = _createBytesDataToAddLP(address(fund), 0, 50_000e18, 50_000e6);

        data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        assertTrue(
            USDC.balanceOf(address(fund)) > 0 || DAI.balanceOf(address(fund)) > 0,
            "One of that assets should not have been fully used."
        );

        // Make sure that approvals are zero.
        assertEq(USDC.allowance(address(fund), address(positionManager)), 0, "USDC allowance should be zero.");
        assertEq(DAI.allowance(address(fund), address(positionManager)), 0, "DAI allowance should be zero.");

        // Simulate some edge case scenario happens where there is an unused approval.
        vm.startPrank(address(fund));
        USDC.approve(address(positionManager), 1);
        DAI.approve(address(positionManager), 1);
        vm.stopPrank();

        // Confirm approvals are non zero.
        assertEq(USDC.allowance(address(fund), address(positionManager)), 1, "USDC allowance should be one.");
        assertEq(DAI.allowance(address(fund), address(positionManager)), 1, "DAI allowance should be one.");

        // Strategist can manually revoke approval.
        bytes[] memory adaptorCallsToRevoke = new bytes[](2);

        adaptorCallsToRevoke[0] = abi.encodeWithSelector(
            BaseAdaptor.revokeApproval.selector,
            USDC,
            address(positionManager)
        );
        adaptorCallsToRevoke[1] = abi.encodeWithSelector(
            BaseAdaptor.revokeApproval.selector,
            DAI,
            address(positionManager)
        );

        data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCallsToRevoke });
        fund.callOnAdaptor(data);

        // Make sure that approvals are zero.
        assertEq(USDC.allowance(address(fund), address(positionManager)), 0, "USDC allowance should be zero.");
        assertEq(DAI.allowance(address(fund), address(positionManager)), 0, "DAI allowance should be zero.");
    }

    function testPositionBurning() external {
        deal(address(USDC), address(this), 101_000e6);
        fund.deposit(101_000e6, address(this));

        // Add liquidity to low liquidity DAI/USDC 0.3% fee pool.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](2);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv3(USDC, DAI, 100, 50_500e6);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }

        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToOpenLP(DAI, USDC, 3000, 50_000e18, 50_000e6, 100);
            data[1] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        }

        fund.callOnAdaptor(data);

        data = new Fund.AdaptorCall[](1);

        // Have Fund make several terrible swaps
        fund.setRebalanceDeviation(0.1e18);
        deal(address(USDC), address(fund), 1_000_000e6);
        deal(address(DAI), address(fund), 1_000_000e18);
        {
            bytes[] memory adaptorCalls = new bytes[](2);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv3(USDC, DAI, 3000, 10_000e6);
            adaptorCalls[1] = _createBytesDataForSwapWithUniv3(DAI, USDC, 3000, 10_000e18);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
            fund.callOnAdaptor(data);
        }

        // First try to get rid of a token with liquidity + fees
        // Prank fund, and give tacker approval to spend token with liquidity + fees
        uint256 positionId = positionManager.tokenOfOwnerByIndex(address(fund), 0);
        vm.startPrank(address(fund));
        positionManager.approve(address(tracker), positionId);
        vm.expectRevert(bytes("Not cleared"));
        tracker.removePositionFromArray(positionId, DAI, USDC);
        vm.stopPrank();

        // Remove liquidity from position but do not take fees.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToTakeLP(address(fund), 0, type(uint128).max, false);
            data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
            fund.callOnAdaptor(data);
        }

        // Then try to get rid of a token with fees
        vm.startPrank(address(fund));
        positionManager.approve(address(tracker), positionId);
        vm.expectRevert(bytes("Not cleared"));
        tracker.removePositionFromArray(positionId, DAI, USDC);
        vm.stopPrank();

        // Set fund balance to 1M so we can check if fees were taken.
        deal(address(USDC), address(fund), 1_000_000e6);
        deal(address(DAI), address(fund), 1_000_000e18);
        // Finally collect fees and purge unused token.
        {
            bytes[] memory adaptorCalls = new bytes[](2);
            adaptorCalls[0] = _createBytesDataToCollectFees(address(fund), 0, type(uint128).max, type(uint128).max);
            adaptorCalls[1] = _createBytesDataToPurgePosition(address(fund), 0);
            data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
            fund.callOnAdaptor(data);
        }

        uint256[] memory positions = tracker.getTokens(address(fund), DAI, USDC);

        assertEq(positions.length, 0, "Tracker should have zero positions.");

        assertTrue(USDC.balanceOf(address(fund)) > 1_000_000e6, "Fund should have earned USDC fees.");
        assertTrue(DAI.balanceOf(address(fund)) > 1_000_000e18, "Fund should have earned DAI fees.");
    }

    // ========================================== REVERT TEST ==========================================
    function testUsingUntrackedLPPosition() external {
        // Remove USDC WETH LP position from fund.
        fund.removePosition(1, fund.creditPositions(1), false);

        // Strategist tries to move funds into USDC WETH LP position.
        uint256 assets = 100_000e6;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        // Use `callOnAdaptor` to enter a range order worth `assets` USDC.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        uint24 fee = 500;
        adaptorCalls[0] = _createBytesDataToOpenRangeOrder(USDC, WETH, fee, assets, 0);
        data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    UniswapV3Adaptor.UniswapV3Adaptor__UntrackedLiquidity.selector,
                    address(USDC),
                    address(WETH)
                )
            )
        );
        fund.callOnAdaptor(data);
    }

    function testUserDepositAndWithdrawRevert() external {
        vm.expectRevert(bytes(abi.encodeWithSelector(BaseAdaptor.BaseAdaptor__UserDepositsNotAllowed.selector)));
        uniswapV3Adaptor.deposit(0, abi.encode(0), abi.encode(0));

        vm.expectRevert(bytes(abi.encodeWithSelector(BaseAdaptor.BaseAdaptor__UserWithdrawsNotAllowed.selector)));
        uniswapV3Adaptor.withdraw(0, address(0), abi.encode(0), abi.encode(0));
    }

    function testWithdrawableFromReturnsZero() external {
        assertEq(
            uniswapV3Adaptor.withdrawableFrom(abi.encode(0), abi.encode(0)),
            0,
            "`withdrawableFrom` should return 0."
        );
    }

    function testAddingPositionWithUnsupportedToken0Reverts() external {
        vm.expectRevert(
            bytes(abi.encodeWithSelector(Registry.Registry__PositionPricingNotSetUp.selector, address(WBTC)))
        );
        registry.trustPosition(101, address(uniswapV3Adaptor), abi.encode(WBTC, USDT));
    }

    function testAddingPositionWithUnsupportedToken1Reverts() external {
        // Add WBTC as a supported asset.
        PriceRouter.ChainlinkDerivativeStorage memory stor;
        PriceRouter.AssetSettings memory settings;
        uint256 price = uint256(IChainlinkAggregator(WBTC_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, WBTC_USD_FEED);
        priceRouter.addAsset(WBTC, settings, abi.encode(stor), price);
        // TX still reverts because USDT is not set up.
        vm.expectRevert(
            bytes(abi.encodeWithSelector(Registry.Registry__PositionPricingNotSetUp.selector, address(USDT)))
        );
        registry.trustPosition(101, address(uniswapV3Adaptor), abi.encode(WBTC, USDT));
    }

    function testUsingLPTokensNotOwnedByFundOrTokensThatDoNotExist() external {
        deal(address(USDC), address(fund), 100_000e6);
        deal(address(DAI), address(fund), 100_000e6);

        uint256 tokenId = 100;
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);

        // Strategist first tries to add funds to a NFT the fund does not own.
        {
            adaptorCalls[0] = abi.encodeWithSelector(
                UniswapV3Adaptor.addToPosition.selector,
                tokenId,
                type(uint256).max,
                type(uint256).max,
                0,
                0
            );
            data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
            vm.expectRevert(
                bytes(abi.encodeWithSelector(UniswapV3Adaptor.UniswapV3Adaptor__NotTheOwner.selector, tokenId))
            );
            fund.callOnAdaptor(data);
        }

        // Strategist tries to add funds to a NFT that does not exist.
        tokenId = type(uint256).max;
        {
            adaptorCalls[0] = abi.encodeWithSelector(
                UniswapV3Adaptor.addToPosition.selector,
                tokenId,
                type(uint256).max,
                type(uint256).max,
                0,
                0
            );
            data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
            vm.expectRevert(bytes("ERC721: owner query for nonexistent token"));
            fund.callOnAdaptor(data);
        }
    }

    // ========================================== INTEGRATION TEST ==========================================
    /**
     * @notice Used to check if fees are being collected.
     */
    event Collect(uint256 indexed tokenId, address recipient, uint256 amount0, uint256 amount1);

    function testIntegration() external {
        // Have whale join the fund with 10M USDC.
        uint256 assets = 10_000_000e6;
        address whale = vm.addr(777);
        deal(address(USDC), whale, assets);
        vm.startPrank(whale);
        USDC.approve(address(fund), assets);
        fund.deposit(assets, whale);
        vm.stopPrank();

        // Strategist manages fund in order to achieve the following portfolio.
        // ~40% in USDC.
        // ~30% Uniswap V3 USDC/WETH 0.05%, 0.3%, and 1% LP
        // ~30% Uniswap V3 DAI/USDC 0.01% and 0.05% LP

        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](2);
        // Create data to add liquidity to Uniswap V3.
        {
            uint256 usdcToUse = assets.mulDivDown(15, 100);

            bytes[] memory adaptorCalls = new bytes[](2);
            {
                adaptorCalls[0] = _createBytesDataForSwapWithUniv3(USDC, WETH, 500, usdcToUse);
                adaptorCalls[1] = _createBytesDataForSwapWithUniv3(USDC, DAI, 100, usdcToUse);
                data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
            }

            // Since we are dividing the USDC into 2 LP positions each, cut it in half.
            usdcToUse = usdcToUse / 2;

            adaptorCalls = new bytes[](5);
            adaptorCalls[0] = _createBytesDataToOpenLP(USDC, WETH, 500, usdcToUse, type(uint256).max, 20);
            adaptorCalls[1] = _createBytesDataToOpenLP(USDC, WETH, 3000, usdcToUse, type(uint256).max, 80);
            adaptorCalls[2] = _createBytesDataToOpenLP(USDC, WETH, 10000, usdcToUse, type(uint256).max, 10);

            adaptorCalls[3] = _createBytesDataToOpenLP(DAI, USDC, 100, type(uint256).max, usdcToUse, 30);
            adaptorCalls[4] = _createBytesDataToOpenLP(DAI, USDC, 500, type(uint256).max, usdcToUse, 40);

            data[1] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        }
        fund.callOnAdaptor(data);

        // Strategist opens more Uniswap V3 positions.
        // Create data to add more liquidity to Uniswap V3.
        {
            uint256 usdcToUse = assets.mulDivDown(6, 1000);

            {
                bytes[] memory adaptorCalls = new bytes[](2);
                adaptorCalls[0] = _createBytesDataForSwapWithUniv3(USDC, WETH, 500, usdcToUse);
                adaptorCalls[1] = _createBytesDataForSwapWithUniv3(USDC, DAI, 100, usdcToUse);
                data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
            }

            // Since we are dividing the USDC into 2 LP positions each, cut it in half.
            usdcToUse = usdcToUse / 2;

            {
                bytes[] memory adaptorCalls = new bytes[](5);
                adaptorCalls[0] = _createBytesDataToOpenLP(USDC, WETH, 500, usdcToUse, type(uint256).max, 120);
                adaptorCalls[1] = _createBytesDataToOpenLP(USDC, WETH, 3000, usdcToUse, type(uint256).max, 44);
                adaptorCalls[2] = _createBytesDataToOpenLP(USDC, WETH, 10000, usdcToUse, type(uint256).max, 8);

                adaptorCalls[3] = _createBytesDataToOpenLP(DAI, USDC, 100, type(uint256).max, usdcToUse, 32);
                adaptorCalls[4] = _createBytesDataToOpenLP(DAI, USDC, 500, type(uint256).max, usdcToUse, 72);

                data[1] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
            }
        }
        fund.callOnAdaptor(data);

        // Have test contract perform a ton of swaps in Uniswap V3 DAI/USDC and USDC/WETH pools.
        {
            uint256 assetsToSwap = 1_000_000e6;
            deal(address(USDC), address(this), assetsToSwap);
            address[] memory path0 = new address[](2);
            path0[0] = address(USDC);
            path0[1] = address(DAI);
            address[] memory path1 = new address[](2);
            path1[0] = address(USDC);
            path1[1] = address(WETH);
            address[] memory path2 = new address[](2);
            path2[0] = address(DAI);
            path2[1] = address(USDC);
            address[] memory path3 = new address[](2);
            path3[0] = address(WETH);
            path3[1] = address(USDC);
            bytes memory swapData;
            uint24[] memory poolFees_100 = new uint24[](1);
            poolFees_100[0] = 100;
            uint24[] memory poolFees_500 = new uint24[](1);
            poolFees_500[0] = 500;
            uint24[] memory poolFees_3000 = new uint24[](1);
            poolFees_3000[0] = 3000;
            uint24[] memory poolFees_10000 = new uint24[](1);
            poolFees_10000[0] = 10000;

            for (uint256 i = 0; i < 10; i++) {
                uint256 swapAmount = assetsToSwap / 2;
                swapData = abi.encode(path0, poolFees_100, swapAmount, 0);
                uint256 daiAmount = swapWithUniV3(swapData, address(this), USDC, DAI);
                swapData = abi.encode(path1, poolFees_500, swapAmount, 0);
                uint256 wethAmount = swapWithUniV3(swapData, address(this), USDC, WETH);
                swapData = abi.encode(path2, poolFees_100, daiAmount, 0);
                assetsToSwap = swapWithUniV3(swapData, address(this), DAI, USDC);
                swapData = abi.encode(path3, poolFees_500, wethAmount, 0);
                assetsToSwap += swapWithUniV3(swapData, address(this), WETH, USDC);

                swapAmount = assetsToSwap / 2;
                swapData = abi.encode(path0, poolFees_500, swapAmount, 0);
                daiAmount = swapWithUniV3(swapData, address(this), USDC, DAI);
                swapData = abi.encode(path1, poolFees_3000, swapAmount, 0);
                wethAmount = swapWithUniV3(swapData, address(this), USDC, WETH);
                swapData = abi.encode(path2, poolFees_500, daiAmount, 0);
                assetsToSwap = swapWithUniV3(swapData, address(this), DAI, USDC);
                swapData = abi.encode(path3, poolFees_3000, wethAmount, 0);
                assetsToSwap += swapWithUniV3(swapData, address(this), WETH, USDC);

                swapAmount = assetsToSwap;
                swapData = abi.encode(path1, poolFees_10000, swapAmount, 0);
                wethAmount = swapWithUniV3(swapData, address(this), USDC, WETH);
                swapData = abi.encode(path3, poolFees_10000, wethAmount, 0);
                assetsToSwap = swapWithUniV3(swapData, address(this), WETH, USDC);
            }
        }
        data = new Fund.AdaptorCall[](1);
        {
            bytes[] memory adaptorCalls = new bytes[](10);

            // Collect fees from LP tokens 0, 1, 2.
            adaptorCalls[0] = _createBytesDataToCollectFees(address(fund), 0, type(uint128).max, type(uint128).max);
            adaptorCalls[1] = _createBytesDataToCollectFees(address(fund), 1, type(uint128).max, type(uint128).max);
            adaptorCalls[2] = _createBytesDataToCollectFees(address(fund), 2, type(uint128).max, type(uint128).max);

            // Take varying amounts of liquidity from tokens 3, 4, 5 using takeFromPosition.
            adaptorCalls[3] = _createBytesDataToTakeLP(address(fund), 3, 1e18, true);
            adaptorCalls[4] = _createBytesDataToTakeLP(address(fund), 4, 0.75e18, true);
            adaptorCalls[5] = _createBytesDataToTakeLP(address(fund), 5, 0.5e18, true);

            //// Take all liquidity from tokens 6, 7, 8, 9 using closePosition.
            adaptorCalls[6] = _createBytesDataToCloseLP(address(fund), 6);
            adaptorCalls[7] = _createBytesDataToCloseLP(address(fund), 7);
            adaptorCalls[8] = _createBytesDataToCloseLP(address(fund), 8);
            adaptorCalls[9] = _createBytesDataToCloseLP(address(fund), 9);

            data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        }

        // Change rebalance deviation, so the rebalance check passes. Normally any yield would be sent to a vesting contract,
        // but for simplicity this test is not doing that.
        fund.setRebalanceDeviation(0.01e18);

        // Check that all Fund NFT positions have their Fees Collected by checking emitted Collect events.
        uint256[] memory nfts = new uint256[](10);
        for (uint8 i; i < 10; i++) {
            nfts[i] = positionManager.tokenOfOwnerByIndex(address(fund), i);
            vm.expectEmit(true, true, false, false, address(positionManager));
            emit Collect(nfts[i], address(fund), 0, 0);
        }
        fund.callOnAdaptor(data);

        // Check that closePosition positions NFT are burned.
        for (uint8 i = 6; i < 10; i++) {
            vm.expectRevert(bytes("ERC721: owner query for nonexistent token"));
            positionManager.ownerOf(nfts[i]);
        }

        // New User deposits more funds.
        assets = 100_000e6;
        address user = vm.addr(7777);
        deal(address(USDC), user, assets);
        vm.startPrank(user);
        USDC.approve(address(fund), assets);
        fund.deposit(assets, user);
        vm.stopPrank();

        // Add to some LP positions.
        data = new Fund.AdaptorCall[](2);
        {
            uint256 usdcToUse = assets.mulDivDown(25, 100);

            {
                bytes[] memory adaptorCalls = new bytes[](2);
                adaptorCalls[0] = _createBytesDataForSwapWithUniv3(USDC, WETH, 500, usdcToUse);
                adaptorCalls[1] = _createBytesDataForSwapWithUniv3(USDC, DAI, 100, usdcToUse);
                data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
            }

            // Since we are dividing the USDC into 2 LP positions each, cut it in half.
            usdcToUse = usdcToUse / 2;

            // Add liquidity to DAI/USDC positions.
            {
                bytes[] memory adaptorCalls = new bytes[](3);
                adaptorCalls[0] = _createBytesDataToAddLP(address(fund), 3, type(uint256).max, usdcToUse);
                adaptorCalls[1] = _createBytesDataToAddLP(address(fund), 4, type(uint256).max, usdcToUse);

                // Add liquidity to USDC/WETH position.
                adaptorCalls[2] = _createBytesDataToAddLP(address(fund), 4, 2 * usdcToUse, type(uint256).max);
                data[1] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
            }
        }
        fund.callOnAdaptor(data);

        // Run another round of swaps to generate fees.
        // Have test contract perform a ton of swaps in Uniswap V3 DAI/USDC and USDC/WETH pools.
        {
            uint256 assetsToSwap = 1_000_000e6;
            deal(address(USDC), address(this), assetsToSwap);
            address[] memory path0 = new address[](2);
            path0[0] = address(USDC);
            path0[1] = address(DAI);
            address[] memory path1 = new address[](2);
            path1[0] = address(USDC);
            path1[1] = address(WETH);
            address[] memory path2 = new address[](2);
            path2[0] = address(DAI);
            path2[1] = address(USDC);
            address[] memory path3 = new address[](2);
            path3[0] = address(WETH);
            path3[1] = address(USDC);
            bytes memory swapData;
            uint24[] memory poolFees_100 = new uint24[](1);
            poolFees_100[0] = 100;
            uint24[] memory poolFees_500 = new uint24[](1);
            poolFees_500[0] = 500;
            uint24[] memory poolFees_3000 = new uint24[](1);
            poolFees_3000[0] = 3000;
            uint24[] memory poolFees_10000 = new uint24[](1);
            poolFees_10000[0] = 10000;

            for (uint256 i = 0; i < 10; i++) {
                uint256 swapAmount = assetsToSwap / 2;
                swapData = abi.encode(path0, poolFees_100, swapAmount, 0);
                uint256 daiAmount = swapWithUniV3(swapData, address(this), USDC, DAI);
                swapData = abi.encode(path1, poolFees_500, swapAmount, 0);
                uint256 wethAmount = swapWithUniV3(swapData, address(this), USDC, WETH);
                swapData = abi.encode(path2, poolFees_100, daiAmount, 0);
                assetsToSwap = swapWithUniV3(swapData, address(this), DAI, USDC);
                swapData = abi.encode(path3, poolFees_500, wethAmount, 0);
                assetsToSwap += swapWithUniV3(swapData, address(this), WETH, USDC);

                swapAmount = assetsToSwap / 2;
                swapData = abi.encode(path0, poolFees_500, swapAmount, 0);
                daiAmount = swapWithUniV3(swapData, address(this), USDC, DAI);
                swapData = abi.encode(path1, poolFees_3000, swapAmount, 0);
                wethAmount = swapWithUniV3(swapData, address(this), USDC, WETH);
                swapData = abi.encode(path2, poolFees_500, daiAmount, 0);
                assetsToSwap = swapWithUniV3(swapData, address(this), DAI, USDC);
                swapData = abi.encode(path3, poolFees_3000, wethAmount, 0);
                assetsToSwap += swapWithUniV3(swapData, address(this), WETH, USDC);

                swapAmount = assetsToSwap;
                swapData = abi.encode(path1, poolFees_10000, swapAmount, 0);
                wethAmount = swapWithUniV3(swapData, address(this), USDC, WETH);
                swapData = abi.encode(path3, poolFees_10000, wethAmount, 0);
                assetsToSwap = swapWithUniV3(swapData, address(this), WETH, USDC);
            }
        }

        // Close all positions.
        data = new Fund.AdaptorCall[](1);
        {
            bytes[] memory adaptorCalls = new bytes[](6);

            //// Take all liquidity from tokens 0, 1, 2, 3, 4, and 5 using closePosition.
            adaptorCalls[0] = _createBytesDataToCloseLP(address(fund), 0);
            adaptorCalls[1] = _createBytesDataToCloseLP(address(fund), 1);
            adaptorCalls[2] = _createBytesDataToCloseLP(address(fund), 2);
            adaptorCalls[3] = _createBytesDataToCloseLP(address(fund), 3);
            adaptorCalls[4] = _createBytesDataToCloseLP(address(fund), 4);
            adaptorCalls[5] = _createBytesDataToCloseLP(address(fund), 5);

            data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        }

        // Check that all Fund NFT positions have their Fees Collected by checking emitted Collect events.
        nfts = new uint256[](6);
        for (uint8 i; i < 6; i++) {
            nfts[i] = positionManager.tokenOfOwnerByIndex(address(fund), i);
            vm.expectEmit(true, true, false, false, address(positionManager));
            emit Collect(nfts[i], address(fund), 0, 0);
        }
        fund.callOnAdaptor(data);
        assertEq(positionManager.balanceOf(address(fund)), 0, "Fund should have no more LP positions.");

        // Strategist converts DAI and WETH to USDC for easier withdraws.
        {
            bytes[] memory adaptorCalls = new bytes[](2);

            adaptorCalls[0] = _createBytesDataForSwapWithUniv3(DAI, USDC, 100, DAI.balanceOf(address(fund)));
            adaptorCalls[1] = _createBytesDataForSwapWithUniv3(WETH, USDC, 500, WETH.balanceOf(address(fund)));

            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }
        fund.callOnAdaptor(data);

        // Have users exit the fund.
        uint256 whaleAssetsToWithdraw = fund.maxWithdraw(whale);
        uint256 userAssetsToWithdraw = fund.maxWithdraw(user);
        uint256 fundAssets = fund.totalAssets();
        uint256 fundLiability = whaleAssetsToWithdraw + userAssetsToWithdraw;
        assertGe(fundAssets, fundLiability, "Fund Assets should be greater than or equal to its Liability.");

        vm.startPrank(whale);
        fund.redeem(fund.balanceOf(whale), whale, whale);
        vm.stopPrank();

        vm.startPrank(user);
        fund.redeem(fund.balanceOf(user), user, user);
        vm.stopPrank();
    }

    function testWorkingWithMaxNumberOfTrackedTokens() external {
        deal(address(USDC), address(this), 202_000e6);
        fund.deposit(202_000e6, address(this));

        // Give fund both assets so no swap is needed.
        deal(address(USDC), address(fund), 101_000e6);
        deal(address(DAI), address(fund), 101_000e18);

        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);

        adaptorCalls[0] = _createBytesDataToOpenLP(DAI, USDC, 100, 1_000e18, 1_000e6, 100_000);
        data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        uint256[] memory positions;

        // Fill tracker with Max positions.
        for (uint256 i; i < tracker.MAX_HOLDINGS(); ++i) {
            fund.callOnAdaptor(data);
            positions = tracker.getTokens(address(fund), DAI, USDC);
            assertEq(positions.length, i + 1, "Tracker should i+1 positions.");
        }

        // Adding 1 more position should revert.
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(UniswapV3PositionTracker.UniswapV3PositionTracker__MaxHoldingsExceeded.selector)
            )
        );
        fund.callOnAdaptor(data);

        // Loop through, and remove all liquidity from positions.'
        for (uint256 i; i < tracker.MAX_HOLDINGS(); ++i) {
            adaptorCalls[0] = _createBytesDataToTakeLP(address(fund), i, type(uint128).max, true);
            data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
            fund.callOnAdaptor(data);
        }

        // Try purging all positons in 1 TX and make sure gas usage is feasible
        adaptorCalls[0] = _createBytesDataToPurgeAllZeroLiquidityPosition(DAI, USDC);
        data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        uint256 startingGas = gasleft();
        fund.callOnAdaptor(data);
        assertLt(startingGas - gasleft(), 10_000_000, "Gas should be below 10M.");

        positions = tracker.getTokens(address(fund), DAI, USDC);
        assertEq(positions.length, 0, "Fund should zero DAI USDC positions.");
    }

    function testFundPurgingSinglePositionsAndAllUnusedPositions() external {
        // create 10 posiitons in the fund
        deal(address(USDC), address(this), 202_000e6);
        fund.deposit(202_000e6, address(this));

        // Give fund both assets so no swap is needed.
        deal(address(USDC), address(fund), 101_000e6);
        deal(address(DAI), address(fund), 101_000e18);

        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);

        adaptorCalls[0] = _createBytesDataToOpenLP(DAI, USDC, 100, 1_000e18, 1_000e6, 100_000);
        data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        uint256[] memory positions;

        // Fill tracker with 10 positions.
        for (uint256 i; i < 10; ++i) {
            fund.callOnAdaptor(data);
            positions = tracker.getTokens(address(fund), DAI, USDC);
        }

        // Try purging a position that has liquidity
        adaptorCalls[0] = _createBytesDataToPurgePosition(address(fund), 0);
        data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    UniswapV3Adaptor.UniswapV3Adaptor__PurgingPositionWithLiquidity.selector,
                    positionManager.tokenOfOwnerByIndex(address(fund), 0)
                )
            )
        );
        fund.callOnAdaptor(data);

        // Call purge all and make sure nothing happens.
        adaptorCalls[0] = _createBytesDataToPurgeAllZeroLiquidityPosition(DAI, USDC);
        data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        positions = tracker.getTokens(address(fund), DAI, USDC);
        assertEq(positions.length, 10, "Fund should have 10 DAI USDC positions.");

        // Remove liquidity from some positions.
        adaptorCalls = new bytes[](5);
        adaptorCalls[0] = _createBytesDataToTakeLP(address(fund), 2, 0.5e18, true);
        adaptorCalls[1] = _createBytesDataToTakeLP(address(fund), 7, type(uint128).max, true);
        adaptorCalls[2] = _createBytesDataToTakeLP(address(fund), 3, 0.5e18, true);
        adaptorCalls[3] = _createBytesDataToTakeLP(address(fund), 9, type(uint128).max, true);
        adaptorCalls[4] = _createBytesDataToTakeLP(address(fund), 1, type(uint128).max, true);
        data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        // Purge 1 Valid position.
        adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _createBytesDataToPurgePosition(address(fund), 7);
        data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        positions = tracker.getTokens(address(fund), DAI, USDC);
        assertEq(positions.length, 9, "Fund should have 9 DAI USDC positions.");

        // Purge all unused positions.
        adaptorCalls[0] = _createBytesDataToPurgeAllZeroLiquidityPosition(DAI, USDC);
        data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        positions = tracker.getTokens(address(fund), DAI, USDC);
        assertEq(positions.length, 7, "Fund should have 7 DAI USDC positions.");

        for (uint256 i; i < 7; ++i) {
            assertEq(
                positions[i],
                positionManager.tokenOfOwnerByIndex(address(fund), i),
                "Tracker should be tracking funds ith Uni NFT."
            );
        }
    }

    function testFundAddingAndRemovingPositionReverts() external {
        deal(address(USDC), address(this), 101_000e6);
        fund.deposit(101_000e6, address(this));

        // Use `callOnAdaptor` to swap 50,000 USDC for DAI, and enter UniV3 position.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](2);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv3(USDC, DAI, 100, 50_500e6);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }

        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToOpenLP(DAI, USDC, 100, 50_000e18, 50_000e6, 10);
            data[1] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        }

        fund.callOnAdaptor(data);

        // Try to have the fund add a position it does not own.
        vm.startPrank(address(fund));
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    UniswapV3PositionTracker.UniswapV3PositionTracker__CallerDoesNotOwnTokenId.selector
                )
            )
        );
        tracker.addPositionToArray(100, USDC, DAI);
        vm.stopPrank();

        // Try to re add a position.
        uint256[] memory positions = tracker.getTokens(address(fund), DAI, USDC);
        vm.startPrank(address(fund));
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    UniswapV3PositionTracker.UniswapV3PositionTracker__TokenIdAlreadyTracked.selector
                )
            )
        );
        tracker.addPositionToArray(positions[0], DAI, USDC);
        vm.stopPrank();

        deal(address(DAI), address(this), 50_000e18);
        deal(address(USDC), address(this), 50_000e6);
        address(uniswapV3Adaptor).functionDelegateCall(
            _createBytesDataToOpenLP(DAI, USDC, 100, 50_000e18, 50_000e6, 10)
        );
        uint256 id = positionManager.tokenOfOwnerByIndex(address(this), 0);

        uint256 totalAssetsBefore = fund.totalAssets();

        // Send token to fund.
        positionManager.transferFrom(address(this), address(fund), id);

        // Check totalAssets.
        assertEq(fund.totalAssets(), totalAssetsBefore, "Total Assets should not change.");

        // First pass in incorrect underlying.
        vm.startPrank(address(fund));
        positionManager.approve(address(tracker), id);
        vm.expectRevert(
            bytes(abi.encodeWithSelector(UniswapV3PositionTracker.UniswapV3PositionTracker__TokenIdNotFound.selector))
        );
        tracker.removePositionFromArray(id, USDC, WETH);
        vm.stopPrank();

        // Now pass in correct underlying.
        vm.startPrank(address(fund));
        vm.expectRevert(
            bytes(abi.encodeWithSelector(UniswapV3PositionTracker.UniswapV3PositionTracker__TokenIdNotFound.selector))
        );
        tracker.removePositionFromArray(id, DAI, USDC);
        vm.stopPrank();

        // Try re-adding same position but with tokens swapped, should succeed but totalAssets should remain the same.
        vm.startPrank(address(fund));
        tracker.addPositionToArray(positions[0], USDC, DAI);
        vm.stopPrank();

        // Check totalAssets.
        assertEq(fund.totalAssets(), totalAssetsBefore, "Total Assets should not change.");

        // Try removing an owned postion from tracker using the remove unowned position and make sure it reverts
        vm.startPrank(address(fund));
        vm.expectRevert(
            bytes(abi.encodeWithSelector(UniswapV3PositionTracker.UniswapV3PositionTracker__CallerOwnsTokenId.selector))
        );
        tracker.removePositionFromArrayThatIsNotOwnedByCaller(id, DAI, USDC);
        vm.stopPrank();
    }

    function testGriefingAttack() external {
        deal(address(USDC), address(this), 101_000e6);
        fund.deposit(101_000e6, address(this));

        // Use `callOnAdaptor` to swap 50,000 USDC for DAI, and enter UniV3 position.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](2);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv3(USDC, DAI, 100, 50_500e6);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }

        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToOpenLP(DAI, USDC, 100, 50_000e18, 50_000e6, 10);
            data[1] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        }

        fund.callOnAdaptor(data);

        uint256 gas = gasleft();
        fund.totalAssets();
        uint256 totalAssetsGasCost = gas - gasleft();

        // Send multiple uniswap V3 NFTs to fund.
        deal(address(USDC), address(this), 50_000e6);
        deal(address(DAI), address(this), 50_000e18);
        for (uint256 i; i < 10; ++i) {
            address(uniswapV3Adaptor).functionDelegateCall(
                _createBytesDataToOpenLP(DAI, USDC, 100, 1_000e18, 1_000e6, 10)
            );
            uint256 id = positionManager.tokenOfOwnerByIndex(address(this), 0);

            // Send token to fund.
            positionManager.transferFrom(address(this), address(fund), id);
        }

        // Make sure totalAssets gas cost has not rose significantly.
        gas = gasleft();
        fund.totalAssets();
        uint256 totalAssetsGasCostAfterAttack = gas - gasleft();

        assertEq(totalAssetsGasCost, totalAssetsGasCostAfterAttack, "Gas cost should be the same.");
    }

    function testIdsAreIgnoredIfNotOwnedByFund() external {
        deal(address(USDC), address(this), 101_000e6);
        fund.deposit(101_000e6, address(this));

        // Use `callOnAdaptor` to swap 50,000 USDC for DAI, and enter UniV3 position.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](2);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv3(USDC, DAI, 100, 50_500e6);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }

        {
            bytes[] memory adaptorCalls = new bytes[](2);
            adaptorCalls[0] = _createBytesDataToOpenLP(DAI, USDC, 100, 25_000e18, 25_000e6, 1_000);
            adaptorCalls[1] = _createBytesDataToOpenLP(DAI, USDC, 100, 25_000e18, 25_000e6, 1_000);
            data[1] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
        }

        fund.callOnAdaptor(data);

        // Save total assets.
        uint256 totalAssetsBefore = fund.totalAssets();

        // Now that fund owns 2 uniswap v3 positions, spoof fund to transfer 1 out.
        vm.startPrank(address(fund));
        uint256 idToRemove = positionManager.tokenOfOwnerByIndex(address(fund), 0);
        positionManager.transferFrom(address(fund), address(this), idToRemove);
        vm.stopPrank();

        // Tracked array still returns 2 LP positions.
        uint256[] memory positions = tracker.getTokens(address(fund), DAI, USDC);

        assertEq(positions.length, 2, "Tracker should report 2 DAI USDC LP positions.");

        // Total assets should be cut in half because the LP position the fund does not own should not be included in totalAssets.
        assertApproxEqRel(
            fund.totalAssets(),
            totalAssetsBefore / 2,
            0.05e18,
            "Fund should have about half the assets."
        );

        // Strategist can remove the unowned tracked position.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToRemoveTrackedPositionNotOwned(idToRemove, DAI, USDC);
            data = new Fund.AdaptorCall[](1);
            data[0] = Fund.AdaptorCall({ adaptor: address(uniswapV3Adaptor), callData: adaptorCalls });
            fund.callOnAdaptor(data);
        }

        positions = tracker.getTokens(address(fund), DAI, USDC);

        assertEq(positions.length, 1, "Tracker should report 1 DAI USDC LP position1.");

        // Total assets should not change much.
        assertApproxEqRel(
            fund.totalAssets(),
            totalAssetsBefore / 2,
            0.05e18,
            "Fund should have about half the assets."
        );
    }

    // ========================================= HELPER FUNCTIONS =========================================

    function swapWithUniV3(
        bytes memory swapData,
        address receiver,
        ERC20 assetIn,
        ERC20
    ) public returns (uint256 amountOut) {
        (address[] memory path, uint24[] memory poolFees, uint256 amount, uint256 amountOutMin) = abi.decode(
            swapData,
            (address[], uint24[], uint256, uint256)
        );

        // Approve assets to be swapped through the router.
        assetIn.safeApprove(address(uniswapV3Router), amount);

        // Encode swap parameters.
        bytes memory encodePackedPath = abi.encodePacked(address(assetIn));
        for (uint256 i = 1; i < path.length; i++)
            encodePackedPath = abi.encodePacked(encodePackedPath, poolFees[i - 1], path[i]);

        // Execute the swap.
        amountOut = uniswapV3Router.exactInput(
            IUniswapV3Router.ExactInputParams({
                path: encodePackedPath,
                recipient: receiver,
                deadline: block.timestamp + 60,
                amountIn: amount,
                amountOutMinimum: amountOutMin
            })
        );
    }

    function _sqrt(uint256 _x) internal pure returns (uint256 y) {
        uint256 z = (_x + 1) / 2;
        y = _x;
        while (z < y) {
            y = z;
            z = (_x / z + z) / 2;
        }
    }

    /**
     * @notice Get the upper and lower tick around token0, token1.
     * @param token0 The 0th Token in the UniV3 Pair
     * @param token1 The 1st Token in the UniV3 Pair
     * @param fee The desired fee pool
     * @param size Dictates the amount of ticks liquidity will cover
     *             @dev Must be an even number
     * @param shift Allows the upper and lower tick to be moved up or down relative
     *              to current price. Useful for range orders.
     */
    function _getUpperAndLowerTick(
        ERC20 token0,
        ERC20 token1,
        uint24 fee,
        int24 size,
        int24 shift
    ) internal view returns (int24 lower, int24 upper) {
        uint256 price = priceRouter.getExchangeRate(token1, token0);
        uint256 ratioX192 = ((10 ** token1.decimals()) << 192) / (price);
        uint160 sqrtPriceX96 = SafeCast.toUint160(_sqrt(ratioX192));
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
        tick = tick + shift;

        IUniswapV3Pool pool = IUniswapV3Pool(factory.getPool(address(token0), address(token1), fee));
        int24 spacing = pool.tickSpacing();
        lower = tick - (tick % spacing);
        lower = lower - ((spacing * size) / 2);
        upper = lower + spacing * size;
    }

    function _createBytesDataToOpenLP(
        ERC20 token0,
        ERC20 token1,
        uint24 poolFee,
        uint256 amount0,
        uint256 amount1,
        int24 size
    ) internal view returns (bytes memory) {
        (int24 lower, int24 upper) = _getUpperAndLowerTick(token0, token1, poolFee, size, 0);
        return
            abi.encodeWithSelector(
                UniswapV3Adaptor.openPosition.selector,
                token0,
                token1,
                poolFee,
                amount0,
                amount1,
                0,
                0,
                lower,
                upper
            );
    }

    function _createBytesDataToCloseLP(address owner, uint256 index) internal view returns (bytes memory) {
        uint256 tokenId = positionManager.tokenOfOwnerByIndex(owner, index);
        return abi.encodeWithSelector(UniswapV3Adaptor.closePosition.selector, tokenId, 0, 0);
    }

    function _createBytesDataToAddLP(
        address owner,
        uint256 index,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (bytes memory) {
        uint256 tokenId = positionManager.tokenOfOwnerByIndex(owner, index);
        return abi.encodeWithSelector(UniswapV3Adaptor.addToPosition.selector, tokenId, amount0, amount1, 0, 0);
    }

    function _createBytesDataToTakeLP(
        address owner,
        uint256 index,
        uint256 liquidityPer,
        bool takeFees
    ) internal view returns (bytes memory) {
        uint256 tokenId = positionManager.tokenOfOwnerByIndex(owner, index);
        uint128 liquidity;
        if (liquidityPer >= 1e18) liquidity = type(uint128).max;
        else {
            (, , , , , , , uint128 positionLiquidity, , , , ) = positionManager.positions(tokenId);
            liquidity = uint128((positionLiquidity * liquidityPer) / 1e18);
        }
        return abi.encodeWithSelector(UniswapV3Adaptor.takeFromPosition.selector, tokenId, liquidity, 0, 0, takeFees);
    }

    function _createBytesDataToCollectFees(
        address owner,
        uint256 index,
        uint128 amount0,
        uint128 amount1
    ) internal view returns (bytes memory) {
        uint256 tokenId = positionManager.tokenOfOwnerByIndex(owner, index);
        return abi.encodeWithSelector(UniswapV3Adaptor.collectFees.selector, tokenId, amount0, amount1);
    }

    function _createBytesDataToPurgePosition(address owner, uint256 index) internal view returns (bytes memory) {
        uint256 tokenId = positionManager.tokenOfOwnerByIndex(owner, index);
        return abi.encodeWithSelector(UniswapV3Adaptor.purgeSinglePosition.selector, tokenId);
    }

    function _createBytesDataToPurgeAllZeroLiquidityPosition(
        ERC20 token0,
        ERC20 token1
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(UniswapV3Adaptor.purgeAllZeroLiquidityPositions.selector, token0, token1);
    }

    function _createBytesDataToRemoveTrackedPositionNotOwned(
        uint256 id,
        ERC20 token0,
        ERC20 token1
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(UniswapV3Adaptor.removeUnOwnedPositionFromTracker.selector, id, token0, token1);
    }

    function _createBytesDataToOpenRangeOrder(
        ERC20 token0,
        ERC20 token1,
        uint24 poolFee,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (bytes memory) {
        int24 lower;
        int24 upper;
        if (amount0 > 0) {
            (lower, upper) = _getUpperAndLowerTick(token0, token1, poolFee, 2, 100);
        } else {
            (lower, upper) = _getUpperAndLowerTick(token0, token1, poolFee, 2, -100);
        }

        return
            abi.encodeWithSelector(
                UniswapV3Adaptor.openPosition.selector,
                token0,
                token1,
                poolFee,
                amount0,
                amount1,
                0,
                0,
                lower,
                upper
            );
    }

    // Used to spoof adaptor into thinkig this is a fund contract.
    function isPositionUsed(uint256) public pure returns (bool) {
        return true;
    }
}
