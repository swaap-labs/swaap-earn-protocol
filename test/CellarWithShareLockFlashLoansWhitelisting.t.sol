// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { MockDataFeed } from "src/mocks/MockDataFeed.sol";
import { MockCellarWithShareLockFlashLoansWhitelisting } from "src/mocks/MockCellarWithShareLockFlashLoansWhitelisting.sol";
import { CellarAdaptor } from "src/modules/adaptors/Sommelier/CellarAdaptor.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { CellarWithShareLockFlashLoansWhitelisting } from "src/base/permutations/CellarWithShareLockFlashLoansWhitelisting.sol";
import { IVault, IERC20, IFlashLoanRecipient } from "@balancer/interfaces/contracts/vault/IVault.sol";
import { CellarWithBalancerFlashLoans } from "src/base/permutations/CellarWithBalancerFlashLoans.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";

import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";

contract MockCellarWithShareLockFlashLoansWhitelistingTest is MainnetStarterTest, AdaptorHelperFunctions {
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using stdStorage for StdStorage;

    MockCellarWithShareLockFlashLoansWhitelisting private cellar;

    MockDataFeed private mockUsdcUsd;
    MockDataFeed private mockWethUsd;
    MockDataFeed private mockWbtcUsd;

    CellarAdaptor private cellarAdaptor;

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
        cellarAdaptor = new CellarAdaptor();

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
        registry.trustAdaptor(address(cellarAdaptor));
        registry.trustPosition(usdcPosition, address(erc20Adaptor), abi.encode(USDC));
        registry.trustPosition(wethPosition, address(erc20Adaptor), abi.encode(WETH));
        registry.trustPosition(wbtcPosition, address(erc20Adaptor), abi.encode(WBTC));

        // Create Cellar.
        string memory cellarName = "Share Lock Whitelist Cellar V0.0";
        uint256 initialDeposit = 1e6;

        // Approve new cellar to spend assets.
        address cellarAddress = deployer.getAddress(cellarName);
        deal(address(USDC), address(this), initialDeposit);
        USDC.approve(cellarAddress, type(uint256).max);

        bytes memory creationCode;
        bytes memory constructorArgs;
        creationCode = type(MockCellarWithShareLockFlashLoansWhitelisting).creationCode;
        constructorArgs = abi.encode(
            address(this),
            registry,
            USDC,
            cellarName,
            cellarName,
            usdcPosition,
            abi.encode(true),
            initialDeposit,
            type(uint192).max
        );

        cellar = MockCellarWithShareLockFlashLoansWhitelisting(
            deployer.deployContract(cellarName, creationCode, constructorArgs, 0)
        );

        // Set up remaining cellar positions.
        cellar.addPositionToCatalogue(wethPosition);
        cellar.addPosition(1, wethPosition, abi.encode(true), false);
        cellar.addPositionToCatalogue(wbtcPosition);
        cellar.addPosition(2, wbtcPosition, abi.encode(true), false);

        // cellar.setStrategistPayoutAddress(strategist);

        vm.label(address(cellar), "cellar");
        vm.label(strategist, "strategist");

        // Approve cellar to spend all assets.
        USDC.approve(address(cellar), type(uint256).max);

        initialAssets = cellar.totalAssets();
        initialShares = cellar.totalSupply();

        assets = 1e6;
        shares = 1e6;
        deal(address(USDC), address(this), assets + shares);

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

    function getSignatureForCellar(uint256 privateKey) internal view returns (bytes memory signature) {
        bytes32 digest = cellar.getHashTypedDataV4(
            keccak256(abi.encode(cellar.WHITELIST_TYPEHASH(), address(this), address(this), block.timestamp))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        signature = abi.encodePacked(r, s, v);
    }

    function testSetUpState() external {
        assertEq(cellar.isWhitelistEnabled(), false, "Cellar should have whitelist de activated");
    }

    function testWhitelistOff() external {
        uint256 shares_minted = cellar.deposit(assets, address(this));
        assertEq(initialShares + shares_minted, cellar.totalSupply(), "Cellar should have minted shares");

        // // Mint the same quantity of shares. as the deposit
        uint256 assets_deposited = cellar.mint(shares, address(this));
        assertEq(
            initialAssets + assets + assets_deposited,
            cellar.totalAssets(),
            "Cellar should have deposited assets"
        );

        // Check for other cellar methods
        cellar.totalAssetsWithdrawable();
        // cellar.callOnAdaptor(data);
        cellar.maxWithdraw(address(this));
        cellar.maxRedeem(address(this));

        uint256 assets_after_lock = cellar.totalAssets();
        uint256 shares_after_lock = cellar.totalSupply();

        // Go after ShareLock period
        moveForwardAndUpdateOracle(cellar.shareLockPeriod());

        uint256 shares_burnt = cellar.withdraw(assets, address(this), address(this));
        assertEq(assets_after_lock - assets, cellar.totalAssets(), "Cellar should have withdrawn assets");

        cellar.redeem(shares, address(this), address(this));
        assertEq(shares_after_lock - shares_burnt - shares, cellar.totalSupply(), "Cellar should have redeemed shares");
    }

    function testWhitelistOnAndThenOff() external {
        cellar.enableWhitelist();
        assertEq(cellar.isWhitelistEnabled(), true, "Cellar should have whitelist activated");

        cellar.transferOwnership(bob);

        // Expect revert with regular deposit and mint
        vm.expectRevert(
            bytes(abi.encodeWithSelector(CellarWithShareLockFlashLoansWhitelisting.Cellar__WhitelistEnabled.selector))
        );
        cellar.deposit(assets, address(this));

        vm.expectRevert(
            bytes(abi.encodeWithSelector(CellarWithShareLockFlashLoansWhitelisting.Cellar__WhitelistEnabled.selector))
        );
        cellar.mint(shares, address(this));

        // Get signature
        bytes memory signature = getSignatureForCellar(bobPrivateKey);

        // Whitelist deposit and mint should go through
        uint256 sharesMinted = cellar.whitelistDeposit(assets, address(this), block.timestamp, signature);
        assertEq(initialAssets + assets, cellar.totalAssets(), "Cellar should have deposited assets");

        cellar.whitelistMint(shares, address(this), block.timestamp, signature);
        assertEq(initialShares + sharesMinted + shares, cellar.totalSupply(), "Cellar should have minted shares");

        // Go after ShareLock period and check for withdraw and redeem with whitelist ON
        moveForwardAndUpdateOracle(cellar.shareLockPeriod());
        assertEq(cellar.isWhitelistEnabled(), true, "Cellar should have whitelist activated");

        uint256 assets_after_lock = cellar.totalAssets();
        uint256 shares_after_lock = cellar.totalSupply();

        uint256 sharesBurned = cellar.withdraw(assets, address(this), address(this));
        assertEq(assets_after_lock - assets, cellar.totalAssets(), "Cellar should have withdrawn assets");

        cellar.redeem(shares, address(this), address(this));
        assertEq(shares_after_lock - sharesBurned - shares, cellar.totalSupply(), "Cellar should have redeemed shares");
    }

    function testSignatureVerificationAsCellarOwner() external {
        cellar.enableWhitelist();
        assertEq(cellar.isWhitelistEnabled(), true, "Cellar should have whitelist activated");

        // Set Bob as owner of the cellar
        cellar.transferOwnership(bob);

        // Get signatures for Alice and Bob
        bytes memory signatureCorrect = getSignatureForCellar(bobPrivateKey);
        bytes memory signatureWrong = getSignatureForCellar(alicePrivateKey);

        cellar.mockVerifyWhitelistSignaturePublic(address(this), block.timestamp, signatureCorrect);

        vm.expectRevert(
            bytes(abi.encodeWithSelector(CellarWithShareLockFlashLoansWhitelisting.Cellar__InvalidSignature.selector))
        );
        cellar.mockVerifyWhitelistSignaturePublic(address(this), block.timestamp, signatureWrong);
    }

    function testSignatureVerificationAsCellarAutomationActions() external {
        cellar.enableWhitelist();
        assertEq(cellar.isWhitelistEnabled(), true, "Cellar should have whitelist activated");

        // Set Bob as automationActions of the cellar
        registry.register(bob);
        cellar.setAutomationActions(3, bob);

        // Get signatures for Alice and Bob
        bytes memory signatureCorrect = getSignatureForCellar(bobPrivateKey);
        bytes memory signatureWrong = getSignatureForCellar(alicePrivateKey);

        cellar.mockVerifyWhitelistSignaturePublic(address(this), block.timestamp, signatureCorrect);

        vm.expectRevert(
            bytes(abi.encodeWithSelector(CellarWithShareLockFlashLoansWhitelisting.Cellar__InvalidSignature.selector))
        );
        cellar.mockVerifyWhitelistSignaturePublic(address(this), block.timestamp, signatureWrong);
    }

    function testWrongSignatureWhitelistOff() external view {
        uint256 whateverPrivateKey = 0x123;

        // Get signatures
        bytes memory signature = getSignatureForCellar(whateverPrivateKey);

        cellar.mockVerifyWhitelistSignaturePublic(address(this), block.timestamp, signature);
    }

    function testUserDelayAboveValidity() external {
        cellar.enableWhitelist();
        assertEq(cellar.isWhitelistEnabled(), true, "Cellar should have whitelist activated");

        // Set Bob as owner of the cellar

        cellar.transferOwnership(bob);

        // Get signature
        bytes memory signature = getSignatureForCellar(bobPrivateKey);
        uint256 timestampSignature = block.timestamp;

        // Last second to sign
        moveForwardAndUpdateOracle(cellar.getExpirationDurationSignature());
        cellar.mockVerifyWhitelistSignaturePublic(address(this), timestampSignature, signature);

        // Validity period of signature passed
        moveForwardAndUpdateOracle(1);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    CellarWithShareLockFlashLoansWhitelisting.Cellar__InvalidSignatureDeadline.selector
                )
            )
        );
        cellar.mockVerifyWhitelistSignaturePublic(address(this), timestampSignature, signature);

        // Now disable whitelist and verification should pass
        vm.prank(bob);
        cellar.disableWhitelist();
        assertEq(cellar.isWhitelistEnabled(), false, "Cellar should have whitelist de activated");

        cellar.mockVerifyWhitelistSignaturePublic(address(this), timestampSignature, signature);
    }

    function testRandomUserTurnWhitelistOn() external {
        vm.prank(alice);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        cellar.enableWhitelist();
    }

    function testRandomUserTurnWhitelistOff() external {
        vm.prank(alice);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        cellar.disableWhitelist();
    }
}
