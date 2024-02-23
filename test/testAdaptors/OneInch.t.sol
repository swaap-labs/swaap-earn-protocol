// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { OneInchAdaptor } from "src/modules/adaptors/OneInch/OneInchAdaptor.sol";
import { MockOneInchAdaptor } from "src/mocks/adaptors/MockOneInchAdaptor.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";

import { FundAggregatorBaseAdaptorTest, MockAggregatorBaseAdaptor } from "test/testAdaptors/AggregatorBaseAdaptor.t.sol";

contract FundOneInchTest is FundAggregatorBaseAdaptorTest {
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using stdStorage for StdStorage;

    OneInchAdaptor private oneInchAdaptor;
    MockOneInchAdaptor private mockOneInchAdaptor;

    // Swap Details
    address private swapTarget = 0x1111111254EEB25477B68fb85Ed929f73A960582;

    bytes private swapCallData =
        hex"0502b1c5000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000000000000000000000000000000000000000989680000000000000000000000000000000000000000000000000001483d59a9bcf1b0000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000100000000000000003b5dc1003926a168c11a816e10c13977f75f488bfffe88e4cfee7c08";

    // Swap Details from the calldata
    uint256 swapTokenInAmount = 10_000_000;

    function setUp() external override {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 16921343;
        _startFork(rpcKey, blockNumber);

        // Run Starter setUp code.
        _setUpAggregatorTest();

        oneInchAdaptor = new OneInchAdaptor(swapTarget, address(erc20Adaptor));
        mockOneInchAdaptor = new MockOneInchAdaptor(mockSwapTarget, address(erc20Adaptor));

        // Add adaptors and positions to the registry.
        registry.trustAdaptor(address(oneInchAdaptor));
        registry.trustAdaptor(address(mockOneInchAdaptor));

        fund.addAdaptorToCatalogue(address(oneInchAdaptor));
        fund.addAdaptorToCatalogue(address(mockOneInchAdaptor));

        // replacing all mockAggregatorAdaptor with mockOneInchAdaptor to test the real adaptor
        mockAggregatorAdaptor = MockAggregatorBaseAdaptor(address(mockOneInchAdaptor));
    }

    function testOneInchSwap() external {
        // Deposit into Fund.
        uint256 assets = 10_000_000;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        uint32 maxSlippage = 0.99e4;

        registry.setMaxAllowedAdaptorVolumeParams(
            address(fund),
            1 days, // period length
            type(uint80).max, // max volume traded
            true // reset volume
        );

        {
            Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToSwap(USDC, WETH, assets, maxSlippage, swapCallData);

            data[0] = Fund.AdaptorCall({ adaptor: address(oneInchAdaptor), callData: adaptorCalls });
            fund.callOnAdaptor(data);
        }

        assertEq(
            USDC.balanceOf(address(fund)),
            initialAssets + assets - swapTokenInAmount,
            "Fund USDC should have been converted into WETH."
        );
        uint256 expectedWETH = priceRouter.getValue(USDC, assets, WETH);
        assertApproxEqRel(
            WETH.balanceOf(address(fund)),
            expectedWETH,
            0.01e18,
            "Fund WETH should be approximately equal to expected."
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
            abi.encodeWithSelector(
                OneInchAdaptor.swapWithOneInch.selector,
                tokenIn,
                tokenOut,
                amount,
                slippage,
                _swapCallData
            );
    }
}

// OneInch swap calldata at block 16921343

// {
//   "fromToken": {
//     "symbol": "ETH",
//     "name": "Ethereum",
//     "decimals": 18,
//     "address": "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
//     "logoURI": "https://tokens.1inch.io/0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee.png",
//     "tags": [
//       "native",
//       "PEG:ETH"
//     ]
//   },
//   "toToken": {
//     "symbol": "MATIC",
//     "name": "Matic Token",
//     "decimals": 18,
//     "address": "0x7d1afa7b718fb893db30a3abc0cfc608aacfebb0",
//     "logoURI": "https://tokens.1inch.io/0x7d1afa7b718fb893db30a3abc0cfc608aacfebb0.png",
//     "tags": [
//       "tokens"
//     ]
//   },
//   "toTokenAmount": "163963423852",
//   "fromTokenAmount": "100000000",
//   "protocols": [
//     [
//       [
//         {
//           "name": "UNISWAP_V2",
//           "part": 100,
//           "fromTokenAddress": "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
//           "toTokenAddress": "0x7d1afa7b718fb893db30a3abc0cfc608aacfebb0"
//         }
//       ]
//     ]
//   ],
//   "tx": {
//     "from": "0xB6631E52E513eEE0b8c932d7c76F8ccfA607a28e",
//     "to": "0x1111111254eeb25477b68fb85ed929f73a960582",
//     "data": "0x0502b1c500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005f5e10000000000000000000000000000000000000000000000000000000025cb40772d0000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000180000000000000003b6d0340819f3450da6f110ba6ea52195b3beafa246062decfee7c08",
//     "value": "100000000",
//     "gas": 133099,
//     "gasPrice": "29584025240"
//   }
// }

// {
//   "fromToken": {
//     "symbol": "USDC",
//     "name": "USD Coin",
//     "address": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
//     "decimals": 6,
//     "logoURI": "https://tokens.1inch.io/0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48.png",
//     "eip2612": true,
//     "domainVersion": "2",
//     "tags": [
//       "tokens",
//       "PEG:USD"
//     ]
//   },
//   "toToken": {
//     "symbol": "WETH",
//     "name": "Wrapped Ether",
//     "address": "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
//     "decimals": 18,
//     "logoURI": "https://tokens.1inch.io/0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2.png",
//     "wrappedNative": "true",
//     "tags": [
//       "tokens",
//       "PEG:ETH"
//     ]
//   },
//   "toTokenAmount": "5832780787260795",
//   "fromTokenAmount": "10000000",
//   "protocols": [
//     [
//       [
//         {
//           "name": "LUASWAP",
//           "part": 100,
//           "fromTokenAddress": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
//           "toTokenAddress": "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"
//         }
//       ]
//     ]
//   ],
//   "tx": {
//     "from": "0xB6631E52E513eEE0b8c932d7c76F8ccfA607a28e",
//     "to": "0x1111111254eeb25477b68fb85ed929f73a960582",
//     "data": "0x0502b1c5000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000000000000000000000000000000000000000989680000000000000000000000000000000000000000000000000001483d59a9bcf1b0000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000100000000000000003b5dc1003926a168c11a816e10c13977f75f488bfffe88e4cfee7c08",
//     "value": "0",
//     "gas": 157684,
//     "gasPrice": "30694393265"
//   }
// }
