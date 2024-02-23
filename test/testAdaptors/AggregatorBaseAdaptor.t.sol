// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { MockAggregatorBaseAdaptor } from "src/mocks/adaptors/MockAggregatorBaseAdaptor.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";

import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";
import { PriceRouter } from "src/modules/price-router/PriceRouter.sol";

contract FundAggregatorBaseAdaptorTest is MainnetStarterTest, AdaptorHelperFunctions {
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using stdStorage for StdStorage;

    MockAggregatorBaseAdaptor internal mockAggregatorAdaptor;

    Fund internal fund;

    uint32 internal usdcPosition = 1;
    uint32 internal wethPosition = 2;

    // Swap Details
    address internal mockSwapTarget = 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496;

    uint256 internal initialAssets;

    function setUp() external virtual {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 16921343;
        _startFork(rpcKey, blockNumber);
        _setUpAggregatorTest();
    }

    function _setUpAggregatorTest() internal virtual {
        // Run Starter setUp code.
        _setUp();

        mockAggregatorAdaptor = new MockAggregatorBaseAdaptor(mockSwapTarget, mockSwapTarget, address(erc20Adaptor));

        PriceRouter.ChainlinkDerivativeStorage memory stor;

        PriceRouter.AssetSettings memory settings;

        uint256 price = uint256(IChainlinkAggregator(WETH_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, WETH_USD_FEED);
        priceRouter.addAsset(WETH, settings, abi.encode(stor), price);

        price = uint256(IChainlinkAggregator(USDC_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, USDC_USD_FEED);
        priceRouter.addAsset(USDC, settings, abi.encode(stor), price);

        // Setup Fund:

        // Add adaptors and positions to the registry.
        registry.trustAdaptor(address(mockAggregatorAdaptor));

        registry.trustPosition(usdcPosition, address(erc20Adaptor), abi.encode(USDC));
        registry.trustPosition(wethPosition, address(erc20Adaptor), abi.encode(WETH));

        string memory fundName = "Aggregator Fund V0.0";
        uint256 initialDeposit = 1e6;

        fund = _createFund(fundName, USDC, usdcPosition, abi.encode(0), initialDeposit);

        fund.addAdaptorToCatalogue(address(mockAggregatorAdaptor));

        fund.addPositionToCatalogue(wethPosition);

        fund.addPosition(1, wethPosition, abi.encode(0), false);

        fund.setRebalanceDeviation(0.01e18);

        USDC.safeApprove(address(fund), type(uint256).max);

        initialAssets = fund.totalAssets();
    }

    function testRevertAggregatorSwapIfTotalVolumeIsSurpassed() external virtual {
        // Deposit into Fund.
        uint256 assets = 10_000_000e6;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        // Make a swap where both assets are supported by the price router, and slippage is good.
        ERC20 from = USDC;
        ERC20 to = WETH;
        uint256 fromAmount = 1_000e6;
        uint32 maxSlippage = 1e4 - (1e4 - mockAggregatorAdaptor.slippage()) / 2;
        bytes memory slippageSwapData = abi.encodeWithSignature(
            "slippageSwap(address,address,uint256,uint32)",
            from,
            to,
            fromAmount,
            maxSlippage + 1
        );

        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _createBytesDataToSwap(from, to, assets, maxSlippage, slippageSwapData);

        data[0] = Fund.AdaptorCall({ adaptor: address(mockAggregatorAdaptor), callData: adaptorCalls });

        vm.expectRevert(abi.encodeWithSelector(Registry.Registry__FundTradingVolumeExceeded.selector, address(fund)));
        fund.callOnAdaptor(data);
    }

    function testVolumeIsIncrementedCorrectly() external virtual {
        // Deposit into Fund.
        uint256 assets = 1_000_000e6;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        uint256 periodLength = 2 hours;

        ERC20 from;
        ERC20 to;
        uint256 fromAmount;
        bytes memory slippageSwapData;
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);

        // Make a swap where both assets are supported by the price router, and slippage is good.
        from = USDC;
        to = WETH;
        fromAmount = 1_000e6;
        uint32 maxSlippage = 1e4 - (1e4 - mockAggregatorAdaptor.slippage()) / 2;
        slippageSwapData = abi.encodeWithSignature(
            "slippageSwap(address,address,uint256,uint32)",
            from,
            to,
            fromAmount,
            maxSlippage + 1
        );

        registry.setMaxAllowedAdaptorVolumeParams(
            address(fund),
            uint48(periodLength), // period length
            type(uint80).max, // max volume traded
            true // reset volume
        );

        uint48 initLastUpdate;

        (uint48 newLastUpdate, uint48 newPeriodLength, uint80 newVolumeInUSD, uint80 newMaxVolumeInUSD) = registry
            .fundsAdaptorVolumeData(address(fund));

        // checking that the variables are set correctly after setting the volume parameters
        assertApproxEqAbs(
            newLastUpdate,
            block.timestamp,
            1,
            "lastUpdate should be the current block timestamp after resetting fund volume data"
        );
        assertEq(newPeriodLength, periodLength, "periodLength should be equal to the initial period");
        assertEq(newVolumeInUSD, 0, "volumeInUSD should be 0 after resetting fund volume data");
        assertEq(newMaxVolumeInUSD, type(uint80).max, "maxVolumeInUSD should be equal to type(uint80).max");

        initLastUpdate = newLastUpdate;

        // Make the swap.
        adaptorCalls[0] = _createBytesDataToSwap(from, to, fromAmount, maxSlippage, slippageSwapData);
        data[0] = Fund.AdaptorCall({ adaptor: address(mockAggregatorAdaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        (newLastUpdate, newPeriodLength, newVolumeInUSD, newMaxVolumeInUSD) = registry.fundsAdaptorVolumeData(
            address(fund)
        );

        // checking that the variables are set correctly after swapping
        // when the max volume is set to type(uint80).max
        assertEq(newLastUpdate, initLastUpdate, "lastUpdate should be the current block timestamp after a trade");
        assertEq(newPeriodLength, periodLength, "periodLength should be equal to the initial period");
        assertEq(newVolumeInUSD, 0, "Fund volume should remain the same when max volume is set to type(uint80).max");
        assertEq(newMaxVolumeInUSD, type(uint80).max, "maxVolumeInUSD should remain the same after a trade");

        registry.setMaxAllowedAdaptorVolumeParams(
            address(fund),
            uint48(periodLength), // period length
            type(uint80).max / 2, // max volume traded
            false // reset volume
        );

        // checking that the variables are set correctly after swapping
        // when the max volume is set to less than type(uint80).max
        fund.callOnAdaptor(data);

        (newLastUpdate, newPeriodLength, newVolumeInUSD, newMaxVolumeInUSD) = registry.fundsAdaptorVolumeData(
            address(fund)
        );

        assertEq(newLastUpdate, initLastUpdate, "lastUpdate should be equal to the initial lastUpdate");
        assertEq(newPeriodLength, periodLength, "periodLength should be equal to the initial period");
        assertApproxEqRel(newVolumeInUSD, (fromAmount * 1e8) / 1e6, 0.01e18, "Fund volume should be updated");
        assertEq(newMaxVolumeInUSD, type(uint80).max / 2, "maxVolumeInUSD should remain the same after a trade");

        // advance time by 5 minutes
        skip(5 minutes);

        fund.callOnAdaptor(data);

        (newLastUpdate, newPeriodLength, newVolumeInUSD, newMaxVolumeInUSD) = registry.fundsAdaptorVolumeData(
            address(fund)
        );

        // checking that the variables are set correctly after swapping twice
        // when the max volume is set to less than type(uint80).max
        assertEq(newLastUpdate, initLastUpdate, "lastUpdate should be equal to the initial lastUpdate");
        assertEq(newPeriodLength, periodLength, "periodLength should be equal to the initial period");
        assertApproxEqRel(
            newVolumeInUSD,
            (fromAmount * 2 * 1e8) / 1e6,
            0.01e18,
            "Fund volume should be updated after a trade"
        );
        assertEq(newMaxVolumeInUSD, type(uint80).max / 2, "maxVolumeInUSD should remain the same after a trade");

        skip(periodLength);

        // Make the swap again.
        fund.callOnAdaptor(data);

        (newLastUpdate, newPeriodLength, newVolumeInUSD, newMaxVolumeInUSD) = registry.fundsAdaptorVolumeData(
            address(fund)
        );

        // checking that the variables are set correctly after swapping several
        // when the max volume is set to less than type(uint80).max and the period has passed
        assertApproxEqAbs(newLastUpdate, block.timestamp, 1, "lastUpdate should be updated");
        assertEq(newPeriodLength, periodLength, "periodLength should be equal to the initial period after a trade");
        assertApproxEqRel(
            newVolumeInUSD,
            (fromAmount * 1e8) / 1e6,
            0.01e18,
            "Fund volume should be reset and then updated"
        );
        assertEq(newMaxVolumeInUSD, type(uint80).max / 2, "maxVolumeInUSD should remain the same after a trade");

        initLastUpdate = newLastUpdate;

        // advance time by 5 minutes
        skip(5 minutes);

        registry.setMaxAllowedAdaptorVolumeParams(
            address(fund),
            uint48(periodLength) * 2, // period length
            type(uint80).max, // max volume traded
            false // reset volume
        );

        (newLastUpdate, newPeriodLength, newVolumeInUSD, newMaxVolumeInUSD) = registry.fundsAdaptorVolumeData(
            address(fund)
        );

        // checking that the variables are after setting max volume and period length only
        assertEq(newLastUpdate, initLastUpdate, "lastUpdate should remain the same");
        assertEq(newPeriodLength, periodLength * 2, "periodLength should be equal to the initial period after a trade");
        assertApproxEqRel(newVolumeInUSD, (fromAmount * 1e8) / 1e6, 0.01e18, "Fund volume should not be reset");
        assertEq(newMaxVolumeInUSD, type(uint80).max, "maxVolumeInUSD should be updated");

        registry.setMaxAllowedAdaptorVolumeParams(
            address(fund),
            uint48(periodLength), // period length
            type(uint80).max, // max volume traded
            true // reset volume
        );

        (newLastUpdate, newPeriodLength, newVolumeInUSD, newMaxVolumeInUSD) = registry.fundsAdaptorVolumeData(
            address(fund)
        );

        // checking that the variables are after setting max volume and period length and resetting volume
        assertApproxEqAbs(newLastUpdate, block.timestamp, 1, "lastUpdate should be updated after a reset");
        assertEq(newPeriodLength, periodLength, "periodLength should be updated");
        assertEq(newVolumeInUSD, 0, "Fund volume should be set to 0 after a reset");
        assertEq(newMaxVolumeInUSD, type(uint80).max, "maxVolumeInUSD should be updated");
    }

    function testSlippageChecks() external virtual {
        // Deposit into Fund.
        uint256 assets = 1_000_000e6;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        registry.setMaxAllowedAdaptorVolumeParams(
            address(fund),
            1 days, // period length
            type(uint80).max, // max volume traded
            true // reset volume
        );

        ERC20 from;
        ERC20 to;
        uint256 fromAmount;
        bytes memory slippageSwapData;
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        uint32 maxSlippage = 1e4 - (1e4 - mockAggregatorAdaptor.slippage()) / 2;

        // Make a swap where both assets are supported by the price router, and slippage is good.
        from = USDC;
        to = WETH;
        fromAmount = 1_000e6;
        slippageSwapData = abi.encodeWithSignature(
            "slippageSwap(address,address,uint256,uint32)",
            from,
            to,
            fromAmount,
            maxSlippage + 1
        );

        // Make the swap.
        adaptorCalls[0] = _createBytesDataToSwap(from, to, fromAmount, maxSlippage, slippageSwapData);
        data[0] = Fund.AdaptorCall({ adaptor: address(mockAggregatorAdaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        // This test does not spend funds approval, but check it is still zero.
        assertEq(USDC.allowance(address(fund), address(this)), 0, "Approval should have been revoked.");

        // Make the same swap, but have the slippage check fail (for custom slippage).
        slippageSwapData = abi.encodeWithSignature(
            "slippageSwap(address,address,uint256,uint32)",
            from,
            to,
            fromAmount,
            maxSlippage - 1
        );

        // Make the swap.
        adaptorCalls[0] = _createBytesDataToSwap(from, to, fromAmount, maxSlippage, slippageSwapData);
        data[0] = Fund.AdaptorCall({ adaptor: address(mockAggregatorAdaptor), callData: adaptorCalls });
        vm.expectRevert(bytes(abi.encodeWithSelector(BaseAdaptor.BaseAdaptor__Slippage.selector)));
        fund.callOnAdaptor(data);

        // Make the same swap, but have the slippage check fail (for aggregator base slippage).
        slippageSwapData = abi.encodeWithSignature(
            "slippageSwap(address,address,uint256,uint32)",
            from,
            to,
            fromAmount,
            mockAggregatorAdaptor.slippage() - 1
        );

        // Make the swap.
        adaptorCalls[0] = _createBytesDataToSwap(from, to, fromAmount, 0, slippageSwapData);
        data[0] = Fund.AdaptorCall({ adaptor: address(mockAggregatorAdaptor), callData: adaptorCalls });
        vm.expectRevert(bytes(abi.encodeWithSelector(BaseAdaptor.BaseAdaptor__Slippage.selector)));
        fund.callOnAdaptor(data);

        // Demonstrate that multiple swaps back to back can max out slippage and still work.
        from = USDC;
        to = WETH;
        fromAmount = 1_000e6;
        slippageSwapData = abi.encodeWithSignature(
            "slippageSwap(address,address,uint256,uint32)",
            from,
            to,
            fromAmount,
            maxSlippage + 1
        );

        adaptorCalls = new bytes[](10);
        for (uint256 i; i < 10; ++i)
            adaptorCalls[i] = _createBytesDataToSwap(from, to, fromAmount, maxSlippage, slippageSwapData);
        data[0] = Fund.AdaptorCall({ adaptor: address(mockAggregatorAdaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        // Above rebalance works, but this attack vector will be mitigated on the steward side, by flagging suspicious rebalances,
        // such as the one above.
    }

    function testRevertForUnsupportedAssets() external virtual {
        registry.setMaxAllowedAdaptorVolumeParams(
            address(fund),
            1 days, // period length
            type(uint80).max, // max volume traded
            true // reset volume
        );

        ERC20 from;
        ERC20 to;
        uint256 fromAmount;
        bytes memory slippageSwapData;
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        uint32 maxSlippage = 1e4 - (1e4 - mockAggregatorAdaptor.slippage()) / 2;

        // Try making a swap where the from `asset` is supported, but the `to` asset is not by a position in the fund.
        from = USDC;
        to = ERC20(address(1));
        fromAmount = 1_000e6;
        slippageSwapData = abi.encodeWithSignature(
            "slippageSwap(address,address,uint256,uint32)",
            from,
            to,
            fromAmount,
            maxSlippage + 1
        );
        adaptorCalls[0] = _createBytesDataToSwap(from, to, fromAmount, maxSlippage, slippageSwapData);
        data[0] = Fund.AdaptorCall({ adaptor: address(mockAggregatorAdaptor), callData: adaptorCalls });

        vm.expectRevert(
            abi.encodeWithSelector(BaseAdaptor.BaseAdaptor__PositionNotUsed.selector, abi.encode(address(1)))
        );
        fund.callOnAdaptor(data);

        // Make a swap where the `from` asset is not supported by the price router.
        from = DAI;
        to = USDC;
        fromAmount = 1_000e18;
        deal(address(DAI), address(fund), fromAmount);
        slippageSwapData = abi.encodeWithSignature(
            "slippageSwap(address,address,uint256,uint32)",
            from,
            to,
            fromAmount,
            maxSlippage + 1
        );
        adaptorCalls[0] = _createBytesDataToSwap(from, to, fromAmount, maxSlippage, slippageSwapData);
        data[0] = Fund.AdaptorCall({ adaptor: address(mockAggregatorAdaptor), callData: adaptorCalls });

        vm.expectRevert(abi.encodeWithSelector(PriceRouter.PriceRouter__UnknownDerivative.selector, 0));
        fund.callOnAdaptor(data);
    }

    function slippageSwap(ERC20 from, ERC20 to, uint256 inAmount, uint32 slippage) public virtual {
        if (priceRouter.isSupported(from) && priceRouter.isSupported(to)) {
            // Figure out value in, quoted in `to`.
            uint256 fullValueOut = priceRouter.getValue(from, inAmount, to);
            uint256 valueOutWithSlippage = fullValueOut.mulDivDown(slippage, 1e4);
            // Deal caller new balances.
            deal(address(from), msg.sender, from.balanceOf(msg.sender) - inAmount);
            deal(address(to), msg.sender, to.balanceOf(msg.sender) + valueOutWithSlippage);
        } else {
            // Pricing is not supported, so just assume exchange rate is 1:1.
            deal(address(from), msg.sender, from.balanceOf(msg.sender) - inAmount);
            deal(
                address(to),
                msg.sender,
                to.balanceOf(msg.sender) + inAmount.changeDecimals(from.decimals(), to.decimals())
            );
        }
    }

    function _createBytesDataToSwap(
        ERC20 tokenIn,
        ERC20 tokenOut,
        uint256 amount,
        uint32 slippage,
        bytes memory _swapCallData
    ) internal pure virtual returns (bytes memory) {
        return
            abi.encodeWithSelector(
                MockAggregatorBaseAdaptor.swapWithAggregator.selector,
                tokenIn,
                tokenOut,
                amount,
                slippage,
                _swapCallData
            );
    }
}
