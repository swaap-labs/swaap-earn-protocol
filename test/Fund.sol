// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ReentrancyERC4626 } from "src/mocks/ReentrancyERC4626.sol";
import { SwaapFundAdaptor } from "src/modules/adaptors/Swaap/SwaapFundAdaptor.sol";
import { ERC20DebtAdaptor } from "src/mocks/ERC20DebtAdaptor.sol";
import { MockDataFeed } from "src/mocks/MockDataFeed.sol";
import { MockFund } from "src/mocks/MockFund.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";

import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";

contract FundTest is MainnetStarterTest, AdaptorHelperFunctions {
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using stdStorage for StdStorage;

    Fund private fund;
    Fund private usdcCLR;
    Fund private wethCLR;
    Fund private wbtcCLR;

    MockFund private mockFund;

    SwaapFundAdaptor private swaapFundAdaptor;

    MockDataFeed private mockUsdcUsd;
    MockDataFeed private mockWethUsd;
    MockDataFeed private mockWbtcUsd;
    MockDataFeed private mockUsdtUsd;

    uint32 private usdcPosition = 1;
    uint32 private wethPosition = 2;
    uint32 private wbtcPosition = 3;
    uint32 private usdcCLRPosition = 4;
    uint32 private wethCLRPosition = 5;
    uint32 private wbtcCLRPosition = 6;
    uint32 private usdtPosition = 7;

    uint256 private initialAssets;
    uint256 private initialShares;

    uint256 assetToSharesDecimalsFactor = 10 ** 12;

    function setUp() external {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 16869780;
        _startFork(rpcKey, blockNumber);

        // Run Starter setUp code.
        _setUp();

        mockUsdcUsd = new MockDataFeed(USDC_USD_FEED);
        mockWethUsd = new MockDataFeed(WETH_USD_FEED);
        mockWbtcUsd = new MockDataFeed(WBTC_USD_FEED);
        mockUsdtUsd = new MockDataFeed(USDT_USD_FEED);
        swaapFundAdaptor = new SwaapFundAdaptor();

        // Setup pricing
        PriceRouter.ChainlinkDerivativeStorage memory stor;

        PriceRouter.AssetSettings memory settings;

        uint256 price = uint256(mockUsdcUsd.latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, address(mockUsdcUsd));
        priceRouter.addAsset(USDC, settings, abi.encode(stor), price);

        price = uint256(mockWethUsd.latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, address(mockWethUsd));
        priceRouter.addAsset(WETH, settings, abi.encode(stor), price);

        price = uint256(mockWbtcUsd.latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, address(mockWbtcUsd));
        priceRouter.addAsset(WBTC, settings, abi.encode(stor), price);

        price = uint256(mockUsdtUsd.latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, address(mockUsdtUsd));
        priceRouter.addAsset(USDT, settings, abi.encode(stor), price);

        // Setup exchange rates:
        // USDC Simulated Price: $1
        // WETH Simulated Price: $2000
        // WBTC Simulated Price: $30,000
        mockUsdcUsd.setMockAnswer(1e8);
        mockWethUsd.setMockAnswer(2_000e8);
        mockWbtcUsd.setMockAnswer(30_000e8);
        mockUsdtUsd.setMockAnswer(1e8);

        // Add adaptors and ERC20 positions to the registry.
        registry.trustAdaptor(address(swaapFundAdaptor));
        registry.trustPosition(usdcPosition, address(erc20Adaptor), abi.encode(USDC));
        registry.trustPosition(wethPosition, address(erc20Adaptor), abi.encode(WETH));
        registry.trustPosition(wbtcPosition, address(erc20Adaptor), abi.encode(WBTC));
        registry.trustPosition(usdtPosition, address(erc20Adaptor), abi.encode(USDT));

        // Create Dummy Funds.
        string memory fundName = "Dummy Fund V0.0";
        uint256 initialDeposit = 1e6;

        usdcCLR = _createFund(fundName, USDC, usdcPosition, abi.encode(true), initialDeposit);
        vm.label(address(usdcCLR), "usdcCLR");

        fundName = "Dummy Fund V0.1";
        initialDeposit = 1e12;
        wethCLR = _createFund(fundName, WETH, wethPosition, abi.encode(true), initialDeposit);
        vm.label(address(wethCLR), "wethCLR");

        fundName = "Dummy Fund V0.2";
        initialDeposit = 1e4;
        wbtcCLR = _createFund(fundName, WBTC, wbtcPosition, abi.encode(true), initialDeposit);
        vm.label(address(wbtcCLR), "wbtcCLR");

        // Add Fund Positions to the registry.
        registry.trustPosition(usdcCLRPosition, address(swaapFundAdaptor), abi.encode(usdcCLR));
        registry.trustPosition(wethCLRPosition, address(swaapFundAdaptor), abi.encode(wethCLR));
        registry.trustPosition(wbtcCLRPosition, address(swaapFundAdaptor), abi.encode(wbtcCLR));

        fundName = "Fund V0.0";
        initialDeposit = 1e6;
        fund = _createFund(fundName, USDC, usdcPosition, abi.encode(true), initialDeposit);

        // Set up remaining fund positions.
        fund.addPositionToCatalogue(usdcCLRPosition);
        fund.addPosition(1, usdcCLRPosition, abi.encode(true), false);
        fund.addPositionToCatalogue(wethCLRPosition);
        fund.addPosition(2, wethCLRPosition, abi.encode(true), false);
        fund.addPositionToCatalogue(wbtcCLRPosition);
        fund.addPosition(3, wbtcCLRPosition, abi.encode(true), false);
        fund.addPositionToCatalogue(wethPosition);
        fund.addPosition(4, wethPosition, abi.encode(true), false);
        fund.addPositionToCatalogue(wbtcPosition);
        fund.addPosition(5, wbtcPosition, abi.encode(true), false);
        fund.addAdaptorToCatalogue(address(swaapFundAdaptor));
        fund.addPositionToCatalogue(usdtPosition);

        vm.label(address(fund), "fund");
        vm.label(strategist, "strategist");

        // Approve fund to spend all assets.
        USDC.approve(address(fund), type(uint256).max);

        initialAssets = fund.totalAssets();
        initialShares = fund.totalSupply();
    }

    function deployMockFund(
        Registry registry,
        ERC20 holdingAsset,
        string memory mockFundName,
        uint32 holdingPosition,
        uint256 initialDeposit
    ) internal returns (MockFund) {
        // Approve new fund to spend assets.
        address mockFundAddress = deployer.getAddress(mockFundName);
        deal(address(holdingAsset), address(this), initialDeposit);
        holdingAsset.approve(mockFundAddress, initialDeposit);

        bytes memory creationCode;
        bytes memory constructorArgs;

        creationCode = type(MockFund).creationCode;
        constructorArgs = abi.encode(
            address(this),
            registry,
            holdingAsset,
            mockFundName,
            mockFundName,
            holdingPosition,
            abi.encode(true),
            initialDeposit,
            type(uint192).max
        );

        return MockFund(deployer.deployContract(mockFundName, creationCode, constructorArgs));
    }

    // ========================================= INITIALIZATION TEST =========================================

    function testInitialization() external {
        assertEq(address(fund.registry()), address(registry), "Should initialize registry to test registry.");

        uint32[] memory expectedPositions = new uint32[](6);
        expectedPositions[0] = usdcPosition;
        expectedPositions[1] = usdcCLRPosition;
        expectedPositions[2] = wethCLRPosition;
        expectedPositions[3] = wbtcCLRPosition;
        expectedPositions[4] = wethPosition;
        expectedPositions[5] = wbtcPosition;

        address[] memory expectedAdaptor = new address[](6);
        expectedAdaptor[0] = address(erc20Adaptor);
        expectedAdaptor[1] = address(swaapFundAdaptor);
        expectedAdaptor[2] = address(swaapFundAdaptor);
        expectedAdaptor[3] = address(swaapFundAdaptor);
        expectedAdaptor[4] = address(erc20Adaptor);
        expectedAdaptor[5] = address(erc20Adaptor);

        bytes[] memory expectedAdaptorData = new bytes[](6);
        expectedAdaptorData[0] = abi.encode(USDC);
        expectedAdaptorData[1] = abi.encode(usdcCLR);
        expectedAdaptorData[2] = abi.encode(wethCLR);
        expectedAdaptorData[3] = abi.encode(wbtcCLR);
        expectedAdaptorData[4] = abi.encode(WETH);
        expectedAdaptorData[5] = abi.encode(WBTC);

        uint32[] memory positions = fund.getCreditPositions();

        assertEq(fund.getCreditPositions().length, 6, "Position length should be 5.");

        for (uint256 i = 0; i < 6; i++) {
            assertEq(positions[i], expectedPositions[i], "Positions should have been written to Fund.");
            uint32 position = positions[i];
            (address adaptor, bool isDebt, bytes memory adaptorData, ) = fund.getPositionData(position);
            assertEq(adaptor, expectedAdaptor[i], "Position adaptor not initialized properly.");
            assertEq(isDebt, false, "There should be no debt positions.");
            assertEq(adaptorData, expectedAdaptorData[i], "Position adaptor data not initialized properly.");
        }

        assertEq(address(fund.asset()), address(USDC), "Should initialize asset to be USDC.");

        assertEq(fund.owner(), address(this), "Should initialize owner to this contract.");
    }

    // ========================================= DEPOSIT/WITHDRAW TEST =========================================

    function testDepositAndWithdraw(uint256 assets) external {
        assets = bound(assets, 1, type(uint72).max);

        deal(address(USDC), address(this), assets);

        // Try depositing more assets than balance.
        vm.expectRevert("TRANSFER_FROM_FAILED");
        fund.deposit(assets + 1, address(this));

        // Test single deposit.
        uint256 expectedShares = fund.previewDeposit(assets);
        uint256 shares = fund.deposit(assets, address(this));

        assertEq(shares, assets * assetToSharesDecimalsFactor, "Should have 1:1 exchange rate for initial deposit.");
        assertEq(fund.previewWithdraw(assets), shares, "Withdrawing assets should burn shares given.");
        assertEq(shares, expectedShares, "Depositing assets should mint shares given.");
        assertEq(fund.totalSupply(), shares + initialShares, "Should have updated total supply with shares minted.");
        assertEq(fund.totalAssets(), assets + initialAssets, "Should have updated total assets with assets deposited.");
        assertEq(fund.balanceOf(address(this)), shares, "Should have updated user's share balance.");
        assertEq(fund.balanceOf(address(fund)), 0, "Should not have minted fees because no gains.");
        assertEq(fund.convertToAssets(fund.balanceOf(address(this))), assets, "Should return all user's assets.");
        assertEq(USDC.balanceOf(address(this)), 0, "Should have deposited assets from user.");

        // Try withdrawing more assets than allowed.
        vm.expectRevert(stdError.arithmeticError);
        fund.withdraw(assets + 1, address(this), address(this));

        // Test single withdraw.
        fund.withdraw(assets, address(this), address(this));

        assertEq(fund.totalAssets(), initialAssets, "Should have updated total assets with assets withdrawn.");
        assertEq(fund.balanceOf(address(this)), 0, "Should have redeemed user's share balance.");
        assertEq(fund.convertToAssets(fund.balanceOf(address(this))), 0, "Should return zero assets.");
        assertEq(USDC.balanceOf(address(this)), assets, "Should have withdrawn assets to user.");
    }

    function testMintAndRedeem(uint256 assetsToDeposit) external {
        // minimum is set to assetsToShares to avoid Fund__ZeroAssets() revert
        uint192 assetsToShares = uint192(fund.totalSupply() / fund.totalAssets());
        assetsToDeposit = bound(assetsToDeposit, 1e6, type(uint80).max);

        uint256 shares = assetsToDeposit * assetsToShares;

        // Change decimals from the 18 used by shares to the 6 used by USDC.
        deal(address(USDC), address(this), shares / assetsToShares);

        // Try minting more assets than balance.
        vm.expectRevert("TRANSFER_FROM_FAILED");
        fund.mint(shares + 100e18, address(this));

        // Test single mint.
        uint256 assets = fund.mint(shares, address(this));

        assertEq(shares, assets * assetToSharesDecimalsFactor, "Should have 1:1 exchange rate for initial deposit.");
        assertEq(fund.previewRedeem(shares), assets, "Redeeming shares should withdraw assets owed.");
        assertEq(fund.previewMint(shares), assets, "Minting shares should deposit assets owed.");
        assertEq(fund.totalSupply(), shares + initialShares, "Should have updated total supply with shares minted.");
        assertEq(fund.totalAssets(), assets + initialAssets, "Should have updated total assets with assets deposited.");
        assertEq(fund.balanceOf(address(this)), shares, "Should have updated user's share balance.");
        assertEq(fund.convertToAssets(fund.balanceOf(address(this))), assets, "Should return all user's assets.");
        assertEq(USDC.balanceOf(address(this)), 0, "Should have deposited assets from user.");

        // Test single redeem.
        fund.redeem(shares, address(this), address(this));

        assertEq(fund.balanceOf(address(this)), 0, "Should have redeemed user's share balance.");
        assertEq(fund.convertToAssets(fund.balanceOf(address(this))), 0, "Should return zero assets.");
        assertEq(USDC.balanceOf(address(this)), assets, "Should have withdrawn assets to user.");
    }

    function testWithdrawInOrder() external {
        // Deposit enough assets into the Fund to rebalance.
        uint256 assets = 32_000e6;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        uint256 assetsToShares = fund.totalSupply() / fund.totalAssets();

        _depositToFund(fund, wethCLR, 2_000e6); // 1 Ether
        _depositToFund(fund, wbtcCLR, 30_000e6); // 1 WBTC
        assertEq(fund.totalAssets(), assets + initialAssets, "Should have updated total assets with assets deposited.");

        // Move USDC position to the back of the withdraw queue.
        fund.swapPositions(0, 3, false);

        // Withdraw from position.
        uint256 shares = fund.withdraw(32_000e6, address(this), address(this));

        assertEq(fund.balanceOf(address(this)), 0, "Should have redeemed all shares.");
        assertEq(shares, 32_000e6 * assetsToShares, "Should returned all redeemed shares.");
        assertEq(WETH.balanceOf(address(this)), 1e18, "Should have transferred position balance to user.");
        assertEq(WBTC.balanceOf(address(this)), 1e8, "Should have transferred position balance to user.");
        assertLt(WETH.balanceOf(address(wethCLR)), 1e18, "Should have transferred balance from WETH position.");
        assertLt(WBTC.balanceOf(address(wbtcCLR)), 1e8, "Should have transferred balance from BTC position.");
        assertEq(fund.totalAssets(), initialAssets, "Fund total assets should equal initial.");
    }

    function testWithdrawWithDuplicateReceivedAssets() external {
        string memory fundName = "Dummy Fund V0.3";
        uint256 initialDeposit = 1e12;
        Fund wethVault = _createFund(fundName, WETH, wethPosition, abi.encode(true), initialDeposit);

        uint32 newWETHPosition = 10;
        registry.trustPosition(newWETHPosition, address(swaapFundAdaptor), abi.encode(wethVault));
        fund.addPositionToCatalogue(newWETHPosition);
        fund.addPosition(1, newWETHPosition, abi.encode(true), false);

        // Deposit enough assets into the Fund to rebalance.
        uint256 assets = 3_000e6;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        _depositToFund(fund, wethCLR, 2_000e6); // 1 Ether
        _depositToFund(fund, wethVault, 1_000e6); // 0.5 Ether

        assertEq(
            fund.totalAssets(),
            3_000e6 + initialAssets,
            "Should have updated total assets with assets deposited."
        );
        uint256 assetsToShares = fund.totalSupply() / fund.totalAssets();
        assertEq(
            fund.totalSupply(),
            (3_000e6 + initialShares / assetToSharesDecimalsFactor) * assetsToShares,
            "Should have updated total supply with deposit"
        );

        // Move USDC position to the back of the withdraw queue.
        fund.swapPositions(0, 4, false);

        // Withdraw from position.
        uint256 shares = fund.withdraw(3_000e6, address(this), address(this));

        assertEq(fund.balanceOf(address(this)), 0, "Should have redeemed all shares.");
        assertEq(shares, 3000e6 * assetsToShares, "Should returned all redeemed shares.");
        assertEq(WETH.balanceOf(address(this)), 1.5e18, "Should have transferred position balance to user.");
        assertLt(WETH.balanceOf(address(wethCLR)), 1e18, "Should have transferred balance from WETH fund position.");
        assertLt(
            WETH.balanceOf(address(wethVault)),
            0.5e18,
            "Should have transferred balance from WETH vault position."
        );
        assertEq(fund.totalAssets(), initialAssets, "Fund total assets should equal initial.");
    }

    function testDepositMintWithdrawRedeemWithZeroInputs() external {
        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__ZeroShares.selector)));
        fund.deposit(0, address(this));

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__ZeroAssets.selector)));
        fund.mint(0, address(this));

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__ZeroAssets.selector)));
        fund.redeem(0, address(this), address(this));

        // Deal fund 1 wei of USDC to check that above explanation is correct.
        deal(address(USDC), address(fund), 1);
        fund.withdraw(0, address(this), address(this));
        assertEq(USDC.balanceOf(address(this)), 0, "Fund should not have sent any assets to this address.");
    }

    // ========================================= LIMITS TEST =========================================

    function testLimits() external {
        uint192 assetsToShares = uint192(fund.totalSupply() / fund.totalAssets());

        uint192 newCap = uint192(100e6 * assetsToShares);
        fund.setShareSupplyCap(newCap);
        assertEq(fund.shareSupplyCap(), newCap, "Share Supply Cap should have been updated.");
        uint256 totalAssets = fund.totalAssets();
        // Shares are not necessarily 1:1 with assets.
        uint256 expectedMaxShares = newCap - (totalAssets * assetsToShares);
        assertEq(
            fund.maxDeposit(address(this)),
            expectedMaxShares / assetsToShares,
            "Max Deposit should equal expected."
        );
        assertEq(fund.maxMint(address(this)), expectedMaxShares, "Max Mint should equal expected.");

        uint256 depositAmountToExceedCap = expectedMaxShares / assetsToShares + 1;
        deal(address(USDC), address(this), depositAmountToExceedCap);

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__ShareSupplyCapExceeded.selector)));
        fund.deposit(depositAmountToExceedCap, address(this));

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__ShareSupplyCapExceeded.selector)));
        fund.mint(expectedMaxShares + 1, address(this));

        // But if 1 wei is removed, deposit works.
        fund.deposit(depositAmountToExceedCap - 1, address(this));

        // Max function should now return 0.
        assertEq(fund.maxDeposit(address(this)), 0, "Max Deposit should equal 0");
        assertEq(fund.maxMint(address(this)), 0, "Max Mint should equal 0");
    }

    // ========================================== POSITIONS TEST ==========================================

    function testInteractingWithDistrustedPositions() external {
        fund.removePosition(4, fund.creditPositions(4), false);
        fund.removePositionFromCatalogue(wethPosition); // Removes WETH position from catalogue.

        // Fund should not be able to add position to tracked array until it is in the catalogue.
        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__PositionNotInCatalogue.selector, wethPosition)));
        fund.addPosition(4, wethPosition, abi.encode(true), false);

        // Since WETH position is trusted, fund should be able to add it to the catalogue, and to the tracked array.
        fund.addPositionToCatalogue(wethPosition);
        fund.addPosition(4, wethPosition, abi.encode(true), false);

        // Registry distrusts weth position.
        registry.distrustPosition(wethPosition);

        // Even though position is distrusted Fund can still operate normally.
        fund.totalAssets();

        // Distrusted position is still in tracked array, but strategist/governance can remove it.
        fund.removePosition(4, fund.creditPositions(4), false);

        // If strategist tries adding it back it reverts.
        vm.expectRevert(bytes(abi.encodeWithSelector(Registry.Registry__PositionIsNotTrusted.selector, wethPosition)));
        fund.addPosition(4, wethPosition, abi.encode(true), false);

        // Governance removes position from funds catalogue.
        fund.removePositionFromCatalogue(wethPosition); // Removes WETH position from catalogue.

        // But tries to add it back later which reverts.
        vm.expectRevert(bytes(abi.encodeWithSelector(Registry.Registry__PositionIsNotTrusted.selector, wethPosition)));
        fund.addPositionToCatalogue(wethPosition);
    }

    function testInteractingWithDistrustedAdaptors() external {
        fund.removeAdaptorFromCatalogue(address(swaapFundAdaptor));

        // With adaptor removed, rebalance calls to it revert.
        bytes[] memory emptyCall;
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        data[0] = Fund.AdaptorCall({ adaptor: address(swaapFundAdaptor), callData: emptyCall });

        vm.expectRevert(
            bytes(abi.encodeWithSelector(Fund.Fund__CallToAdaptorNotAllowed.selector, address(swaapFundAdaptor)))
        );
        fund.callOnAdaptor(data);

        // Add the adaptor back to the catalogue.
        fund.addAdaptorToCatalogue(address(swaapFundAdaptor));

        // Calls to it now work.
        fund.callOnAdaptor(data);

        // Registry distrusts the adaptor, but fund can still use it.
        registry.distrustAdaptor(address(swaapFundAdaptor));
        fund.callOnAdaptor(data);

        // But now if adaptor is removed from the catalogue it can not be re-added.
        fund.removeAdaptorFromCatalogue(address(swaapFundAdaptor));

        vm.expectRevert(
            bytes(abi.encodeWithSelector(Registry.Registry__AdaptorNotTrusted.selector, address(swaapFundAdaptor)))
        );
        fund.addAdaptorToCatalogue(address(swaapFundAdaptor));
    }

    function testManagingPositions() external {
        uint256 positionLength = fund.getCreditPositions().length;

        // Check that `removePosition` actually removes it.
        fund.removePosition(4, fund.creditPositions(4), false);

        assertEq(
            positionLength - 1,
            fund.getCreditPositions().length,
            "Fund positions array should be equal to previous length minus 1."
        );

        assertFalse(fund.isPositionUsed(wethPosition), "`isPositionUsed` should be false for WETH.");
        (address zeroAddressAdaptor, , , ) = fund.getPositionData(wethPosition);
        assertEq(zeroAddressAdaptor, address(0), "Removing position should have deleted position data.");
        // Check that adding a credit position as debt reverts.
        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__DebtMismatch.selector, wethPosition)));
        fund.addPosition(4, wethPosition, abi.encode(true), true);

        // Check that `addPosition` actually adds it.
        fund.addPosition(4, wethPosition, abi.encode(true), false);

        assertEq(
            positionLength,
            fund.getCreditPositions().length,
            "Fund positions array should be equal to previous length."
        );

        assertEq(fund.creditPositions(4), wethPosition, "`positions[4]` should be WETH.");
        assertTrue(fund.isPositionUsed(wethPosition), "`isPositionUsed` should be true for WETH.");

        // Check that `addPosition` reverts if position is already used.
        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__PositionAlreadyUsed.selector, wethPosition)));
        fund.addPosition(4, wethPosition, abi.encode(true), false);

        // Give Fund 1 wei of WETH.
        deal(address(WETH), address(fund), 1);

        // Check that `removePosition` reverts if position has any funds in it.
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    Fund.Fund__PositionNotEmpty.selector,
                    wethPosition,
                    WETH.balanceOf(address(fund))
                )
            )
        );
        fund.removePosition(4, wethPosition, false);

        // Check that `addPosition` reverts if position is not trusted.
        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__PositionNotInCatalogue.selector, 0)));
        fund.addPosition(4, 0, abi.encode(true), false);

        // Check that `addPosition` reverts if debt position is not trusted.
        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__PositionNotInCatalogue.selector, 0)));
        fund.addPosition(4, 0, abi.encode(0), true);

        // Set Fund WETH balance to 0.
        deal(address(WETH), address(fund), 0);

        fund.removePosition(4, fund.creditPositions(4), false);

        // Check that addPosition sets position data.
        fund.addPosition(4, wethPosition, abi.encode(true), false);
        (address adaptor, bool isDebt, bytes memory adaptorData, bytes memory configurationData) = fund.getPositionData(
            wethPosition
        );
        assertEq(adaptor, address(erc20Adaptor), "Adaptor should be the ERC20 adaptor.");
        assertTrue(!isDebt, "Position should not be debt.");
        assertEq(adaptorData, abi.encode((WETH)), "Adaptor data should be abi encoded WETH.");
        assertEq(configurationData, abi.encode(true), "Configuration data should be abi encoded ZERO.");

        // Check that `swapPosition` works as expected.
        fund.swapPositions(4, 2, false);
        assertEq(fund.creditPositions(4), wethCLRPosition, "`positions[4]` should be wethCLR.");
        assertEq(fund.creditPositions(2), wethPosition, "`positions[2]` should be WETH.");

        // Try setting the holding position to an unused position.
        uint32 invalidPositionId = 100;
        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__PositionNotUsed.selector, invalidPositionId)));
        fund.setHoldingPosition(invalidPositionId);

        // Try setting holding position with a position with different asset.
        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__AssetMismatch.selector, address(USDC), address(WETH))));
        fund.setHoldingPosition(wethPosition);

        // Set holding position to usdcCLR.
        fund.setHoldingPosition(usdcCLRPosition);

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__RemovingHoldingPosition.selector)));
        // Try removing the holding position.
        fund.removePosition(1, usdcCLRPosition, false);

        // Set holding position back to USDC.
        fund.setHoldingPosition(usdcPosition);

        // Work with debt positions now.
        // Try setting holding position to a debt position.
        ERC20DebtAdaptor debtAdaptor = new ERC20DebtAdaptor();
        registry.trustAdaptor(address(debtAdaptor));
        uint32 debtWethPosition = 101;
        registry.trustPosition(debtWethPosition, address(debtAdaptor), abi.encode(WETH));
        uint32 debtWbtcPosition = 102;
        registry.trustPosition(debtWbtcPosition, address(debtAdaptor), abi.encode(WBTC));

        uint32 debtUsdcPosition = 103;
        registry.trustPosition(debtUsdcPosition, address(debtAdaptor), abi.encode(USDC));
        fund.addPositionToCatalogue(debtUsdcPosition);
        fund.addPositionToCatalogue(debtWethPosition);
        fund.addPositionToCatalogue(debtWbtcPosition);
        fund.addPosition(0, debtUsdcPosition, abi.encode(0), true);
        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__InvalidHoldingPosition.selector, debtUsdcPosition)));
        fund.setHoldingPosition(debtUsdcPosition);

        registry.distrustPosition(debtUsdcPosition);
        fund.forcePositionOut(0, debtUsdcPosition, true);

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__DebtMismatch.selector, debtWethPosition)));
        fund.addPosition(0, debtWethPosition, abi.encode(0), false);

        fund.addPosition(0, debtWethPosition, abi.encode(0), true);
        assertEq(fund.getDebtPositions().length, 1, "Debt positions should be length 1.");

        fund.addPosition(0, debtWbtcPosition, abi.encode(0), true);
        assertEq(fund.getDebtPositions().length, 2, "Debt positions should be length 2.");

        // Remove all debt.
        fund.removePosition(0, fund.debtPositions(0), true);
        assertEq(fund.getDebtPositions().length, 1, "Debt positions should be length 1.");

        fund.removePosition(0, fund.debtPositions(0), true);
        assertEq(fund.getDebtPositions().length, 0, "Debt positions should be length 1.");

        // Add debt positions back.
        fund.addPosition(0, debtWethPosition, abi.encode(0), true);
        assertEq(fund.getDebtPositions().length, 1, "Debt positions should be length 1.");

        fund.addPosition(0, debtWbtcPosition, abi.encode(0), true);
        assertEq(fund.getDebtPositions().length, 2, "Debt positions should be length 2.");

        // revert for wrong expected position
        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__WrongPositionId.selector)));
        fund.removePosition(2, usdcPosition, false);

        // Check force position out logic.
        // Give Fund 1 WEI WETH.
        deal(address(WETH), address(fund), 1);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    Fund.Fund__PositionNotEmpty.selector,
                    wethPosition,
                    WETH.balanceOf(address(fund))
                )
            )
        );
        fund.removePosition(2, wethPosition, false);

        // Try forcing out the wrong position.
        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__FailedToForceOutPosition.selector)));
        fund.forcePositionOut(4, wethPosition, false);

        // Try forcing out a position that is trusted
        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__FailedToForceOutPosition.selector)));
        fund.forcePositionOut(2, wethPosition, false);

        // When correct index is used, and position is distrusted call works.
        registry.distrustPosition(wethPosition);
        fund.forcePositionOut(2, wethPosition, false);

        assertTrue(!fund.isPositionUsed(wethPosition), "WETH Position should have been forced out.");
    }

    // ========================================== REBALANCE TEST ==========================================

    function testSettingBadRebalanceDeviation() external {
        // Max rebalance deviation value is 10%.
        uint256 deviation = 0.2e18;
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    Fund.Fund__InvalidRebalanceDeviation.selector,
                    deviation,
                    fund.MAX_REBALANCE_DEVIATION()
                )
            )
        );
        fund.setRebalanceDeviation(deviation);
    }

    // ======================================== EMERGENCY TESTS ========================================

    function testRegistryPauseStoppingAllFundActions() external {
        // Empty call on adaptor argument.
        bytes[] memory emptyCall;
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        data[0] = Fund.AdaptorCall({ adaptor: address(swaapFundAdaptor), callData: emptyCall });

        address[] memory targets = new address[](1);
        targets[0] = address(fund);

        uint256 assetsToShares = fund.totalSupply() / fund.totalAssets();

        registry.batchPause(targets);

        assertEq(fund.isPaused(), true, "Fund should be paused.");

        // Fund is fully paused.
        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__Paused.selector)));
        fund.deposit(1e6, address(this));

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__Paused.selector)));
        fund.mint(1e6 * assetsToShares, address(this));

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__Paused.selector)));
        fund.withdraw(1e6, address(this), address(this));

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__Paused.selector)));
        fund.redeem(1e6 * assetsToShares, address(this), address(this));

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__Paused.selector)));
        fund.totalAssets();

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__Paused.selector)));
        fund.totalAssetsWithdrawable();

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__Paused.selector)));
        fund.maxWithdraw(address(this));

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__Paused.selector)));
        fund.maxRedeem(address(this));

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__Paused.selector)));
        fund.callOnAdaptor(data);

        // Once fund is unpaused all actions resume as normal.
        registry.batchUnpause(targets);
        assertEq(fund.isPaused(), false, "Fund should not be paused.");
        deal(address(USDC), address(this), 100e6);
        fund.deposit(1e6, address(this));
        fund.mint(1e6 * assetsToShares, address(this));
        fund.withdraw(1e6, address(this), address(this));
        fund.redeem(1e6 * assetsToShares, address(this), address(this));
        fund.totalAssets();
        fund.totalAssetsWithdrawable();
        fund.maxWithdraw(address(this));
        fund.maxRedeem(address(this));
        fund.callOnAdaptor(data);
    }

    function testRegistryPauseButEndDurationReached() external {
        // Deploy mockFund to access internal variable
        mockFund = deployMockFund(registry, USDC, "Mock Fund", usdcPosition, 100e6);

        // Empty call on adaptor argument.
        bytes[] memory emptyCall;
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        data[0] = Fund.AdaptorCall({ adaptor: address(swaapFundAdaptor), callData: emptyCall });

        address[] memory targets = new address[](1);
        targets[0] = address(fund);

        registry.batchPause(targets);

        deal(address(USDC), address(this), 100e6);

        // Fund is fully paused from the registry.
        assertEq(fund.isPaused(), true, "Fund should be paused.");

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__Paused.selector)));
        fund.deposit(1e6, address(this));

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__Paused.selector)));
        fund.mint(1e18, address(this));

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__Paused.selector)));
        fund.withdraw(1e6, address(this), address(this));

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__Paused.selector)));
        fund.redeem(1e18, address(this), address(this));

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__Paused.selector)));
        fund.totalAssets();

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__Paused.selector)));
        fund.totalAssetsWithdrawable();

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__Paused.selector)));
        fund.maxWithdraw(address(this));

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__Paused.selector)));
        fund.maxRedeem(address(this));

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__Paused.selector)));
        fund.callOnAdaptor(data);

        // After 9 month, fund should ignore the pause whatever the state of the registry for this fund.
        skip(mockFund.getDelayUntilEndPause());

        // Fund is fully paused from the registry.
        assertEq(fund.isPaused(), false, "Fund should not be paused.");

        // Update the external source of price
        mockUsdcUsd.setMockUpdatedAt(block.timestamp);
        mockWethUsd.setMockUpdatedAt(block.timestamp);
        mockWbtcUsd.setMockUpdatedAt(block.timestamp);

        fund.deposit(1e6, address(this));
        fund.mint(1e18, address(this));
        fund.withdraw(1e6, address(this), address(this));
        fund.redeem(1e18, address(this), address(this));
        fund.totalAssets();
        fund.totalAssetsWithdrawable();
        fund.maxWithdraw(address(this));
        fund.maxRedeem(address(this));
        fund.callOnAdaptor(data);
    }

    function testEndPauseDurationButFundIsShutDownThenLiftShutdown() external {
        // Deploy mockFund to access internal variable
        mockFund = deployMockFund(registry, USDC, "Mock Fund", usdcPosition, 100e6);

        // Empty call on adaptor argument.
        bytes[] memory emptyCall;
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        data[0] = Fund.AdaptorCall({ adaptor: address(swaapFundAdaptor), callData: emptyCall });

        address[] memory targets = new address[](1);
        targets[0] = address(fund);

        uint256 assetToDepositOrWithdraw = 1;
        deal(address(USDC), address(this), assetToDepositOrWithdraw);
        fund.deposit(1, address(this));

        registry.batchPause(targets);
        // Fund is fully paused from the registry.
        assertEq(fund.isPaused(), true, "Fund should be paused.");

        fund.initiateShutdown();
        // Fund is also shutdown.
        assertTrue(fund.isShutdown(), "Should have initiated shutdown.");

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__Paused.selector)));
        fund.withdraw(assetToDepositOrWithdraw, address(this), address(this));

        // Go 9 months after the creation of the fund.
        skip(mockFund.getDelayUntilEndPause());

        // Update the external source of price
        mockUsdcUsd.setMockUpdatedAt(block.timestamp);
        mockWethUsd.setMockUpdatedAt(block.timestamp);
        mockWbtcUsd.setMockUpdatedAt(block.timestamp);

        // Shutdown but pause end duration reached
        fund.withdraw(assetToDepositOrWithdraw, address(this), address(this));
        assertEq(USDC.balanceOf(address(this)), assetToDepositOrWithdraw, "Should withdraw while shutdown.");

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__ContractShutdown.selector)));
        fund.deposit(assetToDepositOrWithdraw, address(this));

        // Governance decides to lift the shutdown.
        fund.liftShutdown();
        fund.deposit(assetToDepositOrWithdraw, address(this));
        assertEq(fund.totalAssets(), assetToDepositOrWithdraw + initialAssets, "Fund should be open for deposits.");
    }

    function testShutdown() external {
        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__ContractNotShutdown.selector)));
        fund.liftShutdown();

        fund.initiateShutdown();

        assertTrue(fund.isShutdown(), "Should have initiated shutdown.");

        fund.liftShutdown();

        assertFalse(fund.isShutdown(), "Should have lifted shutdown.");
    }

    function testWithdrawingWhileShutdown() external {
        deal(address(USDC), address(this), 1);
        fund.deposit(1, address(this));

        fund.initiateShutdown();

        fund.withdraw(1, address(this), address(this));

        assertEq(USDC.balanceOf(address(this)), 1, "Should withdraw while shutdown.");
    }

    function testProhibitedActionsWhileShutdown() external {
        uint256 assets = 100e6;

        // Give this address enough USDC to cover deposits.
        deal(address(USDC), address(this), assets);

        // Deposit USDC into Fund.
        fund.deposit(assets, address(this));

        fund.initiateShutdown();

        deal(address(USDC), address(this), 1);

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__ContractShutdown.selector)));
        fund.initiateShutdown();

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__ContractShutdown.selector)));
        fund.deposit(1, address(this));

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__ContractShutdown.selector)));
        fund.addPosition(5, 0, abi.encode(0), false);

        address[] memory path = new address[](2);
        path[0] = address(USDC);
        path[1] = address(WETH);

        Fund.AdaptorCall[] memory adaptorCallData;
        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__ContractShutdown.selector)));
        fund.callOnAdaptor(adaptorCallData);

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__ContractShutdown.selector)));
        fund.initiateShutdown();
    }

    // =========================================== TOTAL ASSETS TEST ===========================================

    function testCachePriceRouter() external {
        uint256 assets = 100e6;

        // Give this address enough USDC to cover deposits.
        deal(address(USDC), address(this), assets);

        // Deposit USDC into Fund.
        fund.deposit(assets, address(this));
        assertEq(address(fund.priceRouter()), address(priceRouter), "Price Router saved in fund should equal current.");

        // Manipulate state so that stored price router reverts with pricing calls.
        stdstore.target(address(fund)).sig(fund.priceRouter.selector).checked_write(address(0));
        vm.expectRevert();
        fund.totalAssets();

        // Governance can recover fund by calling `cachePriceRouter(false)`.
        fund.cachePriceRouter(false, 0.05e4, registry.getAddress(2));
        assertEq(address(fund.priceRouter()), address(priceRouter), "Price Router saved in fund should equal current.");

        // Now that price router is correct, calling it again should succeed even though it doesn't set anything.
        fund.cachePriceRouter(true, 0.05e4, registry.getAddress(2));

        // Registry sets a malicious price router.
        registry.setAddress(2, address(this));

        // Try to set it as the funds price router.
        vm.expectRevert(
            bytes(abi.encodeWithSelector(Fund.Fund__TotalAssetDeviatedOutsideRange.selector, 50e6, 95.95e6, 106.05e6))
        );
        fund.cachePriceRouter(true, 0.05e4, address(this));

        // Set registry back to use old price router.
        registry.setAddress(2, address(priceRouter));

        // Multisig tries to change the price router address once governance prop goes through.
        registry.setAddress(2, address(this));

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__ExpectedAddressDoesNotMatchActual.selector)));
        fund.cachePriceRouter(true, 0.05e4, address(priceRouter));
    }

    function testTotalAssets(
        uint256 usdcAmount,
        uint256 usdcCLRAmount,
        uint256 wethCLRAmount,
        uint256 wbtcCLRAmount,
        uint256 wethAmount
    ) external {
        usdcAmount = bound(usdcAmount, 1e6, 1_000_000e6);
        usdcCLRAmount = bound(usdcCLRAmount, 1e6, 1_000_000e6);
        wethCLRAmount = bound(wethCLRAmount, 1e6, 1_000_000e6);
        wbtcCLRAmount = bound(wbtcCLRAmount, 1e6, 1_000_000e6);
        wethAmount = bound(wethAmount, 1e18, 10_000e18);
        uint256 totalAssets = fund.totalAssets();

        assertEq(totalAssets, initialAssets, "Fund total assets should be initialAssets.");

        deal(address(USDC), address(this), usdcCLRAmount + wethCLRAmount + wbtcCLRAmount + usdcAmount);
        fund.deposit(usdcCLRAmount + wethCLRAmount + wbtcCLRAmount + usdcAmount, address(this));

        _depositToFund(fund, usdcCLR, usdcCLRAmount);
        _depositToFund(fund, wethCLR, wethCLRAmount);
        _depositToFund(fund, wbtcCLR, wbtcCLRAmount);
        deal(address(WETH), address(fund), wethAmount);

        uint256 expectedTotalAssets = usdcAmount +
            usdcCLRAmount +
            priceRouter.getValue(WETH, wethAmount, USDC) +
            wethCLRAmount +
            wbtcCLRAmount +
            initialAssets;

        totalAssets = fund.totalAssets();

        assertApproxEqRel(
            totalAssets,
            expectedTotalAssets,
            0.0001e18,
            "`totalAssets` should equal all asset values summed together."
        );
    }

    // ====================================== PLATFORM FEE TEST ======================================

    function testDebtTokensInFunds() external {
        ERC20DebtAdaptor debtAdaptor = new ERC20DebtAdaptor();
        registry.trustAdaptor(address(debtAdaptor));
        uint32 debtWethPosition = 10;
        registry.trustPosition(debtWethPosition, address(debtAdaptor), abi.encode(WETH));
        uint32 debtWbtcPosition = 11;
        registry.trustPosition(debtWbtcPosition, address(debtAdaptor), abi.encode(WBTC));

        // Setup Fund with debt positions:
        string memory fundName = "Debt Fund V0.0";
        uint256 initialDeposit = 1e6;

        Fund debtFund = _createFund(fundName, USDC, usdcPosition, abi.encode(true), initialDeposit);

        debtFund.addPositionToCatalogue(debtWethPosition);
        debtFund.addPositionToCatalogue(debtWbtcPosition);
        debtFund.addPosition(0, debtWethPosition, abi.encode(0), true);

        //constructor should set isDebt
        (, bool isDebt, , ) = debtFund.getPositionData(debtWethPosition);
        assertTrue(isDebt, "Constructor should have set WETH as a debt position.");
        assertEq(debtFund.getDebtPositions().length, 1, "Fund should have 1 debt position");

        //Add another debt position WBTC.
        //adding WBTC should increment number of debt positions.
        debtFund.addPosition(0, debtWbtcPosition, abi.encode(0), true);
        assertEq(debtFund.getDebtPositions().length, 2, "Fund should have 2 debt positions");

        (, isDebt, , ) = debtFund.getPositionData(debtWbtcPosition);
        assertTrue(isDebt, "Constructor should have set WBTC as a debt position.");
        assertEq(debtFund.getDebtPositions().length, 2, "Fund should have 2 debt positions");

        // removing WBTC should decrement number of debt positions.
        debtFund.removePosition(0, debtWbtcPosition, true);
        assertEq(debtFund.getDebtPositions().length, 1, "Fund should have 1 debt position");

        // Adding a debt position, but specifying it as a credit position should revert.
        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__DebtMismatch.selector, debtWbtcPosition)));
        debtFund.addPosition(0, debtWbtcPosition, abi.encode(0), false);

        debtFund.addPosition(0, debtWbtcPosition, abi.encode(0), true);

        // Give debt fund some assets.
        deal(address(USDC), address(debtFund), 100_000e6);
        deal(address(WBTC), address(debtFund), 1e8);
        deal(address(WETH), address(debtFund), 10e18);

        uint256 totalAssets = debtFund.totalAssets();
        uint256 expectedTotalAssets = 50_000e6;

        assertEq(totalAssets, expectedTotalAssets, "Debt fund total assets should equal expected.");
    }

    function testFundWithFundPositions() external {
        // Fund A's asset is USDC, holding position is Fund B shares, whose holding asset is USDC.
        // Initialize test Funds.

        // Create Fund B
        string memory fundName = "Fund B V0.0";
        uint256 initialDeposit = 1e6;
        Fund fundB = _createFund(fundName, USDC, usdcPosition, abi.encode(true), initialDeposit);

        uint32 fundBPosition = 10;
        registry.trustPosition(fundBPosition, address(swaapFundAdaptor), abi.encode(fundB));

        // Create Fund A
        fundName = "Fund A V0.0";
        initialDeposit = 1e6;
        Fund fundA = _createFund(fundName, USDC, usdcPosition, abi.encode(true), initialDeposit);

        fundA.addPositionToCatalogue(fundBPosition);
        fundA.addPosition(0, fundBPosition, abi.encode(true), false);
        fundA.setHoldingPosition(fundBPosition);
        fundA.swapPositions(0, 1, false);

        uint256 assets = 100e6;
        deal(address(USDC), address(this), assets);
        USDC.approve(address(fundA), assets);
        fundA.deposit(assets, address(this));

        uint256 withdrawAmount = fundA.maxWithdraw(address(this));
        assertEq(assets, withdrawAmount, "Assets should not have changed.");
        assertEq(fundA.totalAssets(), fundB.totalAssets(), "Total assets should be the same.");

        fundA.withdraw(withdrawAmount, address(this), address(this));
    }

    function testCallerOfCallOnAdaptor() external {
        // Specify a zero length Adaptor Call array.
        Fund.AdaptorCall[] memory data;

        address automationActions = vm.addr(5);
        registry.register(automationActions);
        fund.setAutomationActions(3, automationActions);

        // Only owner and automation actions can call `callOnAdaptor`.
        fund.callOnAdaptor(data);

        vm.prank(automationActions);
        fund.callOnAdaptor(data);

        // Update Automation Actions contract to zero address.
        fund.setAutomationActions(4, address(0));

        // Call now reverts.
        vm.startPrank(automationActions);
        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__CallerNotApprovedToRebalance.selector)));
        fund.callOnAdaptor(data);
        vm.stopPrank();

        // Owner can still call callOnAdaptor.
        fund.callOnAdaptor(data);

        registry.setAddress(3, automationActions);

        // Governance tries to set automation actions to registry address 3, but malicious multisig changes it after prop passes.
        registry.setAddress(3, address(this));

        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__ExpectedAddressDoesNotMatchActual.selector)));
        fund.setAutomationActions(3, automationActions);

        // Try setting automation actions to registry id 0.
        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__SettingValueToRegistryIdZeroIsProhibited.selector)));
        fund.setAutomationActions(0, automationActions);
    }

    // ======================================== DEPEGGING ASSET TESTS ========================================

    function testDepeggedAssetNotUsedByFund() external {
        // Scenario 1: Depegged asset is not being used by the fund.
        // Governance can remove it itself by calling `distrustPosition`.

        // Add asset that will be depegged.
        fund.addPosition(5, usdtPosition, abi.encode(true), false);

        deal(address(USDC), address(this), 200e6);
        fund.deposit(100e6, address(this));

        // USDT depeggs to $0.90.
        mockUsdtUsd.setMockAnswer(0.9e8);

        assertEq(fund.totalAssets(), 100e6 + initialAssets, "Fund total assets should remain unchanged.");
        assertEq(fund.deposit(100e6, address(this)), 100e18, "Fund share price should not change.");
    }

    function testDepeggedAssetUsedByTheFund() external {
        // Scenario 2: Depegged asset is being used by the fund. Governance
        // uses multicall to rebalance fund out of position, and to distrust
        // it.

        // Add asset that will be depegged.
        fund.addPosition(5, usdtPosition, abi.encode(true), false);

        deal(address(USDC), address(this), 200e6);
        fund.deposit(100e6, address(this));

        //Change Fund holdings manually to 50/50 USDC/USDT.
        deal(address(USDC), address(fund), 50e6);
        deal(address(USDT), address(fund), 50e6);

        // USDT depeggs to $0.90.
        mockUsdtUsd.setMockAnswer(0.9e8);

        assertEq(fund.totalAssets(), 95e6, "Fund total assets should have gone down.");
        assertGt(fund.deposit(100e6, address(this)), 100e6, "Fund share price should have decreased.");

        // Governance votes to rebalance out of USDT, and distrust USDT.
        // Manually rebalance into USDC.
        deal(address(USDC), address(fund), 95e6);
        deal(address(USDT), address(fund), 0);
    }

    function testDepeggedHoldingPosition() external {
        // Scenario 3: Depegged asset is being used by the fund, and it is the
        // holding position. Governance uses multicall to rebalance fund out
        // of position, set a new holding position, and distrust it.

        fund.setHoldingPosition(usdcCLRPosition);

        // Rebalance into USDC. No swap is made because both positions use
        // USDC.
        deal(address(USDC), address(this), 200e6);
        fund.deposit(100e6, address(this));

        // Make call to adaptor to remove funds from usdcCLR into USDC position.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = abi.encodeWithSelector(SwaapFundAdaptor.withdrawFromFund.selector, usdcCLR, 50e6);
        data[0] = Fund.AdaptorCall({ adaptor: address(swaapFundAdaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        // usdcCLR depeggs from USDC
        deal(address(USDC), address(usdcCLR), 45e6);

        assertLt(fund.totalAssets(), 100e6, "Fund total assets should have gone down.");
        assertGt(fund.deposit(100e6, address(this)), 100e6, "Fund share price should have decreased.");

        // Governance votes to rebalance out of usdcCLR, change the holding
        // position, and distrust usdcCLR. No swap is made because both
        // positions use USDC.
        adaptorCalls[0] = abi.encodeWithSelector(
            SwaapFundAdaptor.withdrawFromFund.selector,
            usdcCLR,
            usdcCLR.maxWithdraw(address(fund))
        );
        data[0] = Fund.AdaptorCall({ adaptor: address(swaapFundAdaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        fund.setHoldingPosition(usdcPosition);
    }

    function testDepeggedFundAsset() external {
        // Scenario 4: Depegged asset is the funds asset. Worst case
        // scenario, rebalance out of position into some new stable position,
        // set fees to zero, initiate a shutdown, and have users withdraw funds
        // asap. Want to ensure that attackers can not join using the depegged
        // asset. Emergency governance proposal to move funds into some new
        // safety contract, shutdown old fund, and allow users to withdraw
        // from the safety contract.
        uint192 assetsToShares = uint192(fund.totalSupply() / fund.totalAssets());

        fund.addPosition(5, usdtPosition, abi.encode(true), false);

        deal(address(USDC), address(this), 100e6);
        fund.deposit(100e6, address(this));

        // USDC depeggs to $0.90.
        mockUsdcUsd.setMockAnswer(0.9e8);

        assertEq(fund.totalAssets(), 100e6 + initialAssets, "Fund total assets should remain unchanged.");

        // Governance rebalances to USDT, sets performance and platform fees to
        // zero, initiates a shutdown, and has users withdraw their funds.
        // Manually rebalance to USDT.
        deal(address(USDC), address(fund), 0);
        deal(address(USDT), address(fund), 90e6);

        fund.initiateShutdown();

        // Attacker tries to join with depegged asset.
        address attacker = vm.addr(34534);
        deal(address(USDC), attacker, 1);
        vm.startPrank(attacker);
        USDC.approve(address(fund), 1);
        vm.expectRevert(bytes(abi.encodeWithSelector(Fund.Fund__ContractShutdown.selector)));
        fund.deposit(1, attacker);
        vm.stopPrank();

        fund.redeem(50e6 * assetsToShares, address(this), address(this));

        // USDC depeggs to $0.10.
        mockUsdcUsd.setMockAnswer(0.1e8);

        fund.redeem(50e6 * assetsToShares, address(this), address(this));

        // Eventhough USDC depegged further, fund rebalanced out of USDC
        // removing its exposure to it.  So users can expect to get the
        // remaining value out of the fund.
        assertEq(
            USDT.balanceOf(address(this)),
            89108910,
            "Withdraws should total the amount of USDT in the fund after rebalance."
        );

        // Governance can not distrust USDC, because it is the holding position,
        // and changing the holding position is pointless because the asset of
        // the new holding position must be USDC.  Therefore the fund is lost,
        // and should be exitted completely.
    }

    //     /**
    //      * Some notes about the above tests:
    //      * It will be difficult for Governance to set some safe min asset amount
    //      * when rebalancing a fund from a depegging asset. Ideally this would be
    //      * done by the strategist, but even then if the price is volatile enough,
    //      * strategists might not be able to set a fair min amount out value. We
    //      * might be able to use Chainlink price feeds to get around this, and rely
    //      * on the Chainlink oracle data in order to calculate a fair min amount out
    //      * on chain.
    //      *
    //      * Users will be able to exit the fund as long as the depegged asset is
    //      * still within its price envelope defined in the price router as minPrice
    //      * and maxPrice. Once an asset is outside this envelope, or Chainlink stops
    //      * reporting pricing data, the situation becomes difficult. Any calls
    //      * involving `totalAssets()` will fail because the price router will not be
    //      * able to get a safe price for the depegged asset. With this in mind we
    //      * should consider creating some emergency fund protector contract, where in
    //      * the event a violent depegging occurs, Governance can vote to trust the
    //      * fund protector contract as a position, and all the funds assets can be
    //      * converted into some safe asset then deposited into the fund protector
    //      * contract. Doing this decouples the depegged asset pricing data from
    //      * assets in the fund. In order to get their funds out users would go to
    //      * the fund protector contract, and trade their shares (from the depegged
    //      * fund) for assets in the fund protector.
    //      */

    // ========================================= MACRO FINDINGS =========================================

    // H-1 done.

    // H-2 NA, funds will not increase their TVL during rebalance calls.
    // In future versions this will be fixed by having all yield converted into the fund's accounting asset, then put into a vestedERC20 contract which gradually releases rewards to the fund.

    // M5
    error Fund__Reentrancy();

    function testReentrancyAttack() external {
        // True means this fund tries to re-enter caller on deposit calls.
        ReentrancyERC4626 maliciousFund = new ReentrancyERC4626(USDC, "Bad Fund", "BC", true);

        uint32 maliciousPosition = 20;
        registry.trustPosition(maliciousPosition, address(swaapFundAdaptor), abi.encode(maliciousFund));
        fund.addPositionToCatalogue(maliciousPosition);
        fund.addPosition(5, maliciousPosition, abi.encode(true), false);

        fund.setHoldingPosition(maliciousPosition);

        uint256 assets = 10000e6;
        deal(address(USDC), address(this), assets);
        USDC.approve(address(maliciousFund), assets);

        vm.expectRevert(Fund__Reentrancy.selector);
        fund.deposit(assets, address(this));
    }

    // L-4 handle via using a centralized contract storing valid positions(to reduce num of governance props), and rely on voters to see mismatched position and types.
    //  Will not be added to this code.

    //M-6 handled offchain using a subgraph to verify no weird webs are happening
    // difficult bc we can control downstream, but can't control upstream. IE
    // Fund A wants to add a position in Fund B, but Fund B already has a position in Fund C. Fund A could see this, but...
    // If Fund A takes a postion in Fund B, then Fund B takes a position in Fund C, Fund B would need to look upstream to see the nested postions which is unreasonable,
    // and it means Fund A can dictate what positions Fund B takes which is not good.

    // M-2, changes in trustPosition.
    function testTrustPositionForUnsupportedAssetLocksAllFunds() external {
        // FRAX is not a supported PriceRouter asset.

        uint256 assets = 10e18;

        deal(address(USDC), address(this), assets);

        // Deposit USDC
        fund.previewDeposit(assets);
        fund.deposit(assets, address(this));
        assertEq(USDC.balanceOf(address(this)), 0, "Should have deposited assets from user.");

        // FRAX is added as a trusted Fund position,
        // but is not supported by the PriceRouter.
        vm.expectRevert(
            bytes(abi.encodeWithSelector(Registry.Registry__PositionPricingNotSetUp.selector, address(FRAX)))
        );
        registry.trustPosition(101, address(erc20Adaptor), abi.encode(FRAX));
    }

    // Crowd Audit Tests
    //M-1 Accepted
    //M-2
    function testFundDNOSPerformanceFeesWithZeroShares() external {
        //Attacker deposits 1 USDC into Fund.
        uint256 assets = 1e6;
        address attacker = vm.addr(101);
        deal(address(USDC), attacker, assets);
        vm.prank(attacker);
        USDC.transfer(address(fund), assets);

        address user = vm.addr(10101);
        deal(address(USDC), user, assets);

        vm.startPrank(user);
        USDC.approve(address(fund), assets);
        fund.deposit(assets, user);
        vm.stopPrank();

        assertEq(fund.maxWithdraw(user), assets, "User should be able to withdraw their assets.");
    }

    //============================================ Helper Functions ===========================================

    function _depositToFund(Fund targetFrom, Fund targetTo, uint256 amountIn) internal {
        ERC20 assetIn = targetFrom.asset();
        ERC20 assetOut = targetTo.asset();

        uint256 amountTo = priceRouter.getValue(assetIn, amountIn, assetOut);

        // Update targetFrom ERC20 balances.
        deal(address(assetIn), address(targetFrom), assetIn.balanceOf(address(targetFrom)) - amountIn);
        deal(address(assetOut), address(targetFrom), assetOut.balanceOf(address(targetFrom)) + amountTo);

        // Rebalance into targetTo.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToDepositToFund(address(targetTo), amountTo);
            data[0] = Fund.AdaptorCall({ adaptor: address(swaapFundAdaptor), callData: adaptorCalls });
        }

        // Perform callOnAdaptor.
        targetFrom.callOnAdaptor(data);
    }

    // Used to act like malicious price router under reporting assets.
    function getValuesDelta(
        ERC20[] calldata,
        uint256[] calldata,
        ERC20[] calldata,
        uint256[] calldata,
        ERC20
    ) external pure returns (uint256) {
        return 50e6;
    }
}
