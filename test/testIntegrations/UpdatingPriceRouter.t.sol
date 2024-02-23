// // SPDX-License-Identifier: Apache-2.0
// pragma solidity 0.8.21;

// import { TickMath } from "@uniswapV3C/libraries/TickMath.sol";
// import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
// import { PoolAddress } from "@uniswapV3P/libraries/PoolAddress.sol";
// import { IUniswapV3Factory } from "@uniswapV3C/interfaces/IUniswapV3Factory.sol";
// import { IUniswapV3Pool } from "@uniswapV3C/interfaces/IUniswapV3Pool.sol";
// import { INonfungiblePositionManager } from "@uniswapV3P/interfaces/INonfungiblePositionManager.sol";
// import "@uniswapV3C/libraries/FixedPoint128.sol";
// import "@uniswapV3C/libraries/FullMath.sol";
// import { Address } from "@openzeppelin/contracts/utils/Address.sol";
// import { ERC721Holder } from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

// // Import Everything from Starter file.
// import "test/resources/MainnetStarter.t.sol";

// import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";

// // Will test the swapping and fund position management using adaptors
// contract UpdatingPriceRouterTest is MainnetStarterTest, AdaptorHelperFunctions, ERC721Holder {
//     using SafeTransferLib for ERC20;
//     using Math for uint256;
//     using stdStorage for StdStorage;
//     using Address for address;

//     address[] public funds;

//     function setUp() external {
//         // Setup forked environment.
//         string memory rpcKey = "MAINNET_RPC_URL";
//         uint256 blockNumber = 17737188;
//         _startFork(rpcKey, blockNumber);

//         // TODO: fill with actual addresses
//         registry = Registry(address(0)); // TODO: here
//         priceRouter = new PriceRouter(address(this), registry, WETH);

//         funds = new address[](0);
//         // funds[0] = address(0); // TODO: here
//     }

//     function testUpdatingPriceRouter() external {
//         vm.prank(multisig);
//         registry.setAddress(2, address(priceRouter));

//         for (uint256 i; i < funds.length; ++i) {
//             Fund fund = Fund(funds[i]);
//             ERC20 asset = fund.asset();
//             uint256 amount = 10 ** asset.decimals();
//             deal(address(asset), address(this), amount);
//             asset.safeApprove(address(fund), amount);
//             fund.deposit(amount, address(this));
//             assertTrue(address(fund.priceRouter()) != address(priceRouter), "PriceRouters should be different");
//         }
//     }
// }
