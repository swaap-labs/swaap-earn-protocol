// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ParaswapAdaptor } from "src/modules/adaptors/Paraswap/ParaswapAdaptor.sol";
import { MockParaswapAdaptor } from "src/mocks/adaptors/MockParaswapAdaptor.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";

import { CellarAggregatorBaseAdaptorTest, MockAggregatorBaseAdaptor } from "test/testAdaptors/AggregatorBaseAdaptor.t.sol";

contract CellarParaswapTest is CellarAggregatorBaseAdaptorTest {
    using Math for uint256;

    ParaswapAdaptor private paraswapAdaptor;
    MockParaswapAdaptor private mockParaswapAdaptor;

    // Swap Details
    address private spender = 0x216B4B4Ba9F3e719726886d34a177484278Bfcae;
    address private swapTarget = 0xDEF171Fe48CF0115B1d80b88dc8eAB59176FEe57;

    // Paraswap swap calldata
    bytes private swapCallData =
        hex"0b86a4c1000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000000009896800000000000000000000000000000000000000000000000000000000001c23549000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000001000000000000000000004de46e1fbeeaba87bae1100d95f8340dc27ad7c8427b";

    // Swap Details from the calldata
    uint256 swapTokenInAmount = 10_000_000;

    function setUp() external override {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 19183203;
        _startFork(rpcKey, blockNumber);

        // Run Starter setUp code.
        _setUpAggregatorTest();

        paraswapAdaptor = new ParaswapAdaptor(swapTarget, spender, address(erc20Adaptor));
        mockParaswapAdaptor = new MockParaswapAdaptor(mockSwapTarget, mockSwapTarget, address(erc20Adaptor));

        // Add adaptors and positions to the registry.
        registry.trustAdaptor(address(paraswapAdaptor));
        registry.trustAdaptor(address(mockParaswapAdaptor));

        cellar.addAdaptorToCatalogue(address(paraswapAdaptor));
        cellar.addAdaptorToCatalogue(address(mockParaswapAdaptor));

        // replacing all mockAggregatorAdaptor with mockParaswapAdaptor to test the real adaptor
        mockAggregatorAdaptor = MockAggregatorBaseAdaptor(address(mockParaswapAdaptor));
    }

    function testParaswapSwap() external {
        // Deposit into Cellar.
        uint256 assets = 10_000_000;
        deal(address(USDC), address(this), assets);
        cellar.deposit(assets, address(this));

        uint32 maxSlippage = 0.99e4;

        registry.setMaxAllowedAdaptorVolumeParams(
            address(cellar),
            1 days, // period length
            type(uint80).max, // max volume traded
            true // reset volume
        );

        {
            Cellar.AdaptorCall[] memory data = new Cellar.AdaptorCall[](1);
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToSwap(USDC, WETH, assets, maxSlippage, swapCallData);

            data[0] = Cellar.AdaptorCall({ adaptor: address(paraswapAdaptor), callData: adaptorCalls });
            cellar.callOnAdaptor(data);
        }

        assertEq(USDC.balanceOf(address(cellar)), assets + initialAssets - swapTokenInAmount, "Cellar USDC should have been converted into WETH.");
        uint256 expectedWETH = priceRouter.getValue(USDC, assets, WETH);
        assertApproxEqRel(
            WETH.balanceOf(address(cellar)),
            expectedWETH,
            0.01e18,
            "Cellar WETH should be approximately equal to expected."
        );
    }

    function _createBytesDataToSwap(
        ERC20 tokenIn,
        ERC20 tokenOut,
        uint256 amount,
        uint32 slippage,
        bytes memory _swapCallData
    ) internal pure override returns (bytes memory) {
        return
            abi.encodeWithSelector(ParaswapAdaptor.swapWithParaswap.selector, tokenIn, tokenOut, amount, slippage, _swapCallData);
    }
}