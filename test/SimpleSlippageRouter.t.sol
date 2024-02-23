// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ReentrancyERC4626 } from "src/mocks/ReentrancyERC4626.sol";
import { SwaapFundAdaptor } from "src/modules/adaptors/Swaap/SwaapFundAdaptor.sol";
import { ERC20DebtAdaptor } from "src/mocks/ERC20DebtAdaptor.sol";
import { MockDataFeed } from "src/mocks/MockDataFeed.sol";
import { SimpleSlippageRouter } from "src/modules/SimpleSlippageRouter.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";
import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";

contract SimpleSlippageRouterTest is MainnetStarterTest, AdaptorHelperFunctions {
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using stdStorage for StdStorage;

    Fund private fund;

    SimpleSlippageRouter private simpleSlippageRouter;

    MockDataFeed private mockUsdcUsd;

    uint32 private usdcPosition = 1;

    uint256 private initialAssets;
    uint256 private initialShares;

    // vars used to check within tests
    uint256 deposit1;
    uint256 minShares1;
    uint64 deadline1;
    uint256 shareBalance1;
    uint256 deposit2;
    uint256 minShares2;
    uint64 deadline2;
    uint256 shareBalance2;

    uint256 assetToSharesDecimalsFactor = 10 ** 12;

    function setUp() external {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 16869780;
        _startFork(rpcKey, blockNumber);

        // Run Starter setUp code.
        // Get a fund w/ usdc holding position, deploy a SlippageRouter to work with it.
        _setUp();

        mockUsdcUsd = new MockDataFeed(USDC_USD_FEED);
        simpleSlippageRouter = new SimpleSlippageRouter();

        // Setup pricing
        PriceRouter.ChainlinkDerivativeStorage memory stor;

        PriceRouter.AssetSettings memory settings;

        uint256 price = uint256(mockUsdcUsd.latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, address(mockUsdcUsd));
        priceRouter.addAsset(USDC, settings, abi.encode(stor), price);

        // Add adaptors and ERC20 positions to the registry.
        registry.trustPosition(usdcPosition, address(erc20Adaptor), abi.encode(USDC));

        // Create Dummy Funds.
        string memory fundName = "Dummy Fund V0.0";
        uint256 initialDeposit = 1e6;

        fundName = "Fund V0.0";
        initialDeposit = 1e6;

        fund = _createFund(fundName, USDC, usdcPosition, abi.encode(true), initialDeposit);

        vm.label(address(fund), "fund");

        // Approve fund to spend all assets.
        USDC.approve(address(fund), type(uint256).max);
        USDC.approve(address(simpleSlippageRouter), type(uint256).max);

        initialAssets = fund.totalAssets();
        initialShares = fund.totalSupply();
    }

    // ========================================= HAPPY PATH TEST =========================================

    // deposit() using SSR, deposit again using SSR. See that appropriate amount of funds were deposited.
    function testDeposit(uint256 assets) external {
        assets = bound(assets, 1e6, 100_000e6);

        deal(address(USDC), address(this), assets);
        deposit1 = assets / 2;
        minShares1 = deposit1 * assetToSharesDecimalsFactor;
        deadline1 = uint64(block.timestamp + 1 days);

        // deposit half using the SSR
        simpleSlippageRouter.deposit(fund, deposit1, minShares1, deadline1);

        shareBalance1 = fund.balanceOf(address(this));

        assertEq(shareBalance1, minShares1);
        assertEq(USDC.balanceOf(address(this)), assets - deposit1);

        // deposit the other half using the SSR
        simpleSlippageRouter.deposit(fund, deposit1, minShares1, deadline1);

        shareBalance2 = fund.balanceOf(address(this));

        assertApproxEqAbs(
            shareBalance2 / assetToSharesDecimalsFactor,
            assets,
            2,
            "deposit(): Test contract USDC should be all shares"
        );
        assertApproxEqAbs(USDC.balanceOf(address(this)), 0, 2, "deposit(): All USDC deposited to Fund");

        // check allowance SSR given to fund is zeroed out
        ERC20 fundERC20 = ERC20(address(fund));
        assertEq(
            fundERC20.allowance(address(simpleSlippageRouter), address(fund)),
            0,
            "fund's approval to spend SSR fundToken should be zeroed out."
        );
    }

    function testWithdraw(uint256 assets) external {
        assets = bound(assets, 1e6, type(uint80).max);

        // deal USDC assets to test contract
        deal(address(USDC), address(this), assets);
        deposit1 = assets / 2;
        minShares1 = deposit1 * assetToSharesDecimalsFactor;
        deadline1 = uint64(block.timestamp + 1 days);
        // deposit half using the SSR
        simpleSlippageRouter.deposit(fund, deposit1, minShares1, deadline1);

        // withdraw a quarter using the SSR
        uint256 withdraw1 = assets / 4;
        uint256 maxShares1 = withdraw1 * assetToSharesDecimalsFactor; // assume 1:1 USDC:Shares shareprice (modulo the decimals diff)
        fund.approve(address(simpleSlippageRouter), maxShares1);
        simpleSlippageRouter.withdraw(fund, withdraw1, maxShares1, deadline1);

        shareBalance1 = fund.balanceOf(address(this));

        assertApproxEqAbs(
            shareBalance1 / assetToSharesDecimalsFactor,
            (assets / 2) - withdraw1,
            2,
            "withdraw(): Test contract should have redeemed half of its shares"
        );
        assertApproxEqAbs(
            USDC.balanceOf(address(this)),
            (assets / 2) + withdraw1,
            2,
            "withdraw(): Should have withdrawn expected partial amount"
        );

        // withdraw the rest using the SSR
        uint256 maxShares2 = fund.balanceOf(address(this));
        uint256 withdraw2 = maxShares2 / assetToSharesDecimalsFactor; // assume 1:1 USDC:Shares shareprice (modulo the decimals diff)
        fund.approve(address(simpleSlippageRouter), type(uint256).max);

        simpleSlippageRouter.withdraw(fund, withdraw2, maxShares2, deadline1);

        shareBalance2 = fund.balanceOf(address(this));

        assertApproxEqAbs(shareBalance2, 0, 2, "withdraw(): Test contract should have redeemed all of its shares");
        assertApproxEqAbs(
            USDC.balanceOf(address(this)),
            assets,
            2,
            "withdraw(): Should have withdrawn expected entire USDC amount"
        );
    }

    function testMint(uint256 assets) external {
        assets = bound(assets, 1e6, 100_000e6);

        // deal USDC assets to test contract
        deal(address(USDC), address(this), assets);
        deposit1 = assets / 2;
        minShares1 = deposit1 * assetToSharesDecimalsFactor;
        deadline1 = uint64(block.timestamp + 1 days);

        // mint with half of the assets using the SSR
        simpleSlippageRouter.mint(fund, minShares1, deposit1, deadline1);

        shareBalance1 = fund.balanceOf(address(this));

        assertEq(shareBalance1, minShares1);
        assertEq(USDC.balanceOf(address(this)), assets - deposit1);

        // mint using the other half using the SSR
        simpleSlippageRouter.mint(fund, minShares1, deposit1, deadline1);

        shareBalance2 = fund.balanceOf(address(this));

        assertApproxEqAbs(
            shareBalance2 / assetToSharesDecimalsFactor,
            assets,
            2,
            "mint(): Test contract USDC should be all shares"
        );
        assertApproxEqAbs(USDC.balanceOf(address(this)), 0, 2, "mint(): All USDC deposited to Fund");

        // check allowance SSR given to fund is zeroed out
        ERC20 fundERC20 = ERC20(address(fund));
        assertEq(
            fundERC20.allowance(address(simpleSlippageRouter), address(fund)),
            0,
            "fund's approval to spend SSR fundToken should be zeroed out."
        );
    }

    function testRedeem(uint256 assets) external {
        assets = bound(assets, 1e6, 100_000e6);

        // deal USDC assets to test contract
        deal(address(USDC), address(this), assets);
        deposit1 = assets / 2;
        minShares1 = deposit1 * assetToSharesDecimalsFactor;
        deadline1 = uint64(block.timestamp + 1 days);
        // deposit half using the SSR
        simpleSlippageRouter.deposit(fund, deposit1, minShares1, deadline1);

        // redeem half of the shares test contract has using the SSR
        uint256 minAssets1 = deposit1 / 2;
        uint256 redeem1 = minAssets1 * assetToSharesDecimalsFactor; // assume 1:1 USDC:Shares shareprice (modulo the decimals diff)
        fund.approve(address(simpleSlippageRouter), redeem1);

        simpleSlippageRouter.redeem(fund, redeem1, minAssets1, deadline1);

        shareBalance1 = fund.balanceOf(address(this));

        assertApproxEqAbs(
            shareBalance1 / assetToSharesDecimalsFactor,
            (assets / 2) - minAssets1,
            2,
            "redeem(): Test contract should have redeemed half of its shares"
        );
        assertApproxEqAbs(
            USDC.balanceOf(address(this)),
            (assets / 2) + minAssets1,
            2,
            "redeem(): Should have withdrawn expected partial amount"
        );

        // redeem the rest using the SSR
        uint256 redeem2 = fund.balanceOf(address(this));
        uint256 minAsets2 = redeem2 / assetToSharesDecimalsFactor; // assume 1:1 USDC:Shares shareprice (modulo the decimals diff)
        fund.approve(address(simpleSlippageRouter), redeem2);

        simpleSlippageRouter.redeem(fund, redeem2, minAsets2, deadline1);

        shareBalance2 = fund.balanceOf(address(this));

        assertApproxEqAbs(shareBalance2, 0, 2, "redeem(): Test contract should have redeemed all of its shares");
        assertApproxEqAbs(
            USDC.balanceOf(address(this)),
            assets,
            2,
            "redeem(): Should have withdrawn expected entire USDC amount"
        );
    }

    // ========================================= REVERSION TEST =========================================

    // For revert tests, check that reversion occurs and then resolve it showing a passing tx.

    function testBadDeadline(uint256 assets) external {
        // test revert in all functions
        assets = bound(assets, 1e6, 100_000e6);

        // deal USDC assets to test contract
        deal(address(USDC), address(this), assets);
        deposit1 = assets / 2;
        minShares1 = deposit1;
        deadline1 = uint64(block.timestamp + 1 days);
        skip(2 days);
        mockUsdcUsd.setMockUpdatedAt(block.timestamp);

        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(SimpleSlippageRouter.SimpleSlippageRouter__ExpiredDeadline.selector, deadline1)
            )
        );
        simpleSlippageRouter.deposit(fund, deposit1, minShares1, deadline1);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(SimpleSlippageRouter.SimpleSlippageRouter__ExpiredDeadline.selector, deadline1)
            )
        );
        simpleSlippageRouter.withdraw(fund, deposit1, minShares1, deadline1);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(SimpleSlippageRouter.SimpleSlippageRouter__ExpiredDeadline.selector, deadline1)
            )
        );
        simpleSlippageRouter.mint(fund, minShares1, deposit1, deadline1);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(SimpleSlippageRouter.SimpleSlippageRouter__ExpiredDeadline.selector, deadline1)
            )
        );
        simpleSlippageRouter.redeem(fund, minShares1, deposit1, deadline1);
    }

    function testDepositMinimumSharesUnmet(uint256 assets) external {
        // test revert in deposit()
        assets = bound(assets, 1e6, 100_000e6);

        // deal USDC assets to test contract
        deal(address(USDC), address(this), assets);
        deposit1 = assets;
        minShares1 = (assets + 1) * assetToSharesDecimalsFactor; // input param so it will revert
        deadline1 = uint64(block.timestamp + 1 days);

        uint256 quoteShares = fund.previewDeposit(assets);

        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    SimpleSlippageRouter.SimpleSlippageRouter__DepositMinimumSharesUnmet.selector,
                    minShares1,
                    quoteShares
                )
            )
        );
        simpleSlippageRouter.deposit(fund, deposit1, minShares1, deadline1);

        // manipulate back so the deposit should resolve.
        minShares1 = assets;
        simpleSlippageRouter.deposit(fund, deposit1, minShares1, deadline1);
    }

    function testWithdrawMaxSharesSurpassed(uint256 assets) external {
        assets = bound(assets, 1e6, 100_000e6);

        // deal USDC assets to test contract
        deal(address(USDC), address(this), assets);
        deposit1 = assets / 2;
        minShares1 = deposit1 * assetToSharesDecimalsFactor;
        deadline1 = uint64(block.timestamp + 1 days);
        // deposit half using the SSR
        simpleSlippageRouter.deposit(fund, deposit1, minShares1, deadline1);

        // withdraw a quarter using the SSR
        uint256 withdraw1 = deposit1 / 2;
        uint256 maxShares1 = withdraw1 * assetToSharesDecimalsFactor; // assume 1:1 USDC:Shares shareprice (modulo the decimals diff)
        fund.approve(address(simpleSlippageRouter), maxShares1);

        uint256 quoteShares = fund.previewWithdraw(withdraw1);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    SimpleSlippageRouter.SimpleSlippageRouter__WithdrawMaxSharesSurpassed.selector,
                    maxShares1 - 1,
                    quoteShares
                )
            )
        );
        simpleSlippageRouter.withdraw(fund, withdraw1, maxShares1 - 1, deadline1);

        // Use a value for maxShare that will pass the conditional logic
        simpleSlippageRouter.withdraw(fund, withdraw1, maxShares1, deadline1);
    }

    function testMintMaxAssetsRqdSurpassed(uint256 assets) external {
        // test revert in mint()
        assets = bound(assets, 1e6, 100_000e6);

        // deal USDC assets to test contract
        deal(address(USDC), address(this), assets);
        deposit1 = assets / 2;
        minShares1 = deposit1 * assetToSharesDecimalsFactor;
        deadline1 = uint64(block.timestamp + 1 days);

        // manipulate fund to have lots of USDC and thus not a 1:1 ratio anymore for shares
        uint256 originalBalance = USDC.balanceOf(address(fund));
        deal(address(USDC), address(fund), assets * 10);
        uint256 quotedAssetAmount = fund.previewMint(minShares1);

        // mint with half of the assets using the SSR
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    SimpleSlippageRouter.SimpleSlippageRouter__MintMaxAssetsRqdSurpassed.selector,
                    minShares1,
                    deposit1,
                    quotedAssetAmount
                )
            )
        );
        simpleSlippageRouter.mint(fund, minShares1, deposit1, deadline1);

        // manipulate back so the mint should resolve.
        deal(address(USDC), address(fund), originalBalance);
        simpleSlippageRouter.mint(fund, minShares1, deposit1, deadline1);
    }

    function testRedeemMinAssetsUnmet(uint256 assets) external {
        // test revert in redeem()
        assets = bound(assets, 1e6, 100_000e6);
        uint192 assetsToShares = uint192(fund.totalSupply() / fund.totalAssets());

        // deal USDC assets to test contract
        deal(address(USDC), address(this), assets);
        deposit1 = assets / 2;
        minShares1 = deposit1 * assetsToShares;
        deadline1 = uint64(block.timestamp + 1 days);
        // deposit half using the SSR
        uint256 receivedShares = fund.balanceOf(address(this));
        simpleSlippageRouter.deposit(fund, deposit1, minShares1, deadline1);
        receivedShares = fund.balanceOf(address(this)) - receivedShares;

        assertEq(
            receivedShares,
            deposit1 * assetsToShares,
            "deposit(): Test contract should have received expected shares"
        );

        // redeem half of the shares test contract has using the SSR
        uint256 maxShares1 = receivedShares / 2;
        uint256 withdrawAssets1 = maxShares1 / assetsToShares;

        fund.approve(address(simpleSlippageRouter), maxShares1);
        uint256 quotedAssetAmount = fund.previewRedeem(maxShares1);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    SimpleSlippageRouter.SimpleSlippageRouter__RedeemMinAssetsUnmet.selector,
                    maxShares1,
                    withdrawAssets1 + 1,
                    quotedAssetAmount
                )
            )
        );
        simpleSlippageRouter.redeem(fund, maxShares1, withdrawAssets1 + 1, deadline1);

        // Use a value for withdraw1 that will pass the conditional logic.
        simpleSlippageRouter.redeem(fund, maxShares1, withdrawAssets1, deadline1);
    }
}
