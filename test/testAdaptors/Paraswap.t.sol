// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ParaswapAdaptor } from "src/modules/adaptors/Paraswap/ParaswapAdaptor.sol";
import { MockParaswapAdaptor } from "src/mocks/adaptors/MockParaswapAdaptor.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";

import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";
import { PriceRouter } from "src/modules/price-router/PriceRouter.sol";

contract CellarParaswapTest is MainnetStarterTest, AdaptorHelperFunctions {
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using stdStorage for StdStorage;

    ParaswapAdaptor private paraswapAdaptor;
    ParaswapAdaptor private mockParaswapAdaptor;
    Cellar private cellar;

    uint32 private usdcPosition = 1;
    uint32 private wethPosition = 2;

    // Swap Details
    address private spender = 0x216B4B4Ba9F3e719726886d34a177484278Bfcae;
    address private swapTarget = 0xDEF171Fe48CF0115B1d80b88dc8eAB59176FEe57;
    address private mockSwapTarget = 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496;
    
    // Paraswap swap calldata
    bytes private swapCallData =
        hex"0b86a4c1000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000000009896800000000000000000000000000000000000000000000000000000000001c23549000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000001000000000000000000004de46e1fbeeaba87bae1100d95f8340dc27ad7c8427b";

    uint256 initialAssets;

    function setUp() external {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 19183203;
        _startFork(rpcKey, blockNumber);

        // Run Starter setUp code.
        _setUp();

        paraswapAdaptor = new ParaswapAdaptor(swapTarget, spender, address(erc20Adaptor));
        mockParaswapAdaptor = new MockParaswapAdaptor(mockSwapTarget, spender, address(erc20Adaptor));

        PriceRouter.ChainlinkDerivativeStorage memory stor;

        PriceRouter.AssetSettings memory settings;

        uint256 price = uint256(IChainlinkAggregator(WETH_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, WETH_USD_FEED);
        priceRouter.addAsset(WETH, settings, abi.encode(stor), price);

        price = uint256(IChainlinkAggregator(USDC_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, USDC_USD_FEED);
        priceRouter.addAsset(USDC, settings, abi.encode(stor), price);

        // Setup Cellar:

        // Add adaptors and positions to the registry.
        registry.trustAdaptor(address(paraswapAdaptor));
        registry.trustAdaptor(address(mockParaswapAdaptor));

        registry.trustPosition(usdcPosition, address(erc20Adaptor), abi.encode(USDC));
        registry.trustPosition(wethPosition, address(erc20Adaptor), abi.encode(WETH));

        string memory cellarName = "Paraswap Cellar V0.0";
        uint256 initialDeposit = 1e6;
        uint64 platformCut = 0.75e18;

        cellar = _createCellar(cellarName, USDC, usdcPosition, abi.encode(0), initialDeposit, platformCut);

        cellar.addAdaptorToCatalogue(address(paraswapAdaptor));
        cellar.addAdaptorToCatalogue(address(mockParaswapAdaptor));

        cellar.addPositionToCatalogue(wethPosition);

        cellar.addPosition(1, wethPosition, abi.encode(0), false);

        cellar.setRebalanceDeviation(0.01e18);

        USDC.safeApprove(address(cellar), type(uint256).max);

        initialAssets = cellar.totalAssets();
    }

    function testParaswapSwap() external {
        // Deposit into Cellar.
        uint256 assets = 10_000_000;
        deal(address(USDC), address(this), assets);
        cellar.deposit(assets, address(this));

        {
            Cellar.AdaptorCall[] memory data = new Cellar.AdaptorCall[](1);
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToSwap(USDC, WETH, assets, swapCallData);

            data[0] = Cellar.AdaptorCall({ adaptor: address(paraswapAdaptor), callData: adaptorCalls });
            
            cellar.callOnAdaptor(data);
            
        }
        assertEq(USDC.balanceOf(address(cellar)), initialAssets, "Cellar USDC should have been converted into WETH.");
        uint256 expectedWETH = priceRouter.getValue(USDC, assets, WETH);
        assertApproxEqRel(
            WETH.balanceOf(address(cellar)),
            expectedWETH,
            0.01e18,
            "Cellar WETH should be approximately equal to expected."
        );
    }

    function testSlippageChecks() external {
        // Deposit into Cellar.
        uint256 assets = 1_000_000e6;
        deal(address(USDC), address(this), assets);
        cellar.deposit(assets, address(this));

        ERC20 from;
        ERC20 to;
        uint256 fromAmount;
        bytes memory slippageSwapData;
        Cellar.AdaptorCall[] memory data = new Cellar.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);

        // Make a swap where both assets are supported by the price router, and slippage is good.
        from = USDC;
        to = WETH;
        fromAmount = 1_000e6;
        slippageSwapData = abi.encodeWithSignature(
            "slippageSwap(address,address,uint256,uint32)",
            from,
            to,
            fromAmount,
            0.99e4
        );

        // Make the swap.
        adaptorCalls[0] = _createBytesDataToSwap(from, to, fromAmount, slippageSwapData);
        data[0] = Cellar.AdaptorCall({ adaptor: address(mockParaswapAdaptor), callData: adaptorCalls });
        cellar.callOnAdaptor(data);

        // This test does not spend cellars approval, but check it is still zero.
        assertEq(USDC.allowance(address(cellar), address(this)), 0, "Approval should have been revoked.");

        // Make the same swap, but have the slippage check fail.
        slippageSwapData = abi.encodeWithSignature(
            "slippageSwap(address,address,uint256,uint32)",
            from,
            to,
            fromAmount,
            0.89e4
        );

        // Make the swap.
        adaptorCalls[0] = _createBytesDataToSwap(from, to, fromAmount, slippageSwapData);
        data[0] = Cellar.AdaptorCall({ adaptor: address(mockParaswapAdaptor), callData: adaptorCalls });
        vm.expectRevert(bytes(abi.encodeWithSelector(BaseAdaptor.BaseAdaptor__Slippage.selector)));
        cellar.callOnAdaptor(data);

        // Demonstrate that multiple swaps back to back can max out slippage and still work.
        from = USDC;
        to = WETH;
        fromAmount = 1_000e6;
        slippageSwapData = abi.encodeWithSignature(
            "slippageSwap(address,address,uint256,uint32)",
            from,
            to,
            fromAmount,
            0.9001e4
        );

        adaptorCalls = new bytes[](10);
        for (uint256 i; i < 10; ++i) adaptorCalls[i] = _createBytesDataToSwap(from, to, fromAmount, slippageSwapData);
        data[0] = Cellar.AdaptorCall({ adaptor: address(mockParaswapAdaptor), callData: adaptorCalls });
        cellar.callOnAdaptor(data);

        // Above rebalance works, but this attack vector will be mitigated on the steward side, by flagging suspicious rebalances,
        // such as the one above.
    }

    function testRevertForUnsupportedAssets() external {
        ERC20 from;
        ERC20 to;
        uint256 fromAmount;
        bytes memory slippageSwapData;
        Cellar.AdaptorCall[] memory data = new Cellar.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);

        // Try making a swap where the from `asset` is supported, but the `to` asset is not by a position in the cellar.
        from = USDC;
        to = ERC20(address(1));
        fromAmount = 1_000e6;
        slippageSwapData = abi.encodeWithSignature(
            "slippageSwap(address,address,uint256,uint32)",
            from,
            to,
            fromAmount,
            0.99e4
        );
        adaptorCalls[0] = _createBytesDataToSwap(from, to, fromAmount, slippageSwapData);
        data[0] = Cellar.AdaptorCall({ adaptor: address(mockParaswapAdaptor), callData: adaptorCalls });

        vm.expectRevert(abi.encodeWithSelector(BaseAdaptor.BaseAdaptor__PositionNotUsed.selector, abi.encode(address(1))));
        cellar.callOnAdaptor(data);

        // Make a swap where the `from` asset is not supported by the price router.
        from = DAI;
        to = USDC;
        fromAmount = 1_000e18;
        deal(address(DAI), address(cellar), fromAmount);
        slippageSwapData = abi.encodeWithSignature(
            "slippageSwap(address,address,uint256,uint32)",
            from,
            to,
            fromAmount,
            0.99e4
        );
        adaptorCalls[0] = _createBytesDataToSwap(from, to, fromAmount, slippageSwapData);
        data[0] = Cellar.AdaptorCall({ adaptor: address(mockParaswapAdaptor), callData: adaptorCalls });
        
        vm.expectRevert(abi.encodeWithSelector(PriceRouter.PriceRouter__UnsupportedAsset.selector, address(DAI)));
        cellar.callOnAdaptor(data);
    }

    function slippageSwap(ERC20 from, ERC20 to, uint256 inAmount, uint32 slippage) public {
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
        bytes memory _swapCallData
    ) internal pure returns (bytes memory) {
        return
            abi.encodeWithSelector(ParaswapAdaptor.swapWithParaswap.selector, tokenIn, tokenOut, amount, _swapCallData);
    }
}