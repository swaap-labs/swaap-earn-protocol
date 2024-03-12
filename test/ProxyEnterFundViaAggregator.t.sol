// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

// Import Adaptors
import { MockFundWithShareLockFlashLoansWhitelisting } from "src/mocks/MockFundWithShareLockFlashLoansWhitelisting.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";

import { MockDataFeed } from "src/mocks/MockDataFeed.sol";
import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";
import { ProxyEnterFundViaAggregator } from "src/modules/ProxyEnterFundViaAggregator.sol";
import { SigUtils } from "src/utils/SigUtils.sol";

contract ProxyEnterFundViaAggregatorTest is MainnetStarterTest, AdaptorHelperFunctions {
    using SafeTransferLib for ERC20;
    using Math for uint256;

    MockFundWithShareLockFlashLoansWhitelisting public usdcFund;
    MockFundWithShareLockFlashLoansWhitelisting public wethFund;

    uint256 public usdcInitialDeposit = 1000e6;
    uint256 public wethInitialDeposit = 1 ether;

    uint32 private usdcPosition = 1;
    uint32 private wethPosition = 2;

    MockDataFeed private mockUsdcUsd;
    MockDataFeed private mockWethUsd;

    ProxyEnterFundViaAggregator private proxy;

    address private paraswap = 0xDEF171Fe48CF0115B1d80b88dc8eAB59176FEe57;
    address private paraswapSpender = 0x216B4B4Ba9F3e719726886d34a177484278Bfcae;
    address private oneInch = 0x111111125421cA6dc452d289314280a0f8842A65;
    address private odos = 0xCf5540fFFCdC3d510B18bFcA6d2b9987b0772559;
    address private zeroEx = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;

    bytes private swapCallDataEthToUsdc =
        hex"83800a8e000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc200000000000000000000000000000000000000000000000000038d7ea4c6800000000000000000000000000000000000000000000000000000000000002dc6c008000000000000003b6d0340b4e16d0168e52d35cacd2c6185b44281ec28c9dc8b1ccac8";
    uint256 private ethTokenIn = 0.001e18;

    // Paraswap swap calldata
    bytes private swapCallDataUsdcToWeth =
        hex"0b86a4c1000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000000009896800000000000000000000000000000000000000000000000000000000001c23549000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000001000000000000000000004de46e1fbeeaba87bae1100d95f8340dc27ad7c8427b";

    uint256 private usdcTokenIn = 10e6;
    uint256 private alicePrivateKey = 0xa11ce;
    uint256 private bobPrivateKey = 0xb0b;

    uint256 private _receivedEth;

    function setUp() public {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 19412443;
        _startFork(rpcKey, blockNumber);

        // Run Starter setUp code.
        _setUp();

        uint256 price;
        PriceRouter.AssetSettings memory settings;
        PriceRouter.ChainlinkDerivativeStorage memory stor;

        mockUsdcUsd = new MockDataFeed(USDC_USD_FEED);
        mockWethUsd = new MockDataFeed(WETH_USD_FEED);

        price = uint256(mockUsdcUsd.latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, address(mockUsdcUsd));
        priceRouter.addAsset(USDC, settings, abi.encode(stor), price);

        price = uint256(mockWethUsd.latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, address(mockWethUsd));
        priceRouter.addAsset(WETH, settings, abi.encode(stor), price);

        // Deploy the ETH Fund contract.
        registry.trustPosition(usdcPosition, address(erc20Adaptor), abi.encode(USDC));
        registry.trustPosition(wethPosition, address(erc20Adaptor), abi.encode(WETH));

        deal(address(USDC), address(this), usdcInitialDeposit);
        usdcFund = _createMockFundWithShareLockFlashLoansWhitelisting(
            "USDC fund",
            USDC,
            usdcPosition,
            abi.encode(true),
            usdcInitialDeposit
        );

        deal(address(WETH), address(this), wethInitialDeposit);
        wethFund = _createMockFundWithShareLockFlashLoansWhitelisting(
            "ETH fund",
            WETH,
            wethPosition,
            abi.encode(true),
            wethInitialDeposit
        );

        // deploy the Proxy
        proxy = new ProxyEnterFundViaAggregator(
            address(0), // new owner
            address(WETH),
            paraswap,
            oneInch,
            odos,
            zeroEx
        );

        registry.setApprovedForDepositOnBehalf(address(proxy), true);

        // set alice as the automationActions of the funds
        address alice = vm.addr(alicePrivateKey);
        registry.register(alice);
        usdcFund.setAutomationActions(3, alice);
        wethFund.setAutomationActions(3, alice);
    }

    function testSwapERC20AndDeposit() public {
        uint256 maxAmountToUse = usdcTokenIn + 1 wei;

        ProxyEnterFundViaAggregator.Quote memory fillQuote = ProxyEnterFundViaAggregator.Quote(
            paraswap,
            paraswapSpender,
            0, // buyAmount,
            swapCallDataUsdcToWeth
        );

        deal(address(USDC), address(this), maxAmountToUse);
        USDC.approve(address(proxy), maxAmountToUse);

        uint256 sharesBalanceBefore = wethFund.balanceOf(address(this));

        uint256 reportedReceivedShares = proxy.depositViaAggregator(
            address(wethFund),
            address(USDC),
            maxAmountToUse,
            0, // minSharesOut
            type(uint256).max, // deadline
            fillQuote
        );

        uint256 sharesBalanceAfter = wethFund.balanceOf(address(this));

        assertGt(sharesBalanceAfter - sharesBalanceBefore, 0, "User should receive some shares after deposit");

        assertEq(
            sharesBalanceAfter - sharesBalanceBefore,
            reportedReceivedShares,
            "Shares minted should be as reported"
        );

        assertEq(USDC.balanceOf(address(this)), maxAmountToUse - usdcTokenIn, "User should hold the remaining USDC");

        assertEq(USDC.balanceOf(address(proxy)), 0, "Proxy should not hold any USDC after deposit");
        assertEq(WETH.balanceOf(address(proxy)), 0, "Proxy should not hold any WETH after deposit");
        assertEq(wethFund.balanceOf(address(proxy)), 0, "Proxy should not hold any shares after deposit");
    }

    function testSwapERC20AndWhitelistDeposit() public {
        uint256 maxAmountToUse = usdcTokenIn + 1 wei;

        ProxyEnterFundViaAggregator.Quote memory fillQuote = ProxyEnterFundViaAggregator.Quote(
            paraswap,
            paraswapSpender,
            0, // buyAmount,
            swapCallDataUsdcToWeth
        );

        deal(address(USDC), address(this), maxAmountToUse);
        USDC.approve(address(proxy), maxAmountToUse);

        uint256 sharesBalanceBefore = wethFund.balanceOf(address(this));

        bytes memory signature = _getWhitelistSignatureForFund(wethFund, alicePrivateKey);

        wethFund.enableWhitelist();

        uint256 reportedReceivedShares = proxy.whitelistDepositViaAggregator(
            address(wethFund),
            address(USDC),
            maxAmountToUse,
            0, // minSharesOut
            type(uint256).max, // deadline
            fillQuote,
            block.timestamp, // signedAt,
            signature
        );

        uint256 sharesBalanceAfter = wethFund.balanceOf(address(this));

        assertGt(sharesBalanceAfter - sharesBalanceBefore, 0, "User should receive some shares after deposit");

        assertEq(
            sharesBalanceAfter - sharesBalanceBefore,
            reportedReceivedShares,
            "Shares minted should be as reported"
        );

        assertEq(USDC.balanceOf(address(this)), maxAmountToUse - usdcTokenIn, "User should hold the remaining USDC");

        assertEq(USDC.balanceOf(address(proxy)), 0, "Proxy should not hold any USDC after deposit");
        assertEq(WETH.balanceOf(address(proxy)), 0, "Proxy should not hold any WETH after deposit");
        assertEq(wethFund.balanceOf(address(proxy)), 0, "Proxy should not hold any shares after deposit");
    }

    function testSwapETHAndDeposit() public {
        uint256 maxAmountToUse = ethTokenIn + 1 wei;

        ProxyEnterFundViaAggregator.Quote memory fillQuote = ProxyEnterFundViaAggregator.Quote(
            oneInch,
            oneInch,
            0, // buyAmount,
            swapCallDataEthToUsdc
        );

        uint256 sharesBalanceBefore = usdcFund.balanceOf(address(this));

        uint256 reportedReceivedShares = proxy.depositViaAggregator{ value: maxAmountToUse }(
            address(usdcFund),
            address(0),
            maxAmountToUse,
            0, // minSharesOut
            type(uint256).max, // deadline
            fillQuote
        );

        uint256 sharesBalanceAfter = usdcFund.balanceOf(address(this));

        assertGt(
            sharesBalanceAfter - sharesBalanceBefore,
            0,
            "User should receive some shares after whitelist deposit"
        );

        assertEq(
            sharesBalanceAfter - sharesBalanceBefore,
            reportedReceivedShares,
            "Shares minted should be as reported"
        );

        assertEq(_receivedEth, maxAmountToUse - ethTokenIn, "User should hold the remaining ETH");

        assertEq(USDC.balanceOf(address(proxy)), 0, "Proxy should not hold any USDC after deposit");
        assertEq(WETH.balanceOf(address(proxy)), 0, "Proxy should not hold any WETH after deposit");
        assertEq(usdcFund.balanceOf(address(proxy)), 0, "Proxy should not hold any shares after deposit");
        assertEq(address(proxy).balance, 0, "Proxy should not hold any ETH after deposit");
    }

    function testSwapETHAndMint() public {
        uint256 maxAmountToUse = ethTokenIn + 1 wei;

        ProxyEnterFundViaAggregator.Quote memory fillQuote = ProxyEnterFundViaAggregator.Quote(
            oneInch,
            oneInch,
            0, // buyAmount,
            swapCallDataEthToUsdc
        );

        uint256 sharesBalanceBefore = usdcFund.balanceOf(address(this));

        uint256 expectedReceivedShares = 1e18; // <==> 1 USDC (1e6 decimals)

        uint256 reportedUsedAssets = proxy.mintViaAggregator{ value: maxAmountToUse }(
            address(usdcFund),
            address(0),
            maxAmountToUse,
            expectedReceivedShares,
            type(uint256).max, // deadline
            fillQuote
        );

        uint256 sharesBalanceAfter = usdcFund.balanceOf(address(this));

        assertEq(
            sharesBalanceAfter - sharesBalanceBefore,
            expectedReceivedShares,
            "Shares minted should be as expected"
        );

        assertEq(reportedUsedAssets * 1e12, expectedReceivedShares, "User should receive the correct amount of Shares");

        assertEq(_receivedEth, maxAmountToUse - ethTokenIn, "User should hold the remaining ETH");
        assertGt(USDC.balanceOf(address(this)), 0, "User should hold the remaining USDC");

        assertEq(USDC.balanceOf(address(proxy)), 0, "Proxy should not hold any USDC after deposit");
        assertEq(WETH.balanceOf(address(proxy)), 0, "Proxy should not hold any WETH after deposit");
        assertEq(usdcFund.balanceOf(address(proxy)), 0, "Proxy should not hold any shares after deposit");
    }

    function testSwapERC20AndMint() public {
        uint256 maxAmountToUse = usdcTokenIn + 1 wei;

        ProxyEnterFundViaAggregator.Quote memory fillQuote = ProxyEnterFundViaAggregator.Quote(
            paraswap,
            paraswapSpender,
            0, // minBuyAmount,
            swapCallDataUsdcToWeth
        );

        deal(address(USDC), address(this), maxAmountToUse);
        USDC.approve(address(proxy), maxAmountToUse);

        uint256 sharesBalanceBefore = wethFund.balanceOf(address(this));

        uint256 expectedReceivedShares = 1e14;

        uint256 reportedUsedAssets = proxy.mintViaAggregator(
            address(wethFund),
            address(USDC),
            maxAmountToUse,
            expectedReceivedShares, // sharesOut
            type(uint256).max, // deadline
            fillQuote
        );

        uint256 sharesBalanceAfter = wethFund.balanceOf(address(this));

        assertEq(
            sharesBalanceAfter - sharesBalanceBefore,
            expectedReceivedShares,
            "Shares minted should be as expected"
        );

        assertEq(reportedUsedAssets, expectedReceivedShares, "User should hold the remaining USDC");

        assertEq(USDC.balanceOf(address(this)), maxAmountToUse - usdcTokenIn, "User should hold the remaining USDC");

        assertEq(USDC.balanceOf(address(proxy)), 0, "Proxy should not hold any USDC after deposit");
        assertEq(WETH.balanceOf(address(proxy)), 0, "Proxy should not hold any WETH after deposit");
        assertEq(wethFund.balanceOf(address(proxy)), 0, "Proxy should not hold any shares after deposit");
    }

    function testSwapERC20AndWhitelistMint() public {
        uint256 maxAmountToUse = usdcTokenIn + 1 wei;

        ProxyEnterFundViaAggregator.Quote memory fillQuote = ProxyEnterFundViaAggregator.Quote(
            paraswap,
            paraswapSpender,
            0, // minBuyAmount,
            swapCallDataUsdcToWeth
        );

        deal(address(USDC), address(this), maxAmountToUse);
        USDC.approve(address(proxy), maxAmountToUse);

        uint256 sharesBalanceBefore = wethFund.balanceOf(address(this));

        uint256 expectedReceivedShares = 1e14;

        wethFund.enableWhitelist();
        bytes memory signature = _getWhitelistSignatureForFund(wethFund, alicePrivateKey);

        uint256 reportedUsedAssets = proxy.whitelistMintViaAggregator(
            address(wethFund),
            address(USDC),
            maxAmountToUse,
            expectedReceivedShares, // sharesOut
            type(uint256).max, // deadline
            fillQuote,
            block.timestamp, // signedAt,
            signature
        );

        uint256 sharesBalanceAfter = wethFund.balanceOf(address(this));

        assertEq(
            sharesBalanceAfter - sharesBalanceBefore,
            expectedReceivedShares,
            "Shares minted should be as expected"
        );

        assertEq(reportedUsedAssets, expectedReceivedShares, "User should hold the remaining USDC");

        assertEq(USDC.balanceOf(address(this)), maxAmountToUse - usdcTokenIn, "User should hold the remaining USDC");

        assertEq(USDC.balanceOf(address(proxy)), 0, "Proxy should not hold any USDC after deposit");
        assertEq(WETH.balanceOf(address(proxy)), 0, "Proxy should not hold any WETH after deposit");
        assertEq(wethFund.balanceOf(address(proxy)), 0, "Proxy should not hold any shares after deposit");
    }

    function testDepositETHWithoutSwapping() public {
        uint256 maxAmountToUse = wethInitialDeposit / 2;

        uint256 sharesBalanceBefore = wethFund.balanceOf(address(this));

        uint256 reportedReceivedShares = proxy.depositViaAggregator{ value: maxAmountToUse }(
            address(wethFund),
            address(0),
            maxAmountToUse,
            0, // minSharesOut
            type(uint256).max, // deadline
            ProxyEnterFundViaAggregator.Quote(address(0), address(0), 0, "")
        );

        uint256 sharesBalanceAfter = wethFund.balanceOf(address(this));

        assertGt(sharesBalanceAfter - sharesBalanceBefore, 0, "User should receive some shares after deposit");

        assertEq(
            sharesBalanceAfter - sharesBalanceBefore,
            reportedReceivedShares,
            "Shares minted should be as reported"
        );

        assertEq(sharesBalanceAfter - sharesBalanceBefore, maxAmountToUse, "Shares minted should be as expected");

        assertEq(address(proxy).balance, 0, "Proxy should not hold any ETH after deposit");
        assertEq(WETH.balanceOf(address(proxy)), 0, "Proxy should not hold any WETH after deposit");
        assertEq(wethFund.balanceOf(address(proxy)), 0, "Proxy should not hold any shares after deposit");
    }

    function testMulticallPermitSwapAndMint() public {}

    function testMintWithoutSwapping() public {}

    function testMulticallPermitSwapAndDeposit() public {
        uint256 maxAmountToUse = usdcTokenIn + 1 wei;

        address bob = vm.addr(bobPrivateKey);
        vm.startPrank(bob);

        uint256 permitDeadline = block.timestamp + 1000;

        bytes[] memory multicallData = new bytes[](2);

        bytes memory erc20PermitProxyCallData = _getERC20PermitProxyCallData(
            USDC,
            bobPrivateKey,
            maxAmountToUse,
            permitDeadline
        );

        multicallData[0] = erc20PermitProxyCallData;

        // (bool success, ) = address(proxy).call{ value: 0 }(erc20PermitProxyCallData);
        // assertEq(success, true, "Proxy should be able to call permit");
        // assertEq(USDC.allowance(bob, address(proxy)), maxAmountToUse, "Proxy should be allowed to spend USDC");

        ProxyEnterFundViaAggregator.Quote memory fillQuote = ProxyEnterFundViaAggregator.Quote(
            paraswap,
            paraswapSpender,
            0, // buyAmount,
            swapCallDataUsdcToWeth
        );

        deal(address(USDC), bob, maxAmountToUse);

        uint256 sharesBalanceBefore = wethFund.balanceOf(bob);

        multicallData[1] = abi.encodeWithSelector(
            ProxyEnterFundViaAggregator.depositViaAggregator.selector,
            address(wethFund),
            address(USDC),
            maxAmountToUse,
            0, // minSharesOut
            type(uint256).max, // deadline
            fillQuote
        );

        proxy.multicall(multicallData);

        uint256 sharesBalanceAfter = wethFund.balanceOf(bob);

        assertGt(
            sharesBalanceAfter - sharesBalanceBefore,
            0,
            "User should receive some shares after permit and deposit"
        );

        assertEq(USDC.balanceOf(bob), maxAmountToUse - usdcTokenIn, "User should hold the remaining USDC");

        assertEq(USDC.balanceOf(address(proxy)), 0, "Proxy should not hold any USDC after deposit");
        assertEq(WETH.balanceOf(address(proxy)), 0, "Proxy should not hold any WETH after deposit");
        assertEq(wethFund.balanceOf(address(proxy)), 0, "Proxy should not hold any shares after deposit");
    }

    function _createMockFundWithShareLockFlashLoansWhitelisting(
        string memory fundName,
        ERC20 holdingAsset,
        uint32 holdingPosition,
        bytes memory holdingPositionConfig,
        uint256 initialDeposit
    ) internal returns (MockFundWithShareLockFlashLoansWhitelisting) {
        // Approve new fund to spend assets.
        address fundAddress = deployer.getAddress(fundName);
        deal(address(holdingAsset), address(this), initialDeposit);
        holdingAsset.approve(fundAddress, initialDeposit);

        bytes memory creationCode;
        bytes memory constructorArgs;
        creationCode = type(MockFundWithShareLockFlashLoansWhitelisting).creationCode;
        constructorArgs = abi.encode(
            address(this),
            registry,
            holdingAsset,
            fundName,
            fundName,
            holdingPosition,
            holdingPositionConfig,
            initialDeposit,
            type(uint192).max
        );

        return
            MockFundWithShareLockFlashLoansWhitelisting(
                deployer.deployContract(fundName, creationCode, constructorArgs)
            );
    }

    function _getERC20PermitProxyCallData(
        ERC20 token,
        uint256 ownerPrivateKey,
        uint256 value,
        uint256 deadline
    ) internal returns (bytes memory erc20PermitProxyCallData) {
        bytes32 DOMAIN_SEPARATOR = token.DOMAIN_SEPARATOR();
        SigUtils sigUtils = new SigUtils(DOMAIN_SEPARATOR);

        address owner = vm.addr(ownerPrivateKey);
        uint256 nonce = token.nonces(owner);

        SigUtils.Permit memory permit = SigUtils.Permit(owner, address(proxy), value, nonce, deadline);
        bytes32 digest = sigUtils.getTypedDataHash(permit);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        return
            abi.encodeWithSelector(
                ProxyEnterFundViaAggregator.permitERC20ToProxy.selector,
                address(token),
                value,
                deadline,
                v,
                r,
                s
            );
    }

    function _getWhitelistSignatureForFund(
        MockFundWithShareLockFlashLoansWhitelisting mockFund,
        uint256 privateKey
    ) internal view returns (bytes memory signature) {
        bytes32 digest = mockFund.getHashTypedDataV4(
            keccak256(abi.encode(mockFund.WHITELIST_TYPEHASH(), address(proxy), address(this), block.timestamp))
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        signature = abi.encodePacked(r, s, v);
    }

    // let's the test contract to receive leftover ether from the proxy
    receive() external payable {
        _receivedEth = msg.value; // track how much ether was received
    }
}
