// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { MockDataFeed } from "src/mocks/MockDataFeed.sol";
import { MockFundWithShareLockFlashLoansWhitelisting } from "src/mocks/MockFundWithShareLockFlashLoansWhitelisting.sol";
import { SwaapFundAdaptor } from "src/modules/adaptors/Swaap/SwaapFundAdaptor.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { FundWithShareLockFlashLoansWhitelisting } from "src/base/permutations/FundWithShareLockFlashLoansWhitelisting.sol";
import { IVault, IERC20, IFlashLoanRecipient } from "@balancer/interfaces/contracts/vault/IVault.sol";
import { FundWithBalancerFlashLoans } from "src/base/permutations/FundWithBalancerFlashLoans.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";

import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";

contract MockFundWithShareLockFlashLoansWhitelistingTest is MainnetStarterTest, AdaptorHelperFunctions {
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using stdStorage for StdStorage;

    MockFundWithShareLockFlashLoansWhitelisting private fund;

    MockDataFeed private mockUsdcUsd;
    MockDataFeed private mockWethUsd;
    MockDataFeed private mockWbtcUsd;

    SwaapFundAdaptor private swaapFundAdaptor;

    uint32 private usdcPosition = 1;
    uint32 private wethPosition = 2;
    uint32 private wbtcPosition = 3;

    uint256 private initialAssets;
    uint256 private initialShares;

    uint256 assets;
    uint256 shares;

    uint256 bobPrivateKey;
    uint256 alicePrivateKey;

    address bob;
    address alice;

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

        // Setup exchange rates:
        // USDC Simulated Price: $1
        // WETH Simulated Price: $2000
        // WBTC Simulated Price: $30,000
        mockUsdcUsd.setMockAnswer(1e8);
        mockWethUsd.setMockAnswer(2_000e8);
        mockWbtcUsd.setMockAnswer(30_000e8);

        // Add adaptors and ERC20 positions to the registry.
        registry.trustAdaptor(address(swaapFundAdaptor));
        registry.trustPosition(usdcPosition, address(erc20Adaptor), abi.encode(USDC));
        registry.trustPosition(wethPosition, address(erc20Adaptor), abi.encode(WETH));
        registry.trustPosition(wbtcPosition, address(erc20Adaptor), abi.encode(WBTC));

        // Create Fund.
        string memory fundName = "Share Lock Whitelist Fund V0.0";
        uint256 initialDeposit = 1e6;

        // Approve new fund to spend assets.
        address fundAddress = deployer.getAddress(fundName);
        deal(address(USDC), address(this), initialDeposit);
        USDC.approve(fundAddress, type(uint256).max);

        bytes memory creationCode;
        bytes memory constructorArgs;
        creationCode = type(MockFundWithShareLockFlashLoansWhitelisting).creationCode;
        constructorArgs = abi.encode(
            address(this),
            registry,
            USDC,
            fundName,
            fundName,
            usdcPosition,
            abi.encode(true),
            initialDeposit,
            type(uint192).max
        );

        fund = MockFundWithShareLockFlashLoansWhitelisting(
            deployer.deployContract(fundName, creationCode, constructorArgs)
        );

        // Set up remaining fund positions.
        fund.addPositionToCatalogue(wethPosition);
        fund.addPosition(1, wethPosition, abi.encode(true), false);
        fund.addPositionToCatalogue(wbtcPosition);
        fund.addPosition(2, wbtcPosition, abi.encode(true), false);

        // fund.setStrategistPayoutAddress(strategist);

        vm.label(address(fund), "fund");
        vm.label(strategist, "strategist");

        // Approve fund to spend all assets.
        USDC.approve(address(fund), type(uint256).max);

        initialAssets = fund.totalAssets();
        initialShares = fund.totalSupply();

        assets = 1e6;
        shares = 1e18;
        deal(address(USDC), address(this), assets + shares / assetToSharesDecimalsFactor);

        // Define private keys and their corresponding addresses
        bobPrivateKey = 0xB0B;
        alicePrivateKey = 0xA11CE;
        bob = vm.addr(bobPrivateKey);
        alice = vm.addr(alicePrivateKey);
    }

    function moveForwardAndUpdateOracle(uint256 delayTimestamp) internal {
        skip(delayTimestamp);
        mockUsdcUsd.setMockUpdatedAt(block.timestamp);
        mockWethUsd.setMockUpdatedAt(block.timestamp);
        mockWbtcUsd.setMockUpdatedAt(block.timestamp);
    }

    function getSignatureForFund(uint256 privateKey) internal view returns (bytes memory signature) {
        bytes32 digest = fund.getHashTypedDataV4(
            keccak256(abi.encode(fund.WHITELIST_TYPEHASH(), address(this), address(this), block.timestamp))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        signature = abi.encodePacked(r, s, v);
    }

    function testSetUpState() external {
        assertEq(fund.isWhitelistEnabled(), false, "Fund should have whitelist de activated");
    }

    function testWhitelistOff() external {
        uint256 shares_minted = fund.deposit(assets, address(this));
        assertEq(initialShares + shares_minted, fund.totalSupply(), "Fund should have minted shares");

        // // Mint the same quantity of shares. as the deposit
        uint256 assets_deposited = fund.mint(shares, address(this));
        assertEq(initialAssets + assets + assets_deposited, fund.totalAssets(), "Fund should have deposited assets");

        // Check for other fund methods
        fund.totalAssetsWithdrawable();
        // fund.callOnAdaptor(data);
        fund.maxWithdraw(address(this));
        fund.maxRedeem(address(this));

        uint256 assets_after_lock = fund.totalAssets();
        uint256 shares_after_lock = fund.totalSupply();

        // Go after ShareLock period
        moveForwardAndUpdateOracle(fund.shareLockPeriod());

        uint256 shares_burnt = fund.withdraw(assets, address(this), address(this));
        assertEq(assets_after_lock - assets, fund.totalAssets(), "Fund should have withdrawn assets");

        fund.redeem(shares, address(this), address(this));
        assertEq(shares_after_lock - shares_burnt - shares, fund.totalSupply(), "Fund should have redeemed shares");
    }

    function testWhitelistOnAndThenOff() external {
        fund.enableWhitelist();
        assertEq(fund.isWhitelistEnabled(), true, "Fund should have whitelist activated");

        fund.transferOwnership(bob);

        // Expect revert with regular deposit and mint
        vm.expectRevert(
            bytes(abi.encodeWithSelector(FundWithShareLockFlashLoansWhitelisting.Fund__WhitelistEnabled.selector))
        );
        fund.deposit(assets, address(this));

        vm.expectRevert(
            bytes(abi.encodeWithSelector(FundWithShareLockFlashLoansWhitelisting.Fund__WhitelistEnabled.selector))
        );
        fund.mint(shares, address(this));

        // Get signature
        bytes memory signature = getSignatureForFund(bobPrivateKey);

        // Whitelist deposit and mint should go through
        uint256 sharesMinted = fund.whitelistDeposit(assets, address(this), block.timestamp, signature);
        assertEq(initialAssets + assets, fund.totalAssets(), "Fund should have deposited assets");

        fund.whitelistMint(shares, address(this), block.timestamp, signature);
        assertEq(initialShares + sharesMinted + shares, fund.totalSupply(), "Fund should have minted shares");

        // Go after ShareLock period and check for withdraw and redeem with whitelist ON
        moveForwardAndUpdateOracle(fund.shareLockPeriod());
        assertEq(fund.isWhitelistEnabled(), true, "Fund should have whitelist activated");

        uint256 assets_after_lock = fund.totalAssets();
        uint256 shares_after_lock = fund.totalSupply();

        uint256 sharesBurned = fund.withdraw(assets, address(this), address(this));
        assertEq(assets_after_lock - assets, fund.totalAssets(), "Fund should have withdrawn assets");

        fund.redeem(shares, address(this), address(this));
        assertEq(shares_after_lock - sharesBurned - shares, fund.totalSupply(), "Fund should have redeemed shares");
    }

    function testSignatureVerificationAsFundOwner() external {
        fund.enableWhitelist();
        assertEq(fund.isWhitelistEnabled(), true, "Fund should have whitelist activated");

        // Set Bob as owner of the fund
        fund.transferOwnership(bob);

        // Get signatures for Alice and Bob
        bytes memory signatureCorrect = getSignatureForFund(bobPrivateKey);
        bytes memory signatureWrong = getSignatureForFund(alicePrivateKey);

        fund.mockVerifyWhitelistSignaturePublic(address(this), block.timestamp, signatureCorrect);

        vm.expectRevert(
            bytes(abi.encodeWithSelector(FundWithShareLockFlashLoansWhitelisting.Fund__InvalidSignature.selector))
        );
        fund.mockVerifyWhitelistSignaturePublic(address(this), block.timestamp, signatureWrong);
    }

    function testSignatureVerificationAsFundAutomationActions() external {
        fund.enableWhitelist();
        assertEq(fund.isWhitelistEnabled(), true, "Fund should have whitelist activated");

        // Set Bob as automationActions of the fund
        registry.register(bob);
        fund.setAutomationActions(3, bob);

        // Get signatures for Alice and Bob
        bytes memory signatureCorrect = getSignatureForFund(bobPrivateKey);
        bytes memory signatureWrong = getSignatureForFund(alicePrivateKey);

        fund.mockVerifyWhitelistSignaturePublic(address(this), block.timestamp, signatureCorrect);

        vm.expectRevert(
            bytes(abi.encodeWithSelector(FundWithShareLockFlashLoansWhitelisting.Fund__InvalidSignature.selector))
        );
        fund.mockVerifyWhitelistSignaturePublic(address(this), block.timestamp, signatureWrong);
    }

    function testWrongSignatureWhitelistOff() external view {
        uint256 whateverPrivateKey = 0x123;

        // Get signatures
        bytes memory signature = getSignatureForFund(whateverPrivateKey);

        fund.mockVerifyWhitelistSignaturePublic(address(this), block.timestamp, signature);
    }

    function testUserDelayAboveValidity() external {
        fund.enableWhitelist();
        assertEq(fund.isWhitelistEnabled(), true, "Fund should have whitelist activated");

        // Set Bob as owner of the fund

        fund.transferOwnership(bob);

        // Get signature
        bytes memory signature = getSignatureForFund(bobPrivateKey);
        uint256 timestampSignature = block.timestamp;

        // Last second to sign
        moveForwardAndUpdateOracle(fund.getExpirationDurationSignature());
        fund.mockVerifyWhitelistSignaturePublic(address(this), timestampSignature, signature);

        // Validity period of signature passed
        moveForwardAndUpdateOracle(1);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(FundWithShareLockFlashLoansWhitelisting.Fund__InvalidSignatureDeadline.selector)
            )
        );
        fund.mockVerifyWhitelistSignaturePublic(address(this), timestampSignature, signature);

        // Now disable whitelist and verification should pass
        vm.prank(bob);
        fund.disableWhitelist();
        assertEq(fund.isWhitelistEnabled(), false, "Fund should have whitelist de activated");

        fund.mockVerifyWhitelistSignaturePublic(address(this), timestampSignature, signature);
    }

    function testRandomUserTurnWhitelistOn() external {
        vm.prank(alice);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        fund.enableWhitelist();
    }

    function testRandomUserTurnWhitelistOff() external {
        vm.prank(alice);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        fund.disableWhitelist();
    }
}
