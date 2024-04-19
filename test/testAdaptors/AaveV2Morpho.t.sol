// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { MorphoAaveV2ATokenAdaptor, IMorphoV2 } from "src/modules/adaptors/Morpho/MorphoAaveV2ATokenAdaptor.sol";
import { MorphoAaveV2DebtTokenAdaptor } from "src/modules/adaptors/Morpho/MorphoAaveV2DebtTokenAdaptor.sol";
import { IMorphoLensV2 } from "src/interfaces/external/Morpho/IMorphoLensV2.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";

import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";

contract FundAaveV2MorphoTest is MainnetStarterTest, AdaptorHelperFunctions {
    using SafeTransferLib for ERC20;
    using Math for uint256;

    MorphoAaveV2ATokenAdaptor private aTokenAdaptor;
    MorphoAaveV2DebtTokenAdaptor private debtTokenAdaptor;
    Fund private fund;

    IMorphoV2 private morpho = IMorphoV2(0x777777c9898D384F785Ee44Acfe945efDFf5f3E0);
    address private morphoLens = 0x507fA343d0A90786d86C7cd885f5C49263A91FF4;
    address private rewardHandler = 0x3B14E5C73e0A56D607A8688098326fD4b4292135;

    address private aWstEthWhale = 0xAF06acFD1BD492B913d5807d562e4FC3A6343C4E;

    uint32 private wethPosition = 1;
    uint32 private usdcPosition = 2;
    uint32 private stethPosition = 3;
    uint32 private morphoAWethPosition = 1_000_001;
    uint32 private morphoAUsdcPosition = 1_000_002;
    uint32 private morphoAStEthPosition = 1_000_003;
    uint32 private morphoDebtWethPosition = 1_000_004;

    function setUp() external {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 16869780;
        _startFork(rpcKey, blockNumber);

        // Run Starter setUp code.
        _setUp();

        aTokenAdaptor = new MorphoAaveV2ATokenAdaptor(address(morpho), morphoLens, 1.05e18, rewardHandler);
        debtTokenAdaptor = new MorphoAaveV2DebtTokenAdaptor(address(morpho), morphoLens, 1.05e18);

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

        // Setup Fund:

        // Add adaptors and positions to the registry.
        registry.trustAdaptor(address(aTokenAdaptor));
        registry.trustAdaptor(address(debtTokenAdaptor));

        registry.trustPosition(wethPosition, address(erc20Adaptor), abi.encode(WETH));
        registry.trustPosition(usdcPosition, address(erc20Adaptor), abi.encode(USDC));
        registry.trustPosition(stethPosition, address(erc20Adaptor), abi.encode(STETH));
        registry.trustPosition(morphoAWethPosition, address(aTokenAdaptor), abi.encode(aV2WETH));
        registry.trustPosition(morphoAUsdcPosition, address(aTokenAdaptor), abi.encode(aV2USDC));
        registry.trustPosition(morphoAStEthPosition, address(aTokenAdaptor), abi.encode(aV2STETH));
        registry.trustPosition(morphoDebtWethPosition, address(debtTokenAdaptor), abi.encode(aV2WETH));

        string memory fundName = "Morpho Aave V2 Fund V0.0";
        uint256 initialDeposit = 1e12;

        fund = _createFund(fundName, WETH, morphoAWethPosition, abi.encode(true), initialDeposit);

        fund.addAdaptorToCatalogue(address(aTokenAdaptor));
        fund.addAdaptorToCatalogue(address(debtTokenAdaptor));
        fund.addAdaptorToCatalogue(address(swapWithUniswapAdaptor));

        fund.addPositionToCatalogue(wethPosition);
        fund.addPositionToCatalogue(stethPosition);
        fund.addPositionToCatalogue(morphoAWethPosition);
        fund.addPositionToCatalogue(morphoAStEthPosition);
        fund.addPositionToCatalogue(morphoDebtWethPosition);

        WETH.safeApprove(address(fund), type(uint256).max);

        // UniV2 WETH/STETH slippage is turbo bad, so set a large rebalance deviation.
        fund.setRebalanceDeviation(0.1e18);
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

        // Only withdraw assets - 1 because p2pSupplyIndex is not updated, so it is possible
        // for totalAssets to equal assets - 1.
        fund.withdraw(assets - 1, address(this), address(this));
    }

    function testTotalAssets(uint256 assets) external {
        uint256 initialAssets = fund.totalAssets();
        assets = bound(assets, 0.01e18, 10_000e18);
        deal(address(WETH), address(this), assets);
        fund.deposit(assets, address(this));
        assertApproxEqAbs(
            fund.totalAssets(),
            (assets + initialAssets),
            1,
            "Total assets should equal assets deposited."
        );
    }

    function testTakingOutLoans(uint256 assets) external {
        _setupFundForBorrowing(fund);

        assets = bound(assets, 0.01e18, 100e18);
        deal(address(WETH), address(this), assets);
        fund.deposit(assets, address(this));

        // Rebalance Fund to take on debt.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](3);
        // Swap WETH for WSTETH.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv2(WETH, STETH, assets);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }
        // Supply WSTETH as collateral on Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToLendToMorphoAaveV2(address(aV2STETH), type(uint256).max);
            data[1] = Fund.AdaptorCall({ adaptor: address(aTokenAdaptor), callData: adaptorCalls });
        }
        // Borrow WETH from Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            uint256 wethToBorrow = assets / 3;
            adaptorCalls[0] = _createBytesDataToBorrowFromMorphoAaveV2(address(aV2WETH), wethToBorrow);
            data[2] = Fund.AdaptorCall({ adaptor: address(debtTokenAdaptor), callData: adaptorCalls });
        }

        // Perform callOnAdaptor.
        fund.callOnAdaptor(data);

        uint256 balanceInUnderlying = getMorphoDebt(address(aV2WETH), address(fund));

        assertApproxEqAbs(balanceInUnderlying, assets / 3, 1, "WETH debt should equal assets / 3.");
        // Below assert uses such a large range bc of uniV2 slippage.
        assertApproxEqRel(fund.totalAssets(), assets, 0.90e18, "Total assets should equal assets.");
    }

    function testRepayingLoans(uint256 assets) external {
        _setupFundForBorrowing(fund);

        assets = bound(assets, 0.01e18, 100e18);
        deal(address(WETH), address(this), assets);
        fund.deposit(assets, address(this));

        // Rebalance Fund to take on debt.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](3);
        // Swap WETH for WSTETH.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv2(WETH, STETH, assets);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }
        // Supply WSTETH as collateral on Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToLendToMorphoAaveV2(address(aV2STETH), type(uint256).max);
            data[1] = Fund.AdaptorCall({ adaptor: address(aTokenAdaptor), callData: adaptorCalls });
        }
        // Borrow WETH from Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            uint256 wethToBorrow = assets / 4;
            adaptorCalls[0] = _createBytesDataToBorrowFromMorphoAaveV2(address(aV2WETH), wethToBorrow);
            data[2] = Fund.AdaptorCall({ adaptor: address(debtTokenAdaptor), callData: adaptorCalls });
        }

        // Perform callOnAdaptor.
        fund.callOnAdaptor(data);

        uint256 wethDebt = getMorphoDebt(address(aV2WETH), address(fund));

        assertApproxEqAbs(wethDebt, assets / 4, 1, "WETH debt should equal assets / 4.");

        // Now repay half the debt.
        data = new Fund.AdaptorCall[](1);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            uint256 wethToRepay = wethDebt / 2;
            adaptorCalls[0] = _createBytesDataToRepayToMorphoAaveV2(address(aV2WETH), wethToRepay);
            data[0] = Fund.AdaptorCall({ adaptor: address(debtTokenAdaptor), callData: adaptorCalls });
        }

        // Perform callOnAdaptor.
        fund.callOnAdaptor(data);

        wethDebt = getMorphoDebt(address(aV2WETH), address(fund));

        assertApproxEqAbs(wethDebt, assets / 8, 1, "WETH debt should equal assets / 8.");
    }

    function testWithdrawalLogic(uint256 assetsToBorrow) external {
        uint256 initialAssets = fund.totalAssets();
        assetsToBorrow = bound(assetsToBorrow, 1, 1_000e18);

        uint256 assetsWithdrawable;
        // Add vanilla WETH to the fund.
        fund.addPosition(0, wethPosition, abi.encode(true), false);
        // Add debt position to fund.
        fund.addPosition(0, morphoDebtWethPosition, abi.encode(0), true);

        uint256 assetsToLend = 2 * assetsToBorrow;

        deal(address(WETH), address(this), assetsToLend);
        fund.deposit(assetsToLend, address(this));

        assertTrue(!aTokenAdaptor.isBorrowingAny(address(fund)), "Fund should not be borrowing.");

        // Withdrawable assets should equal assetsToLend.
        assetsWithdrawable = fund.totalAssetsWithdrawable();

        assertApproxEqAbs(assetsWithdrawable - initialAssets, assetsToLend, 1, "Fund should be fully liquid.");

        // Rebalance Fund to take on debt.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        // Borrow WETH from Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToBorrowFromMorphoAaveV2(address(aV2WETH), assetsToBorrow);
            data[0] = Fund.AdaptorCall({ adaptor: address(debtTokenAdaptor), callData: adaptorCalls });
        }

        // Perform callOnAdaptor.
        fund.callOnAdaptor(data);

        deal(address(WETH), address(fund), assetsToBorrow + 1);

        assertTrue(aTokenAdaptor.isBorrowingAny(address(fund)), "Fund should be borrowing.");

        // Withdrawable assets should equal assetsToBorrow.
        assetsWithdrawable = fund.totalAssetsWithdrawable();

        assertApproxEqAbs(assetsWithdrawable, assetsToBorrow, 1, "Fund aToken position should be illiquid.");

        // Rebalance Fund to repay debt in full.
        data = new Fund.AdaptorCall[](1);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToRepayToMorphoAaveV2(address(aV2WETH), type(uint256).max);
            data[0] = Fund.AdaptorCall({ adaptor: address(debtTokenAdaptor), callData: adaptorCalls });
        }

        // Perform callOnAdaptor.
        fund.callOnAdaptor(data);

        assertTrue(!aTokenAdaptor.isBorrowingAny(address(fund)), "Fund should not be borrowing.");

        // Withdrawable assets should equal assetsToLend.
        assetsWithdrawable = fund.totalAssetsWithdrawable();

        assertApproxEqAbs(assetsWithdrawable - initialAssets, assetsToLend, 10, "Fund should be fully liquid.");
    }

    function testTakingOutLoansInUntrackedPosition(uint256 assets) external {
        _setupFundForBorrowing(fund);
        fund.removePosition(0, fund.debtPositions(0), true);

        assets = bound(assets, 0.01e18, 100e18);
        deal(address(WETH), address(this), assets);
        fund.deposit(assets, address(this));

        // Rebalance Fund to take on debt.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](3);
        // Swap WETH for STETH.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv2(WETH, STETH, assets);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }
        // Supply STETH as collateral on Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToLendToMorphoAaveV2(address(aV2STETH), type(uint256).max);
            data[1] = Fund.AdaptorCall({ adaptor: address(aTokenAdaptor), callData: adaptorCalls });
        }
        // Borrow WETH from Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            uint256 wethToBorrow = assets / 4;
            adaptorCalls[0] = _createBytesDataToBorrowFromMorphoAaveV2(address(aV2WETH), wethToBorrow);
            data[2] = Fund.AdaptorCall({ adaptor: address(debtTokenAdaptor), callData: adaptorCalls });
        }

        // callOnAdaptor reverts because WETH debt is not tracked.
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    MorphoAaveV2DebtTokenAdaptor.MorphoAaveV2DebtTokenAdaptor__DebtPositionsMustBeTracked.selector,
                    address(aV2WETH)
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
            adaptorCalls[0] = _createBytesDataToRepayToMorphoAaveV2(address(aV2WETH), wethToRepay);
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
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        // Supply WETH as collateral on Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToLendToMorphoAaveV2(address(aV2WETH), type(uint256).max);
            data[0] = Fund.AdaptorCall({ adaptor: address(aTokenAdaptor), callData: adaptorCalls });
        }
        fund.callOnAdaptor(data);

        // Strategist tries calling withdraw on collateral.
        data = new Fund.AdaptorCall[](1);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = abi.encodeWithSelector(
                MorphoAaveV2ATokenAdaptor.withdraw.selector,
                1,
                strategist,
                abi.encode(aV2WETH),
                abi.encode(0)
            );
            data[0] = Fund.AdaptorCall({ adaptor: address(aTokenAdaptor), callData: adaptorCalls });
        }
        vm.expectRevert(bytes(abi.encodeWithSelector(BaseAdaptor.BaseAdaptor__ExternalReceiverBlocked.selector)));
        fund.callOnAdaptor(data);
    }

    // ========================================== INTEGRATION TEST ==========================================

    function testIntegrationRealYieldUsd(uint256 assets) external {
        // Create a new fund that runs the following strategy.
        // Allows for user direct deposit to morpho.
        // Allows for user direct withdraw form morpho.
        // Allows for strategist deposit to morpho.
        // Allows for strategist withdraw form morpho.
        string memory fundName = "MORPHO P2P Fund";
        uint256 initialDeposit = 1e6;

        fund = _createFund(fundName, USDC, morphoAUsdcPosition, abi.encode(0), initialDeposit);

        fund.addAdaptorToCatalogue(address(aTokenAdaptor));
        fund.addAdaptorToCatalogue(address(swapWithUniswapAdaptor));
        fund.addPositionToCatalogue(usdcPosition);
        fund.addPosition(0, usdcPosition, abi.encode(true), false);

        // assets = 100_000e6;
        assets = bound(assets, 1e6, 1_000_000e6);

        address user = vm.addr(7654);
        deal(address(USDC), user, assets);
        vm.startPrank(user);
        USDC.approve(address(fund), assets);
        fund.deposit(assets, user);
        vm.stopPrank();

        // Check that users funds where deposited into morpho.
        uint256 assetsInMorpho = getMorphoBalance(address(aV2USDC), address(fund));
        assertApproxEqAbs(assetsInMorpho, assets + initialDeposit, 1, "Assets should have been deposited into Morpho.");

        // Now make sure users can withdraw from morpho.
        deal(address(USDC), user, 0);
        assetsInMorpho = fund.maxWithdraw(user);
        vm.prank(user);
        fund.withdraw(assetsInMorpho, user, user);

        assertEq(USDC.balanceOf(user), assetsInMorpho, "User should have received assets in morpho.");

        assetsInMorpho = getMorphoBalance(address(aV2USDC), address(fund));
        assertApproxEqAbs(assetsInMorpho, initialDeposit, 1, "Assets should have been withdrawn from morpho.");

        // Strategist changes holding position to be vanilla USDC, so they can try depositing into morpho.
        fund.setHoldingPosition(usdcPosition);

        // User deposits again.
        deal(address(USDC), user, assets);
        vm.startPrank(user);
        USDC.approve(address(fund), assets);
        fund.deposit(assets, user);
        vm.stopPrank();

        assertApproxEqAbs(USDC.balanceOf(address(fund)), assets, 1, "Fund should be holding assets in USDC.");

        // Strategist rebalances assets into morpho.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        // Supply USDC as collateral on Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToLendToMorphoAaveV2(address(aV2USDC), type(uint256).max);
            data[0] = Fund.AdaptorCall({ adaptor: address(aTokenAdaptor), callData: adaptorCalls });
        }

        fund.callOnAdaptor(data);

        // Strategist rebalances assets out of morpho.
        data = new Fund.AdaptorCall[](1);
        // Supply USDC as collateral on Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToWithdrawFromMorphoAaveV2(address(aV2USDC), type(uint256).max);
            data[0] = Fund.AdaptorCall({ adaptor: address(aTokenAdaptor), callData: adaptorCalls });
        }

        fund.callOnAdaptor(data);

        assertApproxEqAbs(USDC.balanceOf(address(fund)), assets + initialDeposit, 1, "Fund should be holding USDC.");
    }

    function testIntegrationRealYieldEth(uint256 assets) external {
        // Setup fund so that aSTETH is illiquid.
        // Then have strategist loop into STETH.
        // -Deposit STETH as collateral, and borrow WETH, repeat.
        fund.addPosition(0, wethPosition, abi.encode(true), false);
        fund.addPosition(0, stethPosition, abi.encode(true), false);
        fund.addPosition(0, morphoAStEthPosition, abi.encode(false), false);
        fund.addPosition(0, morphoDebtWethPosition, abi.encode(0), true);

        // Change holding position to vanilla WETH.
        fund.setHoldingPosition(wethPosition);

        // Strategist rebalances assets out of morpho.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        // Supply USDC as collateral on Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToWithdrawFromMorphoAaveV2(address(aV2WETH), type(uint256).max);
            data[0] = Fund.AdaptorCall({ adaptor: address(aTokenAdaptor), callData: adaptorCalls });
        }

        fund.callOnAdaptor(data);

        // Remove unused aWETH Morpho position from the fund.
        fund.removePosition(3, fund.creditPositions(3), false);

        assets = 10e18;
        // assets = bound(assets, 1e18, 100e18);

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
            adaptorCalls[0] = _createBytesDataForSwapWithUniv2(WETH, STETH, assets);
            data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }
        // Supply WSTETH as collateral on Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToLendToMorphoAaveV2(address(aV2STETH), type(uint256).max);
            data[1] = Fund.AdaptorCall({ adaptor: address(aTokenAdaptor), callData: adaptorCalls });
        }
        // Borrow WETH from Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            uint256 wethToBorrow = assets / 3;
            adaptorCalls[0] = _createBytesDataToBorrowFromMorphoAaveV2(address(aV2WETH), wethToBorrow);
            data[2] = Fund.AdaptorCall({ adaptor: address(debtTokenAdaptor), callData: adaptorCalls });
        }
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv2(WETH, STETH, type(uint256).max);
            data[3] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }
        // Supply WSTETH as collateral on Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToLendToMorphoAaveV2(address(aV2STETH), type(uint256).max);
            data[4] = Fund.AdaptorCall({ adaptor: address(aTokenAdaptor), callData: adaptorCalls });
        }

        // Perform callOnAdaptor.
        fund.callOnAdaptor(data);
    }

    function testIsBorrowingAnyFullRepay(uint256 assetsToBorrow) external {
        assetsToBorrow = bound(assetsToBorrow, 1, 1_000e18);

        // Add vanilla WETH to the fund.
        fund.addPosition(0, wethPosition, abi.encode(true), false);
        // Add debt position to fund.
        fund.addPosition(0, morphoDebtWethPosition, abi.encode(0), true);

        uint256 assetsToLend = 2 * assetsToBorrow;

        deal(address(WETH), address(this), assetsToLend);
        fund.deposit(assetsToLend, address(this));

        assertTrue(!aTokenAdaptor.isBorrowingAny(address(fund)), "Fund should not be borrowing.");

        // Rebalance Fund to take on debt.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        // Borrow WETH from Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToBorrowFromMorphoAaveV2(address(aV2WETH), assetsToBorrow);
            data[0] = Fund.AdaptorCall({ adaptor: address(debtTokenAdaptor), callData: adaptorCalls });
        }

        // Perform callOnAdaptor.
        fund.callOnAdaptor(data);

        deal(address(WETH), address(fund), assetsToBorrow + 1);

        assertTrue(aTokenAdaptor.isBorrowingAny(address(fund)), "Fund should be borrowing.");

        // Rebalance Fund to repay debt in full.
        data = new Fund.AdaptorCall[](1);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToRepayToMorphoAaveV2(address(address(aV2WETH)), type(uint256).max);
            data[0] = Fund.AdaptorCall({ adaptor: address(debtTokenAdaptor), callData: adaptorCalls });
        }

        // Perform callOnAdaptor.
        fund.callOnAdaptor(data);

        assertTrue(!aTokenAdaptor.isBorrowingAny(address(fund)), "Fund should not be borrowing.");
    }

    function testHealthFactorChecks() external {
        uint256 assets = 100e18;

        // Add vanilla WETH to the fund.
        fund.addPosition(0, wethPosition, abi.encode(true), false);
        // Add debt position to fund.
        fund.addPosition(0, morphoDebtWethPosition, abi.encode(0), true);

        deal(address(WETH), address(this), assets);
        fund.deposit(assets, address(this));

        uint256 targetHealthFactor = 1.052e18;
        uint256 ltv = 0.86e18;
        uint256 wethToBorrow = assets.mulDivDown(ltv, targetHealthFactor);
        uint256 wethToBorrowToTriggerHealthFactorRevert = 0.2e18;

        // Rebalance Fund to take on debt.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        // Borrow WETH from Morpho.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToBorrowFromMorphoAaveV2(address(aV2WETH), wethToBorrow);
            data[0] = Fund.AdaptorCall({ adaptor: address(debtTokenAdaptor), callData: adaptorCalls });
        }

        // Perform callOnAdaptor.
        fund.callOnAdaptor(data);

        // Borrow more WETH from Morpho to trigger HF check.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToBorrowFromMorphoAaveV2(
                address(aV2WETH),
                wethToBorrowToTriggerHealthFactorRevert
            );
            data[0] = Fund.AdaptorCall({ adaptor: address(debtTokenAdaptor), callData: adaptorCalls });
        }

        // callOnAdaptor reverts because the health factor is too low.
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    MorphoAaveV2DebtTokenAdaptor.MorphoAaveV2DebtTokenAdaptor__HealthFactorTooLow.selector
                )
            )
        );
        fund.callOnAdaptor(data);

        // Try withdrawing WETH to lower Health Factor passed minimum.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToWithdrawFromMorphoAaveV2(address(aV2WETH), 0.2e18);
            data[0] = Fund.AdaptorCall({ adaptor: address(aTokenAdaptor), callData: adaptorCalls });
        }

        // callOnAdaptor reverts because the health factor is too low.
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(MorphoAaveV2ATokenAdaptor.MorphoAaveV2ATokenAdaptor__HealthFactorTooLow.selector)
            )
        );
        fund.callOnAdaptor(data);
    }

    // ========================================= HELPER FUNCTIONS =========================================

    function _setupFundForBorrowing(Fund target) internal {
        // Add required positions.
        target.addPosition(0, wethPosition, abi.encode(true), false);
        target.addPosition(1, stethPosition, abi.encode(true), false);
        target.addPosition(2, morphoAStEthPosition, abi.encode(0), false);
        target.addPosition(0, morphoDebtWethPosition, abi.encode(0), true);

        // Change holding position to vanilla WETH.
        target.setHoldingPosition(wethPosition);
    }

    function getMorphoBalance(address poolToken, address user) internal view returns (uint256) {
        (uint256 inP2P, uint256 onPool) = morpho.supplyBalanceInOf(poolToken, user);

        uint256 balanceInUnderlying;
        if (inP2P > 0) balanceInUnderlying = inP2P.mulDivDown(morpho.p2pSupplyIndex(poolToken), 1e27);
        if (onPool > 0) balanceInUnderlying += onPool.mulDivDown(morpho.poolIndexes(poolToken).poolSupplyIndex, 1e27);
        return balanceInUnderlying;
    }

    function getMorphoDebt(address aToken, address user) public view returns (uint256) {
        (uint256 inP2P, uint256 onPool) = morpho.borrowBalanceInOf(aToken, user);

        uint256 balanceInUnderlying;
        if (inP2P > 0) balanceInUnderlying = inP2P.mulDivDown(morpho.p2pBorrowIndex(aToken), 1e27);
        if (onPool > 0) balanceInUnderlying += onPool.mulDivDown(morpho.poolIndexes(aToken).poolBorrowIndex, 1e27);
        return balanceInUnderlying;
    }
}
