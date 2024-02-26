// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { IRETH } from "src/interfaces/external/IRETH.sol";
import { ICBETH } from "src/interfaces/external/ICBETH.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { UniswapV3Pool } from "src/interfaces/external/UniswapV3Pool.sol";
import { IBasePool } from "@balancer/interfaces/contracts/vault/IBasePool.sol";
import { IBalancerPool } from "src/interfaces/external/IBalancerPool.sol";

import { SwaapSafeguardPoolExtension } from "src/modules/price-router/Extensions/Swaap/SwaapSafeguardPoolExtension.sol";
import { WstEthExtension } from "src/modules/price-router/Extensions/Lido/WstEthExtension.sol";

import { IVault, IAsset, IERC20 } from "@balancer/interfaces/contracts/vault/IVault.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";

import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";
import { MockDataFeed } from "src/mocks/MockDataFeed.sol";

contract SwaapSafeguarPoolTest is MainnetStarterTest, AdaptorHelperFunctions {
    using Math for uint256;
    // using stdStorage for StdStorage;
    using Address for address;

    SwaapSafeguardPoolExtension private swaapSafeguardPoolExtension;
    uint256 public expectedWETH_USDC_SPTPrice;

    MockDataFeed private mockUsdcUsd;
    MockDataFeed private mockWethUsd;

    function setUp() external {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 19035690;

        _startFork(rpcKey, blockNumber);

        // Run Starter setUp code.
        _setUp();

        // expected price of WETH_USDC_SPT @ forked block
        expectedWETH_USDC_SPTPrice = 0.2328e8;

        // Deploy Required Extensions.
        swaapSafeguardPoolExtension = new SwaapSafeguardPoolExtension(priceRouter, IVault(swaapV2Vault));

        // creating mock oracles to skip time for tests
        // Setup pricing
        mockUsdcUsd = new MockDataFeed(USDC_USD_FEED);
        mockWethUsd = new MockDataFeed(WETH_USD_FEED);
    }

    // ======================================= HAPPY PATH =======================================

    function testPricingUSDC_WETH_SPT(uint256 joinExitValue) external {
        joinExitValue = bound(joinExitValue, 1e6, 1_000_000e8); // 0.01$ - 1,000,000$
        // Add required pricing.
        _addChainlinkAsset(USDC, USDC_USD_FEED, false);
        _addChainlinkAsset(WETH, WETH_USD_FEED, false);

        PriceRouter.AssetSettings memory settings;

        settings = PriceRouter.AssetSettings(EXTENSION_DERIVATIVE, address(swaapSafeguardPoolExtension));
        priceRouter.addAsset(USDC_WETH_SPT, settings, abi.encode(), expectedWETH_USDC_SPTPrice);

        uint256 sptPrice = priceRouter.getPriceInUSD(USDC_WETH_SPT);

        uint256 sptAmount = (joinExitValue * 10 ** 18) / sptPrice;

        ERC20[] memory underlyings = new ERC20[](2);
        underlyings[0] = USDC;
        underlyings[1] = WETH;

        uint256[] memory joinAmounts = _joinPool(IBasePool(address(USDC_WETH_SPT)), underlyings, sptAmount);

        uint256 valueIn = _totalValueInUSD(underlyings, joinAmounts);

        uint256[] memory exitAmounts = _exitPool(IBasePool(address(USDC_WETH_SPT)), underlyings, sptAmount);

        uint256 valueOut = _totalValueInUSD(underlyings, exitAmounts);

        assertApproxEqRel(joinExitValue, valueIn, 0.001e18, "Target value should approximately equal to value in.");
        assertApproxEqRel(joinExitValue, valueOut, 0.001e18, "Value out should approximately equal value in.");
    }

    // ======================================= REVERTS =======================================

    function testPricingSafeguardPoolWithUnsupportedPool() external {
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    SwaapSafeguardPoolExtension.SwaapSafeguardPoolExtension__PoolNotRegistered.selector
                )
            )
        );
        swaapSafeguardPoolExtension.getPriceInUSD(USDC_WETH_SPT);
    }

    function testPoolPricingWithManagementFees(uint256 yearlyFees) external {
        yearlyFees = bound(yearlyFees, 0.1e16, 5e16); // 0.1% - 5%
        // Add required pricing.
        _addChainlinkAsset(USDC, address(mockUsdcUsd), false);
        _addChainlinkAsset(WETH, address(mockWethUsd), false);

        PriceRouter.AssetSettings memory settings;

        settings = PriceRouter.AssetSettings(EXTENSION_DERIVATIVE, address(swaapSafeguardPoolExtension));
        priceRouter.addAsset(USDC_WETH_SPT, settings, abi.encode(), expectedWETH_USDC_SPTPrice);

        uint256 sptPriceWithNoFees = priceRouter.getPriceInUSD(USDC_WETH_SPT);

        // set fees
        // USDC_WETH_SPT setAllowlist setter
        vm.prank(0x327d92816eCb1E54cb7F41cf498c0387E81baA1d);
        (bool success, ) = address(USDC_WETH_SPT).call(abi.encodeWithSelector(0x6484e410, yearlyFees)); // set management fees
        require(success, "failed to set management fees in the pool");

        // skip 8 months (can be any amount of time)
        uint256 skipTime1 = 8 * 30 days;
        _moveForwardAndUpdateOracle(skipTime1);

        uint256 calcSptPriceAfterFees = priceRouter.getPriceInUSD(USDC_WETH_SPT);
        
        (success, ) = address(USDC_WETH_SPT).call(abi.encodeWithSelector(0x5c91bba0)); // collect fees
        require(success, "failed to collect management fees in the pool");

        uint256 realSptPriceAfterFees = priceRouter.getPriceInUSD(USDC_WETH_SPT);

        assertApproxEqRel(
            calcSptPriceAfterFees,
            realSptPriceAfterFees,
            0.0001e18,
            "SPT price should accounted after 8 months of accumulated fees."
        );

        // skip the rest of the year
        uint256 skipTime2 = (12 * 30 days) - skipTime1;
        _moveForwardAndUpdateOracle(skipTime2);

        calcSptPriceAfterFees = priceRouter.getPriceInUSD(USDC_WETH_SPT);

        (success, ) = address(USDC_WETH_SPT).call(abi.encodeWithSelector(0x5c91bba0)); // collect fees
        require(success, "failed to collect management fees in the pool");

        realSptPriceAfterFees = priceRouter.getPriceInUSD(USDC_WETH_SPT);

        assertApproxEqRel(
            calcSptPriceAfterFees,
            realSptPriceAfterFees,
            0.0001e18,
            "SPT price should accounted after 4 months of accumulated fees."
        );

        console.log(sptPriceWithNoFees);

        assertApproxEqRel(
            realSptPriceAfterFees,
            (sptPriceWithNoFees * (1e18 - yearlyFees)) / 1e18,
            0.001e18,
            "SPT price should be correct after 1 year of accumulated fees."
        );
    }

    // ======================================= HELPER FUNCTIONS =======================================

    enum SafeguardJoinKind {
        INIT,
        ALL_TOKENS_IN_FOR_EXACT_BPT_OUT,
        EXACT_TOKENS_IN_FOR_BPT_OUT
    }
    enum SafeguardExitKind {
        EXACT_BPT_IN_FOR_TOKENS_OUT,
        BPT_IN_FOR_EXACT_TOKENS_OUT
    }

    function _joinPool(
        IBasePool pool,
        ERC20[] memory tokens,
        uint256 sptAmountOut
    ) internal returns (uint256[] memory amountsIn) {
        uint256 lengthToUse = tokens.length;
        IAsset[] memory assets = new IAsset[](lengthToUse);
        uint256[] memory maxAmounts = new uint256[](lengthToUse);
        uint256[] memory joinAmounts = new uint256[](lengthToUse);
        uint256[] memory balancesBefore = new uint256[](lengthToUse);

        for (uint256 i; i < lengthToUse; ++i) {
            assets[i] = IAsset(address(tokens[i]));
            deal(address(tokens[i]), address(this), type(uint256).max / 10);
            ERC20(tokens[i]).approve(swaapV2Vault, type(uint256).max);
            maxAmounts[i] = type(uint256).max;
            balancesBefore[i] = tokens[i].balanceOf(address(this));
        }

        bytes memory userData = abi.encode(SafeguardJoinKind.ALL_TOKENS_IN_FOR_EXACT_BPT_OUT, sptAmountOut);

        uint256 totalSupplyBefore = ERC20(address(pool)).balanceOf(address(this));

        IVault(swaapV2Vault).joinPool(
            pool.getPoolId(),
            address(this),
            address(this),
            IVault.JoinPoolRequest(assets, maxAmounts, userData, false)
        );

        for (uint256 i; i < lengthToUse; ++i) {
            joinAmounts[i] = balancesBefore[i] - tokens[i].balanceOf(address(this));
        }

        // assert that the sptAmountOut is correct.
        assertEq(ERC20(address(pool)).balanceOf(address(this)) - totalSupplyBefore, sptAmountOut);

        return joinAmounts;
    }

    function _exitPool(
        IBasePool pool,
        ERC20[] memory tokens,
        uint256 sptAmountIn
    ) internal returns (uint256[] memory amountsOut) {
        uint256 lengthToUse = tokens.length;
        IAsset[] memory assets = new IAsset[](lengthToUse);
        uint256[] memory minAmounts = new uint256[](lengthToUse);
        uint256[] memory exitAmounts = new uint256[](lengthToUse);
        uint256[] memory balancesBefore = new uint256[](lengthToUse);

        for (uint256 i; i < lengthToUse; ++i) {
            assets[i] = IAsset(address(tokens[i]));
            balancesBefore[i] = ERC20(tokens[i]).balanceOf(address(this));
        }

        bytes memory userData = abi.encode(SafeguardExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT, sptAmountIn);

        uint256 totalSupplyBefore = ERC20(address(pool)).balanceOf(address(this));

        IVault(swaapV2Vault).exitPool(
            pool.getPoolId(),
            address(this),
            payable(address(this)),
            IVault.ExitPoolRequest(assets, minAmounts, userData, false)
        );

        for (uint256 i; i < lengthToUse; ++i) {
            exitAmounts[i] = tokens[i].balanceOf(address(this)) - balancesBefore[i];
        }

        // assert that the sptAmountOut is correct.
        assertEq(totalSupplyBefore - ERC20(address(pool)).balanceOf(address(this)), sptAmountIn);

        return exitAmounts;
    }

    function _totalValueInUSD(ERC20[] memory tokens, uint256[] memory amounts) internal view returns (uint256) {
        uint256[] memory prices = priceRouter.getPricesInUSD(tokens);

        uint256 valueIn;
        for (uint256 i; i < tokens.length; ++i) {
            valueIn += (prices[i] * amounts[i]) / (10 ** tokens[i].decimals());
        }

        return valueIn;
    }

    function _addChainlinkAsset(ERC20 asset, address priceFeed, bool inEth) internal {
        PriceRouter.ChainlinkDerivativeStorage memory stor;
        PriceRouter.AssetSettings memory settings;
        stor.inETH = inEth;

        uint256 price = uint256(IChainlinkAggregator(priceFeed).latestAnswer());
        if (inEth) {
            price = priceRouter.getValue(WETH, price, USDC);
            price = price.changeDecimals(6, 8);
        }

        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, priceFeed);
        priceRouter.addAsset(asset, settings, abi.encode(stor), price);
    }

    function _moveForwardAndUpdateOracle(uint256 delayTimestamp) internal {
        skip(delayTimestamp);
        mockUsdcUsd.setMockUpdatedAt(block.timestamp);
        mockWethUsd.setMockUpdatedAt(block.timestamp);
    }
}
