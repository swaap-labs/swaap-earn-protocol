// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { MorphoAaveV3ATokenP2PAdaptor, IMorphoV3, BaseAdaptor } from "src/modules/adaptors/Morpho/MorphoAaveV3ATokenP2PAdaptor.sol";
import { MorphoAaveV3ATokenCollateralAdaptor } from "src/modules/adaptors/Morpho/MorphoAaveV3ATokenCollateralAdaptor.sol";
import { MorphoAaveV3DebtTokenAdaptor } from "src/modules/adaptors/Morpho/MorphoAaveV3DebtTokenAdaptor.sol";
import { WstEthExtension } from "src/modules/price-router/Extensions/Lido/WstEthExtension.sol";
import { IPoolV3 } from "src/interfaces/external/IPoolV3.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";

import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";

contract FundAaveV3MorphoTest is MainnetStarterTest, AdaptorHelperFunctions {
    using SafeTransferLib for ERC20;
    using Math for uint256;

    MorphoAaveV3ATokenP2PAdaptor private p2pATokenAdaptor;
    MorphoAaveV3ATokenCollateralAdaptor private collateralATokenAdaptor;
    MorphoAaveV3DebtTokenAdaptor private debtTokenAdaptor;
    WstEthExtension private wstethExtension;
    Fund private fund;

    IPoolV3 private pool = IPoolV3(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);

    IMorphoV3 private morpho = IMorphoV3(0x33333aea097c193e66081E930c33020272b33333);
    address private rewardHandler = 0x3B14E5C73e0A56D607A8688098326fD4b4292135;
    WstEthExtension private wstEthOracle;

    address private aWstEthWhale = 0xAF06acFD1BD492B913d5807d562e4FC3A6343C4E;

    uint32 private wethPosition = 1;
    uint32 private wstethPosition = 2;
    uint32 private morphoAWethPosition = 1_000_001;
    uint32 private morphoAWstEthPosition = 1_000_002;
    uint32 private morphoDebtWethPosition = 1_000_003;

    function setUp() external {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 17297048;
        _startFork(rpcKey, blockNumber);

        // Run Starter setUp code.
        _setUp();

        wstethExtension = new WstEthExtension(priceRouter);

        p2pATokenAdaptor = new MorphoAaveV3ATokenP2PAdaptor(address(morpho), rewardHandler);
        collateralATokenAdaptor = new MorphoAaveV3ATokenCollateralAdaptor(address(morpho), 1.05e18, rewardHandler);
        debtTokenAdaptor = new MorphoAaveV3DebtTokenAdaptor(address(morpho), 1.05e18);

        PriceRouter.ChainlinkDerivativeStorage memory stor;

        PriceRouter.AssetSettings memory settings;

        uint256 price = uint256(IChainlinkAggregator(WETH_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, WETH_USD_FEED);
        priceRouter.addAsset(WETH, settings, abi.encode(stor), price);

        price = uint256(IChainlinkAggregator(USDC_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, USDC_USD_FEED);
        priceRouter.addAsset(USDC, settings, abi.encode(stor), price);

        price = uint256(IChainlinkAggregator(STETH_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, STETH_USD_FEED);
        priceRouter.addAsset(STETH, settings, abi.encode(stor), price);

        // Add wstEth.
        uint256 wstethToStethConversion = wstethExtension.stEth().getPooledEthByShares(1e18);
        price = price.mulDivDown(wstethToStethConversion, 1e18);
        settings = PriceRouter.AssetSettings(EXTENSION_DERIVATIVE, address(wstethExtension));
        priceRouter.addAsset(WSTETH, settings, abi.encode(0), price);

        // Setup Fund:

        // Add adaptors and positions to the registry.
        registry.trustAdaptor(address(p2pATokenAdaptor));
        registry.trustAdaptor(address(collateralATokenAdaptor));
        registry.trustAdaptor(address(debtTokenAdaptor));

        registry.trustPosition(wethPosition, address(erc20Adaptor), abi.encode(WETH));
        registry.trustPosition(wstethPosition, address(erc20Adaptor), abi.encode(WSTETH));
        registry.trustPosition(morphoAWethPosition, address(p2pATokenAdaptor), abi.encode(WETH));
        registry.trustPosition(morphoAWstEthPosition, address(collateralATokenAdaptor), abi.encode(WSTETH));
        registry.trustPosition(morphoDebtWethPosition, address(debtTokenAdaptor), abi.encode(WETH));

        string memory fundName = "Morpho Aave V3 Fund V0.0";
        uint256 initialDeposit = 1e12;

        fund = _createFund(fundName, WETH, morphoAWethPosition, abi.encode(4), initialDeposit);

        fund.addAdaptorToCatalogue(address(p2pATokenAdaptor));
        fund.addAdaptorToCatalogue(address(collateralATokenAdaptor));
        fund.addAdaptorToCatalogue(address(debtTokenAdaptor));
        fund.addAdaptorToCatalogue(address(swapWithUniswapAdaptor));

        fund.addPositionToCatalogue(wethPosition);
        fund.addPositionToCatalogue(wstethPosition);
        fund.addPositionToCatalogue(morphoAWethPosition);
        fund.addPositionToCatalogue(morphoAWstEthPosition);
        fund.addPositionToCatalogue(morphoDebtWethPosition);

        WETH.safeApprove(address(fund), type(uint256).max);

        fund.setRebalanceDeviation(0.005e18);

        // Force whale out of their WSTETH position.
        vm.prank(aWstEthWhale);
        pool.withdraw(address(WSTETH), 1_000e18, aWstEthWhale);
    }

    function testDeposit(uint256 assets) external {
        assets = bound(assets, 0.01e18, 10_000e18);
        deal(address(WETH), address(this), assets);
        fund.deposit(assets, address(this));
    }

    function testWithdraw(uint256 assets) external {
        assets = bound(assets, 0.01e18, 10_000e18);
        deal(address(WETH), address(this), assets);
        fund.deposit(assets, address(this));

        // Pass a little bit of time so that we can withdraw the full amount.
        // Morpho deposit rounds down.
        vm.warp(block.timestamp + 300);

        fund.withdraw(assets, address(this), address(this));
    }

    function testTotalAssets(uint256 assets) external {
        uint256 initialAssets = fund.totalAssets();
        assets = bound(assets, 0.01e18, 10_000e18);
        deal(address(WETH), address(this), assets);
        fund.deposit(assets, address(this));
        assertApproxEqAbs(fund.totalAssets(), assets + initialAssets, 2, "Total assets should equal assets deposited.");
    }

    function testTakingOutLoans(uint256 assets) external {
        uint256 initialAssets = fund.totalAssets();
        _setupFundForBorrowing(fund);

        assets = bound(assets, 0.01e18, 1_000e18);
        deal(address(WETH), address(this), assets);
        fund.deposit(assets, address(this));

        // Rebalance Fund to take on debt.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](3);
        // Swap WETH for WSTETH.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv3(WETH, WSTETH, 500, assets);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }
        // Supply WSTETH as collateral on Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToLendCollateralOnMorphoAaveV3(WSTETH, type(uint256).max);
            data[1] = Fund.AdaptorCall({ adaptor: address(collateralATokenAdaptor), callData: adaptorCalls });
        }
        // Borrow WETH from Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            uint256 wethToBorrow = assets / 4;
            adaptorCalls[0] = _createBytesDataToBorrowFromMorphoAaveV3(WETH, wethToBorrow, 4);
            data[2] = Fund.AdaptorCall({ adaptor: address(debtTokenAdaptor), callData: adaptorCalls });
        }

        // Perform callOnAdaptor.
        fund.callOnAdaptor(data);

        uint256 wethDebt = morpho.borrowBalance(address(WETH), address(fund));

        assertApproxEqAbs(wethDebt, assets / 4, 1, "WETH debt should equal assets / 4.");
        assertApproxEqRel(fund.totalAssets(), assets + initialAssets, 0.003e18, "Total assets should equal assets.");
    }

    function testRepayingLoans(uint256 assets) external {
        uint256 initialAssets = fund.totalAssets();
        _setupFundForBorrowing(fund);

        assets = bound(assets, 0.01e18, 1_000e18);
        deal(address(WETH), address(this), assets);
        fund.deposit(assets, address(this));

        // Rebalance Fund to take on debt.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](3);
        // Swap WETH for WSTETH.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv3(WETH, WSTETH, 500, assets);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }
        // Supply WSTETH as collateral on Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToLendCollateralOnMorphoAaveV3(WSTETH, type(uint256).max);
            data[1] = Fund.AdaptorCall({ adaptor: address(collateralATokenAdaptor), callData: adaptorCalls });
        }
        // Borrow WETH from Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            uint256 wethToBorrow = assets / 4;
            adaptorCalls[0] = _createBytesDataToBorrowFromMorphoAaveV3(WETH, wethToBorrow, 4);
            data[2] = Fund.AdaptorCall({ adaptor: address(debtTokenAdaptor), callData: adaptorCalls });
        }

        // Perform callOnAdaptor.
        fund.callOnAdaptor(data);

        uint256 wethDebt = morpho.borrowBalance(address(WETH), address(fund));

        assertApproxEqAbs(wethDebt, assets / 4, 1, "WETH debt should equal assets / 4.");
        assertApproxEqRel(fund.totalAssets(), assets + initialAssets, 0.003e18, "Total assets should equal assets.");

        // Now repay half the debt.
        data = new Fund.AdaptorCall[](1);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            uint256 wethToRepay = wethDebt / 2;
            adaptorCalls[0] = _createBytesDataToRepayToMorphoAaveV3(WETH, wethToRepay);
            data[0] = Fund.AdaptorCall({ adaptor: address(debtTokenAdaptor), callData: adaptorCalls });
        }

        // Perform callOnAdaptor.
        fund.callOnAdaptor(data);

        wethDebt = morpho.borrowBalance(address(WETH), address(fund));

        assertApproxEqAbs(wethDebt, assets / 8, 1, "WETH debt should equal assets / 8.");
        assertApproxEqRel(fund.totalAssets(), assets + initialAssets, 0.003e18, "Total assets should equal assets.");
    }

    function testWithdrawalLogic(uint256 assets) external {
        uint256 initialAssets = fund.totalAssets();
        _setupFundForBorrowing(fund);

        assets = bound(assets, 0.01e18, 400e18);
        deal(address(WETH), address(this), assets);
        fund.deposit(assets, address(this));

        // Rebalance Fund to take on debt.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](4);
        // Swap WETH for WSTETH.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv3(WETH, WSTETH, 500, assets);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }
        // Supply WSTETH as collateral on Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToLendCollateralOnMorphoAaveV3(WSTETH, type(uint256).max);
            data[1] = Fund.AdaptorCall({ adaptor: address(collateralATokenAdaptor), callData: adaptorCalls });
        }
        // Borrow WETH from Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            uint256 wethToBorrow = assets / 4;
            adaptorCalls[0] = _createBytesDataToBorrowFromMorphoAaveV3(WETH, wethToBorrow, 4);
            data[2] = Fund.AdaptorCall({ adaptor: address(debtTokenAdaptor), callData: adaptorCalls });
        }
        // Supply WETH as collateral p2p on Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToLendP2POnMorpoAaveV3(WETH, type(uint256).max, 4);
            data[3] = Fund.AdaptorCall({ adaptor: address(p2pATokenAdaptor), callData: adaptorCalls });
        }

        // Perform callOnAdaptor.
        fund.callOnAdaptor(data);

        // The only assets withdrawable from the fund should be the WETH lent P2P.
        uint256 wethP2PLend = morpho.supplyBalance(address(WETH), address(fund));

        uint256 assetsWithdrawable = fund.totalAssetsWithdrawable();
        assertEq(wethP2PLend, assetsWithdrawable, "Only assets withdrawable should be in P2P Lending.");

        // User withdraws as much as possible.
        uint256 maxAssets = fund.maxWithdraw(address(this));
        fund.withdraw(maxAssets, address(this), address(this));
        assertEq(WETH.balanceOf(address(this)), wethP2PLend, "Withdraw should have sent P2P assets to user.");
        assertEq(morpho.supplyBalance(address(WETH), address(fund)), 0, "There should be no more WETH supplied.");

        assertEq(fund.totalAssetsWithdrawable(), 0, "There should be no more assets withdrawable.");

        // Fund must repay ALL of its WETH debt before WSTETH collateral can be withdrawn.
        uint256 wethDebt = morpho.borrowBalance(address(WETH), address(fund));

        // Give the fund enough WETH to pay off the debt.
        deal(address(WETH), address(fund), wethDebt);

        data = new Fund.AdaptorCall[](1);
        // Repay the debt.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToRepayToMorphoAaveV3(WETH, type(uint256).max);
            data[0] = Fund.AdaptorCall({ adaptor: address(debtTokenAdaptor), callData: adaptorCalls });
        }

        // Perform callOnAdaptor.
        fund.callOnAdaptor(data);

        // Note 0.1% deviation happens because of swap fees and slippage.
        assertApproxEqRel(
            fund.totalAssetsWithdrawable(),
            assets + initialAssets,
            0.003e18,
            "Withdrawable assets should equal assets in."
        );

        assertEq(morpho.borrowBalance(address(WETH), address(fund)), 0, "Borrow balance should be zero.");
        assertEq(morpho.userBorrows(address(fund)).length, 0, "User borrows array should be empty.");

        maxAssets = fund.maxWithdraw(address(this));
        fund.withdraw(maxAssets, address(this), address(this));
        uint256 expectedOut = priceRouter.getValue(WETH, maxAssets, WSTETH);
        assertApproxEqAbs(
            WSTETH.balanceOf(address(this)),
            expectedOut,
            1,
            "Withdraw should have sent collateral assets to user."
        );
    }

    function testTakingOutLoansInUntrackedPosition(uint256 assets) external {
        _setupFundForBorrowing(fund);
        fund.removePosition(0, true);

        assets = bound(assets, 0.01e18, 1_000e18);
        deal(address(WETH), address(this), assets);
        fund.deposit(assets, address(this));

        // Rebalance Fund to take on debt.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](3);
        // Swap WETH for WSTETH.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv3(WETH, WSTETH, 500, assets);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }
        // Supply WSTETH as collateral on Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToLendCollateralOnMorphoAaveV3(WSTETH, type(uint256).max);
            data[1] = Fund.AdaptorCall({ adaptor: address(collateralATokenAdaptor), callData: adaptorCalls });
        }
        // Borrow WETH from Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            uint256 wethToBorrow = assets / 4;
            adaptorCalls[0] = _createBytesDataToBorrowFromMorphoAaveV3(WETH, wethToBorrow, 4);
            data[2] = Fund.AdaptorCall({ adaptor: address(debtTokenAdaptor), callData: adaptorCalls });
        }

        // callOnAdaptor reverts because WETH debt is not tracked.
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    MorphoAaveV3DebtTokenAdaptor.MorphoAaveV3DebtTokenAdaptor__DebtPositionsMustBeTracked.selector,
                    address(WETH)
                )
            )
        );
        fund.callOnAdaptor(data);
    }

    function testRepayingDebtThatIsNotOwed(uint256 assets) external {
        _setupFundForBorrowing(fund);

        assets = bound(assets, 0.01e18, 1_000e18);
        deal(address(WETH), address(this), assets);
        fund.deposit(assets, address(this));

        // Rebalance Fund to take on debt.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            uint256 wethToRepay = 1;
            adaptorCalls[0] = _createBytesDataToRepayToMorphoAaveV3(WETH, wethToRepay);
            data[0] = Fund.AdaptorCall({ adaptor: address(debtTokenAdaptor), callData: adaptorCalls });
        }

        // callOnAdaptor fails because the fund has no WETH debt.
        vm.expectRevert();
        fund.callOnAdaptor(data);
    }

    function testBlockExternalReceiver(uint256 assets) external {
        _setupFundForBorrowing(fund);

        assets = bound(assets, 0.01e18, 1_000e18);
        deal(address(WETH), address(this), assets);
        fund.deposit(assets, address(this));

        // Rebalance into both collateral and p2p.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](3);
        // Swap WETH for WSTETH.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv3(WETH, WSTETH, 500, assets / 2);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }
        // Supply WSTETH as collateral on Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToLendCollateralOnMorphoAaveV3(WSTETH, type(uint256).max);
            data[1] = Fund.AdaptorCall({ adaptor: address(collateralATokenAdaptor), callData: adaptorCalls });
        }
        // Supply WETH as collateral p2p on Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToLendP2POnMorpoAaveV3(WETH, type(uint256).max, 4);
            data[2] = Fund.AdaptorCall({ adaptor: address(p2pATokenAdaptor), callData: adaptorCalls });
        }

        fund.callOnAdaptor(data);

        // Strategist tries calling withdraw on collateral.
        data = new Fund.AdaptorCall[](1);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = abi.encodeWithSelector(
                MorphoAaveV3ATokenCollateralAdaptor.withdraw.selector,
                1,
                strategist,
                abi.encode(WSTETH),
                abi.encode(0)
            );
            data[0] = Fund.AdaptorCall({ adaptor: address(collateralATokenAdaptor), callData: adaptorCalls });
        }
        vm.expectRevert(bytes(abi.encodeWithSelector(BaseAdaptor.BaseAdaptor__ExternalReceiverBlocked.selector)));
        fund.callOnAdaptor(data);

        // Strategist tries calling withdraw on p2p.
        data = new Fund.AdaptorCall[](1);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = abi.encodeWithSelector(
                MorphoAaveV3ATokenP2PAdaptor.withdraw.selector,
                1,
                strategist,
                abi.encode(WETH),
                abi.encode(0)
            );
            data[0] = Fund.AdaptorCall({ adaptor: address(p2pATokenAdaptor), callData: adaptorCalls });
        }
        vm.expectRevert(bytes(abi.encodeWithSelector(BaseAdaptor.BaseAdaptor__ExternalReceiverBlocked.selector)));
        fund.callOnAdaptor(data);
    }

    function testHealthFactor(uint256 assets) external {
        _setupFundForBorrowing(fund);

        assets = bound(assets, 10e18, 1_000e18);
        deal(address(WETH), address(this), assets);
        fund.deposit(assets, address(this));

        // Simulate a swap by minting fund the correct amount of WSTETH.
        deal(address(WETH), address(fund), 0);
        uint256 wstEthToMint = priceRouter.getValue(WETH, assets, WSTETH);
        deal(address(WSTETH), address(fund), wstEthToMint);

        uint256 targetHealthFactor = 1.06e18;
        uint256 ltv = 0.93e18;
        uint256 wethToBorrow = assets.mulDivDown(ltv, targetHealthFactor);

        // Rebalance Fund to take on debt.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](2);
        // Supply WSTETH as collateral on Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToLendCollateralOnMorphoAaveV3(WSTETH, wstEthToMint);
            data[0] = Fund.AdaptorCall({ adaptor: address(collateralATokenAdaptor), callData: adaptorCalls });
        }
        // Borrow WETH from Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToBorrowFromMorphoAaveV3(WETH, wethToBorrow, 4);
            data[1] = Fund.AdaptorCall({ adaptor: address(debtTokenAdaptor), callData: adaptorCalls });
        }

        // Perform callOnAdaptor.
        fund.callOnAdaptor(data);

        IMorphoV3.LiquidityData memory liquidityData = morpho.liquidityData(address(fund));
        uint256 morphoHealthFactor = uint256(1e18).mulDivDown(liquidityData.maxDebt, liquidityData.debt);

        assertApproxEqRel(
            morphoHealthFactor,
            targetHealthFactor,
            0.0025e18,
            "Morpho health factor should equal target."
        );

        // Make sure that morpho Health factor is the same as ours.
        assertApproxEqAbs(
            _getUserHealthFactor(address(fund)),
            morphoHealthFactor,
            1,
            "Our health factor should equal morphos."
        );
    }

    function testHealthFactorChecks() external {
        // Need to borrow, and lower the health factor below 1.05, then need to withdraw to lower health factor below 1.05.
        _setupFundForBorrowing(fund);

        uint256 assets = 100e18;
        deal(address(WETH), address(this), assets);
        fund.deposit(assets, address(this));

        // Simulate a swap by minting fund the correct amount of WSTETH.
        deal(address(WETH), address(fund), 0);
        uint256 wstEthToMint = priceRouter.getValue(WETH, assets, WSTETH);
        deal(address(WSTETH), address(fund), wstEthToMint);

        uint256 targetHealthFactor = 1.052e18;
        uint256 ltv = 0.93e18;
        uint256 wethToBorrow = assets.mulDivDown(ltv, targetHealthFactor);
        uint256 wethToBorrowToTriggerHealthFactorRevert = assets.mulDivDown(ltv, 1.04e18) - wethToBorrow;

        // Rebalance Fund to take on debt.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](2);
        // Supply WSTETH as collateral on Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToLendCollateralOnMorphoAaveV3(WSTETH, wstEthToMint);
            data[0] = Fund.AdaptorCall({ adaptor: address(collateralATokenAdaptor), callData: adaptorCalls });
        }
        // Borrow WETH from Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToBorrowFromMorphoAaveV3(WETH, wethToBorrow, 4);
            data[1] = Fund.AdaptorCall({ adaptor: address(debtTokenAdaptor), callData: adaptorCalls });
        }

        // Perform callOnAdaptor.
        fund.callOnAdaptor(data);

        // Strategist tries to borrow more.
        data = new Fund.AdaptorCall[](1);
        // Borrow WETH from Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToBorrowFromMorphoAaveV3(
                WETH,
                wethToBorrowToTriggerHealthFactorRevert,
                4
            );
            data[0] = Fund.AdaptorCall({ adaptor: address(debtTokenAdaptor), callData: adaptorCalls });
        }

        // callOnAdaptor reverts because the health factor is too low.
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    MorphoAaveV3DebtTokenAdaptor.MorphoAaveV3DebtTokenAdaptor__HealthFactorTooLow.selector
                )
            )
        );
        fund.callOnAdaptor(data);

        // If strategist tries to withdraw some collateral, the withdraw also reverts.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            uint256 amountToWithdraw = 1e18;
            adaptorCalls[0] = _createBytesDataToWithdrawCollateralFromMorphoAaveV3(WSTETH, amountToWithdraw);
            data[0] = Fund.AdaptorCall({ adaptor: address(collateralATokenAdaptor), callData: adaptorCalls });
        }

        // callOnAdaptor should revert because withdraw lowers Health Factor too far.
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    MorphoAaveV3ATokenCollateralAdaptor.MorphoAaveV3ATokenCollateralAdaptor__HealthFactorTooLow.selector
                )
            )
        );
        fund.callOnAdaptor(data);
    }

    // ========================================== INTEGRATION TEST ==========================================

    function testIntegrationRealYieldEth(uint256 assets) external {
        // Setup fund so that aSTETH is illiquid.
        // Then have strategist loop into STETH.
        // -Deposit STETH as collateral, and borrow WETH, repeat.
        fund.addPosition(0, wethPosition, abi.encode(0), false);
        fund.addPosition(0, wstethPosition, abi.encode(0), false);
        fund.addPosition(0, morphoAWstEthPosition, abi.encode(false), false);
        fund.addPosition(0, morphoDebtWethPosition, abi.encode(0), true);

        // Change holding position to vanilla WETH.
        fund.setHoldingPosition(wethPosition);

        // Remove unused aWETH Morpho position from the fund.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToWithdrawP2PFromMorphoAaveV3(WETH, type(uint256).max, 4);
            data[0] = Fund.AdaptorCall({ adaptor: address(p2pATokenAdaptor), callData: adaptorCalls });
        }
        fund.callOnAdaptor(data);
        fund.removePosition(3, false);

        // assets = bound(assets, 1e18, 400e18);
        assets = 400e18;
        address user = vm.addr(7654);
        deal(address(WETH), user, assets);
        vm.startPrank(user);
        WETH.approve(address(fund), assets);
        fund.deposit(assets, user);
        vm.stopPrank();

        // Rebalance Fund to leverage into STETH.
        data = new Fund.AdaptorCall[](5);
        // Swap WETH for WSTETH.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv3(WETH, WSTETH, 500, assets);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }
        // Supply WSTETH as collateral on Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToLendCollateralOnMorphoAaveV3(WSTETH, type(uint256).max);
            data[1] = Fund.AdaptorCall({ adaptor: address(collateralATokenAdaptor), callData: adaptorCalls });
        }
        // Borrow WETH from Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            uint256 wethToBorrow = assets / 3;
            adaptorCalls[0] = _createBytesDataToBorrowFromMorphoAaveV3(WETH, wethToBorrow, 4);
            data[2] = Fund.AdaptorCall({ adaptor: address(debtTokenAdaptor), callData: adaptorCalls });
        }
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv3(WETH, WSTETH, 500, type(uint256).max);
            data[3] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }
        // Supply WSTETH as collateral on Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToLendCollateralOnMorphoAaveV3(WSTETH, type(uint256).max);
            data[4] = Fund.AdaptorCall({ adaptor: address(collateralATokenAdaptor), callData: adaptorCalls });
        }

        // Perform callOnAdaptor.
        fund.callOnAdaptor(data);
    }

    // ========================================= HELPER FUNCTIONS =========================================
    uint256 internal constant WAD = 1e18;

    function wadDiv(uint256 a, uint256 b) internal pure returns (uint256 c) {
        // to avoid overflow, a <= (type(uint256).max - halfB) / WAD
        assembly {
            if or(iszero(b), iszero(iszero(gt(a, div(sub(not(0), div(b, 2)), WAD))))) {
                revert(0, 0)
            }

            c := div(add(mul(a, WAD), div(b, 2)), b)
        }
    }

    function _getUserHealthFactor(address user) internal view returns (uint256) {
        IMorphoV3.LiquidityData memory liquidityData = morpho.liquidityData(user);

        return liquidityData.debt > 0 ? wadDiv(liquidityData.maxDebt, liquidityData.debt) : type(uint256).max;
    }

    function _setupFundForBorrowing(Fund target) internal {
        // Add required positions.
        target.addPosition(0, wethPosition, abi.encode(0), false);
        target.addPosition(1, wstethPosition, abi.encode(0), false);
        target.addPosition(2, morphoAWstEthPosition, abi.encode(0), false);
        target.addPosition(0, morphoDebtWethPosition, abi.encode(0), true);

        // Change holding position to vanilla WETH.
        target.setHoldingPosition(wethPosition);
    }
}
