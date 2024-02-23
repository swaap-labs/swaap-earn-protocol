// // SPDX-License-Identifier: Apache-2.0
// pragma solidity 0.8.21;

// import { Fund, ERC4626 } from "src/base/Fund.sol";
// import { MockDataFeed } from "src/mocks/MockDataFeed.sol";
// import { SwaapFundAdaptor } from "src/modules/adaptors/Swaap/SwaapFundAdaptor.sol";

// // Import Everything from Starter file.
// import "test/resources/MainnetStarter.t.sol";

// import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";

// // Will test the swapping and fund position management using adaptors
// contract UsingSwaapFundAdaptorForSFraxTest is MainnetStarterTest, AdaptorHelperFunctions {
//     using SafeTransferLib for ERC20;

//     MockDataFeed private fraxMockFeed;

//     Fund public fund;
//     SwaapFundAdaptor public swaapFundAdaptor;

//     uint32 fraxPosition = 1;
//     uint32 sFraxPosition = 2;

//     uint256 originalTotalAssets;

//     function setUp() external {
//         // Setup forked environment.
//         string memory rpcKey = "MAINNET_RPC_URL";
//         uint256 blockNumber = 18406923;
//         _startFork(rpcKey, blockNumber);

//         // Run Starter setUp code.
//         _setUp();

//         fraxMockFeed = new MockDataFeed(FRAX_USD_FEED);

//         PriceRouter.ChainlinkDerivativeStorage memory stor;

//         PriceRouter.AssetSettings memory settings;

//         uint256 price = uint256(IChainlinkAggregator(WETH_USD_FEED).latestAnswer());
//         settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, WETH_USD_FEED);
//         priceRouter.addAsset(WETH, settings, abi.encode(stor), price);

//         price = uint256(IChainlinkAggregator(address(fraxMockFeed)).latestAnswer());
//         settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, address(fraxMockFeed));
//         priceRouter.addAsset(FRAX, settings, abi.encode(stor), price);

//         swaapFundAdaptor = new SwaapFundAdaptor();

//         registry.trustAdaptor(address(swaapFundAdaptor));

//         registry.trustPosition(fraxPosition, address(erc20Adaptor), abi.encode(FRAX));
//         registry.trustPosition(sFraxPosition, address(swaapFundAdaptor), abi.encode(sFRAX));

//         bytes memory creationCode = type(Fund).creationCode;
//         bytes memory constructorArgs = abi.encode(
//             address(this),
//             registry,
//             FRAX,
//             "Test sFRAX Fund",
//             "TSFC",
//             fraxPosition,
//             abi.encode(0),
//             1e18,
//             type(uint192).max
//         );
//         fund = Fund(deployer.getAddress("Test Fund"));
//         FRAX.safeApprove(address(fund), 1e18);
//         deal(address(FRAX), address(this), 1e18);
//         deployer.deployContract("Test Fund", creationCode, constructorArgs, 0);

//         fund.addAdaptorToCatalogue(address(swaapFundAdaptor));
//         fund.addPositionToCatalogue(sFraxPosition);
//         fund.addPosition(0, sFraxPosition, abi.encode(true), false);

//         originalTotalAssets = fund.totalAssets();
//     }

//     function testSFraxUse(uint256 assets) external {
//         assets = bound(assets, 1e18, 1_000_000_000e18);

//         // User deposits.
//         deal(address(FRAX), address(this), assets);
//         FRAX.safeApprove(address(fund), assets);
//         fund.deposit(assets, address(this));

//         // Strategist moves assets into sFrax, and makes sFrax the holding position.
//         {
//             Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
//             bytes[] memory adaptorCalls = new bytes[](1);
//             adaptorCalls[0] = _createBytesDataToDepositToFund(address(sFRAX), assets);
//             data[0] = Fund.AdaptorCall({ adaptor: address(swaapFundAdaptor), callData: adaptorCalls });
//             fund.callOnAdaptor(data);
//         }
//         fund.setHoldingPosition(sFraxPosition);

//         // Check that we deposited into sFRAX.
//         uint256 fundsFraxWorth = ERC4626(sFRAX).maxWithdraw(address(fund));
//         assertApproxEqAbs(fundsFraxWorth, assets, 1, "Should have deposited assets into sFRAX.");

//         skip(100 days);
//         fraxMockFeed.setMockUpdatedAt(block.timestamp);

//         assertGt(
//             fund.totalAssets(),
//             originalTotalAssets + assets,
//             "Fund totalAssets should have increased from sFRAX yield."
//         );

//         // Have user withdraw to make sure we can withdraw from sFRAX.
//         uint256 maxWithdraw = fund.maxWithdraw(address(this));
//         fund.withdraw(maxWithdraw, address(this), address(this));

//         assertEq(FRAX.balanceOf(address(this)), maxWithdraw, "Assets withdrawn should equal expected.");

//         // Make sure we pulled from sFRAX.
//         uint256 newFundsFraxWorth = ERC4626(sFRAX).maxWithdraw(address(fund));
//         assertLt(newFundsFraxWorth, fundsFraxWorth, "Should have pulled assets from sFRAX.");

//         // Make sure users deposit go into sFRAX.
//         FRAX.safeApprove(address(fund), assets);
//         fund.deposit(assets, address(this));

//         uint256 expectedAssets = newFundsFraxWorth + assets;
//         fundsFraxWorth = ERC4626(sFRAX).maxWithdraw(address(fund));
//         assertApproxEqAbs(fundsFraxWorth, expectedAssets, 1, "Should have deposited assets into sFRAX.");

//         // Make sure strategist can rebalance assets out of sFRAX.
//         {
//             Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
//             bytes[] memory adaptorCalls = new bytes[](1);
//             adaptorCalls[0] = _createBytesDataToWithdrawFromFund(sFRAX, type(uint256).max);
//             data[0] = Fund.AdaptorCall({ adaptor: address(swaapFundAdaptor), callData: adaptorCalls });
//             fund.callOnAdaptor(data);
//         }

//         assertEq(0, ERC20(sFRAX).balanceOf(address(fund)), "Should have withdrawn all assets from sFRAX.");
//     }
// }
