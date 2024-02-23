// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";

import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";

contract ERC20AdaptorTest is MainnetStarterTest, AdaptorHelperFunctions {
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using stdStorage for StdStorage;
    using Address for address;

    Fund private fund;

    uint32 private usdcPosition = 1;
    uint32 private wethPosition = 2;

    uint256 initialAssets;

    function setUp() external {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 16921343;
        _startFork(rpcKey, blockNumber);

        // Run Starter setUp code.
        _setUp();

        PriceRouter.ChainlinkDerivativeStorage memory stor;

        PriceRouter.AssetSettings memory settings;

        uint256 price = uint256(IChainlinkAggregator(WETH_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, WETH_USD_FEED);
        priceRouter.addAsset(WETH, settings, abi.encode(stor), price);

        price = uint256(IChainlinkAggregator(USDC_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, USDC_USD_FEED);
        priceRouter.addAsset(USDC, settings, abi.encode(stor), price);

        // Setup Fund:

        registry.trustPosition(usdcPosition, address(erc20Adaptor), abi.encode(USDC));
        registry.trustPosition(wethPosition, address(erc20Adaptor), abi.encode(WETH));

        string memory fundName = "ERC20 Fund V0.0";
        uint256 initialDeposit = 1e6;

        fund = _createFund(fundName, USDC, usdcPosition, abi.encode(true), initialDeposit);

        fund.addPositionToCatalogue(wethPosition);

        fund.setRebalanceDeviation(0.01e18);

        USDC.safeApprove(address(fund), type(uint256).max);

        initialAssets = fund.totalAssets();
    }

    function testLogic(uint256 assets, uint256 illiquidMultiplier) external {
        assets = bound(assets, 1e6, 1_000_000e6);
        illiquidMultiplier = bound(illiquidMultiplier, 0, 1e18); // The percent of assets that are illiquid in the fund.

        // USDC is liquid, but WETH is not liquid.
        fund.addPosition(1, wethPosition, abi.encode(false), false);

        // Have user deposit into fund.
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        uint256 totalAssets = fund.totalAssets();
        assertEq(totalAssets, assets + initialAssets, "All assets should be accounted for.");
        // All assets should be liquid.
        uint256 liquidAssets = fund.totalAssetsWithdrawable();
        assertEq(liquidAssets, totalAssets, "All assets should be liquid.");

        // Simulate a strategist rebalance into WETH.
        uint256 assetsIlliquid = assets.mulDivDown(illiquidMultiplier, 1e18);
        uint256 assetsInWeth = priceRouter.getValue(USDC, assetsIlliquid, WETH);
        deal(address(USDC), address(fund), totalAssets - assetsIlliquid);
        deal(address(WETH), address(fund), assetsInWeth);

        totalAssets = fund.totalAssets();
        assertApproxEqAbs(totalAssets, assets + initialAssets, 1, "Total assets should be the same.");

        liquidAssets = fund.totalAssetsWithdrawable();
        assertApproxEqAbs(liquidAssets, totalAssets - assetsIlliquid, 1, "Fund should only be partially liquid.");

        // If for some reason a fund tried to pull from the illiquid position it would revert.
        bytes memory data = abi.encodeWithSelector(
            ERC20Adaptor.withdraw.selector,
            1,
            address(this),
            abi.encode(WETH),
            abi.encode(false)
        );

        vm.startPrank(address(fund));
        vm.expectRevert(bytes(abi.encodeWithSelector(BaseAdaptor.BaseAdaptor__UserWithdrawsNotAllowed.selector)));
        address(erc20Adaptor).functionDelegateCall(data);
        vm.stopPrank();
    }
}
