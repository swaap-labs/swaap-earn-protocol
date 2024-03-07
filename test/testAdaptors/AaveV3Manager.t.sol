// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { AaveV3ATokenManagerAdaptor } from "src/modules/adaptors/Aave/V3/AaveV3ATokenManagerAdaptor.sol";
import { AaveV3DebtManagerAdaptor } from "src/modules/adaptors/Aave/V3/AaveV3DebtManagerAdaptor.sol";
import { AaveV3AccountExtension } from "src/modules/adaptors/Aave/V3/AaveV3AccountExtension.sol";
import { BaseAdaptor } from "src/modules/adaptors/BaseAdaptor.sol";

import { IPoolV3 } from "src/interfaces/external/IPoolV3.sol";

import { FundWithAaveFlashLoans } from "src/base/permutations/FundWithAaveFlashLoans.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";

import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";

contract FundAaveV3Test is MainnetStarterTest, AdaptorHelperFunctions {
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using stdStorage for StdStorage;

    AaveV3ATokenManagerAdaptor private aaveATokenManagerAdaptor;
    AaveV3DebtManagerAdaptor private aaveDebtManagerAdaptor;
    FundWithAaveFlashLoans private fund;

    IPoolV3 private pool = IPoolV3(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    address private aaveOracle = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;

    uint32 private usdcPosition = 1;
    uint32 private aV3USDCPosition = 1_000_001;
    uint32 private debtUSDCPosition = 1_000_002;
    uint32 private aV3WETHPosition = 1_000_003;
    uint32 private aV3WBTCPosition = 1_000_004;
    uint32 private debtWETHPosition = 1_000_005;

    uint32 private aV3WETHPositionEmode = 10_000_001;
    uint32 private debtWETHPositionEmode = 10_000_002;

    uint8 private constant DEFAULT_ACCOUNT = 0;
    uint8 private constant ACCOUNT_EMODE_ONE = 1;

    function setUp() external {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 16700000;
        _startFork(rpcKey, blockNumber);

        // Run Starter setUp code.
        _setUp();

        aaveATokenManagerAdaptor = new AaveV3ATokenManagerAdaptor(address(pool), aaveOracle, 1.05e18);
        aaveDebtManagerAdaptor = new AaveV3DebtManagerAdaptor(address(pool), 1.05e18);

        PriceRouter.ChainlinkDerivativeStorage memory stor;

        PriceRouter.AssetSettings memory settings;

        uint256 price = uint256(IChainlinkAggregator(WETH_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, WETH_USD_FEED);
        priceRouter.addAsset(WETH, settings, abi.encode(stor), price);

        price = uint256(IChainlinkAggregator(USDC_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, USDC_USD_FEED);
        priceRouter.addAsset(USDC, settings, abi.encode(stor), price);

        price = uint256(IChainlinkAggregator(DAI_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, DAI_USD_FEED);
        priceRouter.addAsset(DAI, settings, abi.encode(stor), price);

        price = uint256(IChainlinkAggregator(WBTC_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, WBTC_USD_FEED);
        priceRouter.addAsset(WBTC, settings, abi.encode(stor), price);

        // Setup Fund:

        // Add adaptors and positions to the registry.
        registry.trustAdaptor(address(aaveATokenManagerAdaptor));
        registry.trustAdaptor(address(aaveDebtManagerAdaptor));

        registry.trustPosition(usdcPosition, address(erc20Adaptor), abi.encode(USDC));
        registry.trustPosition(
            aV3USDCPosition,
            address(aaveATokenManagerAdaptor),
            abi.encode(DEFAULT_ACCOUNT, address(aV3USDC))
        );
        registry.trustPosition(
            debtUSDCPosition,
            address(aaveDebtManagerAdaptor),
            abi.encode(DEFAULT_ACCOUNT, address(dV3USDC))
        );

        uint256 minHealthFactor = 1.1e18;

        string memory fundName = "AAVE Debt Fund V0.0";
        uint256 initialDeposit = 1e6;

        // Approve new fund to spend assets.
        address fundAddress = deployer.getAddress(fundName);
        deal(address(USDC), address(this), initialDeposit);
        USDC.approve(fundAddress, initialDeposit);

        bytes memory creationCode = type(FundWithAaveFlashLoans).creationCode;
        bytes memory constructorArgs = abi.encode(
            address(this),
            registry,
            USDC,
            fundName,
            fundName,
            aV3USDCPosition,
            abi.encode(minHealthFactor),
            initialDeposit,
            type(uint192).max,
            address(pool)
        );

        fund = FundWithAaveFlashLoans(deployer.deployContract(fundName, creationCode, constructorArgs, 0));

        fund.addAdaptorToCatalogue(address(aaveATokenManagerAdaptor));
        fund.addAdaptorToCatalogue(address(aaveDebtManagerAdaptor));
        fund.addAdaptorToCatalogue(address(swapWithUniswapAdaptor));

        fund.addPositionToCatalogue(usdcPosition);
        fund.addPositionToCatalogue(debtUSDCPosition);

        fund.addPosition(1, usdcPosition, abi.encode(0), false);
        fund.addPosition(0, debtUSDCPosition, abi.encode(0), true);

        USDC.safeApprove(address(fund), type(uint256).max);

        fund.setRebalanceDeviation(0.005e18);
    }

    function testDefaultAaveAccountDeployedOnInitDeposit() external {
        // Test that the account 0 was deployed on contract creation.

        address account0 = _getAccountAddress(DEFAULT_ACCOUNT);

        // assert that the account was deployed in the setup.
        assertTrue(Address.isContract(account0), "Account 0 should be a contract.");
        assertEq(AaveV3AccountExtension(account0).fund(), address(fund), "Fund should be the owner of the account.");
    }

    event AccountExtensionCreated(uint8 indexed accountId, address accountAddress);

    function testCreateAaveAccountExtension() external {
        address account1 = _getAccountAddress(ACCOUNT_EMODE_ONE);

        assertFalse(Address.isContract(account1), "Account 1 should not be a contract yet.");

        registry.trustPosition(
            aV3WETHPositionEmode,
            address(aaveATokenManagerAdaptor),
            abi.encode(ACCOUNT_EMODE_ONE, address(aV3WETH))
        );
        fund.addPositionToCatalogue(aV3WETHPositionEmode);
        fund.addPosition(2, aV3WETHPositionEmode, abi.encode(0), false);

        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _createBytesDataToCreateAaveAccount(ACCOUNT_EMODE_ONE, address(aV3WETH));

        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);

        data[0] = Fund.AdaptorCall({ adaptor: address(aaveATokenManagerAdaptor), callData: adaptorCalls });

        vm.expectEmit();
        emit AccountExtensionCreated(ACCOUNT_EMODE_ONE, account1);

        fund.callOnAdaptor(data);

        assertTrue(Address.isContract(account1), "Account 1 should be a contract.");

        uint256 account1Emode = pool.getUserEMode(account1);

        assertEq(account1Emode, 1, "Account 1 should be in EMode 1.");
    }

    function testRevertWhenDeployAaveAccountWithIncorrectData() external {
        address account1 = _getAccountAddress(ACCOUNT_EMODE_ONE);

        assertFalse(Address.isContract(account1), "Account 1 should not be a contract yet.");

        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _createBytesDataToCreateAaveAccount(ACCOUNT_EMODE_ONE, address(aV3USDC));

        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);

        data[0] = Fund.AdaptorCall({ adaptor: address(aaveATokenManagerAdaptor), callData: adaptorCalls });

        vm.expectRevert(
            abi.encodeWithSelector(
                BaseAdaptor.BaseAdaptor__PositionNotUsed.selector,
                abi.encode(ACCOUNT_EMODE_ONE, address(aV3USDC))
            )
        );

        fund.callOnAdaptor(data);
    }

    function testDeposit(uint256 assets) external {
        uint256 initialAssets = fund.totalAssets();
        assets = bound(assets, 0.1e6, 1_000_000e6);
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        address defaultAccount = _getAccountAddress(DEFAULT_ACCOUNT);
        assertApproxEqAbs(
            aV3USDC.balanceOf(defaultAccount),
            assets + initialAssets,
            1,
            "Assets should have been deposited into Aave."
        );

        assertApproxEqAbs(
            fund.totalAssets(),
            assets + initialAssets,
            1,
            "Assets should be added to the fund's total assets."
        );
    }

    function testWithdraw(uint256 assets) external {
        assets = bound(assets, 0.1e6, 1_000_000e6);
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        deal(address(USDC), address(this), 0);
        uint256 amountToWithdraw = fund.maxWithdraw(address(this)) - 1; // -1 accounts for rounding errors when supplying liquidity to aTokens.
        fund.withdraw(amountToWithdraw, address(this), address(this));

        assertEq(
            USDC.balanceOf(address(this)),
            amountToWithdraw,
            "Amount withdrawn should equal callers USDC balance."
        );
    }

    function testWithdrawalLogicNoEModeNoDebt() external {
        // Add aV3WETH as a trusted position to the registry, then to the fund.
        registry.trustPosition(
            aV3WETHPosition,
            address(aaveATokenManagerAdaptor),
            abi.encode(DEFAULT_ACCOUNT, address(aV3WETH))
        );
        fund.addPositionToCatalogue(aV3WETHPosition);
        fund.addPosition(2, aV3WETHPosition, abi.encode(0), false);

        uint32 wethPosition = 2;
        registry.trustPosition(wethPosition, address(erc20Adaptor), abi.encode(WETH));
        fund.addPositionToCatalogue(wethPosition);
        fund.addPosition(3, wethPosition, abi.encode(0), false);

        // Change holding position to just be USDC.
        fund.setHoldingPosition(usdcPosition);

        // Have user join the fund.
        uint256 assets = 1_000_000e6;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        // Rebalance fund so that it has aV3USDC and aV3WETH positions.
        // Simulate swapping hald the assets by dealing appropriate amounts of WETH.
        uint256 wethAmount = priceRouter.getValue(USDC, assets / 2, WETH);
        deal(address(USDC), address(fund), assets / 2);
        deal(address(WETH), address(fund), wethAmount);

        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](2);
        adaptorCalls[0] = _createBytesDataToLendOnAaveV3Manager(DEFAULT_ACCOUNT, aV3USDC, type(uint256).max);
        adaptorCalls[1] = _createBytesDataToLendOnAaveV3Manager(DEFAULT_ACCOUNT, aV3WETH, type(uint256).max);
        data[0] = Fund.AdaptorCall({ adaptor: address(aaveATokenManagerAdaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        // If fund has no debt, then all aTokens are fully withdrawable.
        uint256 withdrawable = fund.maxWithdraw(address(this));
        assertApproxEqAbs(withdrawable, assets, 1, "Withdrawable should approx equal original assets deposited.");
    }

    function testWithdrawalLogicEmodeNoDebt() external {
        // Even if EMode is set, all assets are still withdrawable.
        registry.trustPosition(
            aV3WETHPositionEmode,
            address(aaveATokenManagerAdaptor),
            abi.encode(ACCOUNT_EMODE_ONE, address(aV3WETH))
        );
        fund.addPositionToCatalogue(aV3WETHPositionEmode);
        fund.addPosition(2, aV3WETHPositionEmode, abi.encode(0), false);

        uint32 wethPosition = 2;
        registry.trustPosition(wethPosition, address(erc20Adaptor), abi.encode(WETH));
        fund.addPositionToCatalogue(wethPosition);
        fund.addPosition(3, wethPosition, abi.encode(0), false);

        uint32 aV3USDCPositionEmodeONE = 1111;
        registry.trustPosition(
            aV3USDCPositionEmodeONE,
            address(aaveATokenManagerAdaptor),
            abi.encode(ACCOUNT_EMODE_ONE, address(aV3USDC))
        );
        fund.addPositionToCatalogue(aV3USDCPositionEmodeONE);
        fund.addPosition(4, aV3USDCPositionEmodeONE, abi.encode(0), false);

        // Change holding position to just be USDC.
        fund.setHoldingPosition(usdcPosition);

        // Have user join the fund.
        uint256 assets = 1_000_000e6;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        // Rebalance fund so that it has aV3USDC and aV3WETH positions.
        // Simulate swapping hald the assets by dealing appropriate amounts of WETH.
        uint256 wethAmount = priceRouter.getValue(USDC, assets / 2, WETH);
        deal(address(USDC), address(fund), assets / 2);
        deal(address(WETH), address(fund), wethAmount);

        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](2);
        adaptorCalls[0] = _createBytesDataToLendOnAaveV3Manager(ACCOUNT_EMODE_ONE, aV3USDC, type(uint256).max);
        adaptorCalls[1] = _createBytesDataToLendOnAaveV3Manager(ACCOUNT_EMODE_ONE, aV3WETH, type(uint256).max);
        data[0] = Fund.AdaptorCall({ adaptor: address(aaveATokenManagerAdaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        // If fund has no debt, then all aTokens are fully withdrawable.
        uint256 withdrawable = fund.maxWithdraw(address(this));
        assertApproxEqAbs(withdrawable, assets, 1, "Withdrawable should approx equal original assets deposited.");

        uint256 assetsOut = fund.redeem(fund.balanceOf(address(this)), address(this), address(this));
        assertApproxEqAbs(assetsOut, assets, 1, "Assets Out should approx equal original assets deposited.");
    }

    function testWithdrawalLogicEModeWithDebt() external {
        uint256 initialAssets = fund.totalAssets();
        // Add aV3WETH as a trusted position to the registry, then to the fund.
        registry.trustPosition(
            aV3WETHPositionEmode,
            address(aaveATokenManagerAdaptor),
            abi.encode(ACCOUNT_EMODE_ONE, address(aV3WETH))
        );
        fund.addPositionToCatalogue(aV3WETHPositionEmode);
        fund.addPosition(2, aV3WETHPositionEmode, abi.encode(0), false);

        registry.trustPosition(
            debtWETHPosition,
            address(aaveDebtManagerAdaptor),
            abi.encode(ACCOUNT_EMODE_ONE, address(dV3WETH))
        );
        fund.addPositionToCatalogue(debtWETHPosition);
        fund.addPosition(1, debtWETHPosition, abi.encode(0), true);

        uint32 wethPosition = 2;
        registry.trustPosition(wethPosition, address(erc20Adaptor), abi.encode(WETH));
        fund.addPositionToCatalogue(wethPosition);
        fund.addPosition(3, wethPosition, abi.encode(0), false);

        // Change holding position to just be USDC.
        fund.setHoldingPosition(usdcPosition);

        // Have user join the fund.
        uint256 assets = 1_000_000e6;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        // Rebalance fund so that it has aV3USDC and aV3WETH positions.
        // Simulate swapping held the assets by dealing appropriate amounts of WETH.
        uint256 wethAmount = priceRouter.getValue(USDC, assets / 2, WETH);
        deal(address(USDC), address(fund), assets / 2);
        deal(address(WETH), address(fund), wethAmount);
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](3);
        bytes[] memory adaptorCalls0 = new bytes[](2);
        adaptorCalls0[0] = _createBytesDataToLendOnAaveV3Manager(DEFAULT_ACCOUNT, aV3USDC, type(uint256).max);
        adaptorCalls0[1] = _createBytesDataToLendOnAaveV3Manager(ACCOUNT_EMODE_ONE, aV3WETH, type(uint256).max);

        data[0] = Fund.AdaptorCall({ adaptor: address(aaveATokenManagerAdaptor), callData: adaptorCalls0 });

        bytes[] memory adaptorCalls1 = new bytes[](1);
        adaptorCalls1[0] = _createBytesDataToBorrowFromAaveV3Manager(ACCOUNT_EMODE_ONE, dV3WETH, wethAmount / 10);
        data[1] = Fund.AdaptorCall({ adaptor: address(aaveDebtManagerAdaptor), callData: adaptorCalls1 });

        bytes[] memory adaptorCalls2 = new bytes[](1);
        adaptorCalls2[0] = _createBytesDataToLendOnAaveV3Manager(ACCOUNT_EMODE_ONE, aV3WETH, type(uint256).max);
        data[2] = Fund.AdaptorCall({ adaptor: address(aaveATokenManagerAdaptor), callData: adaptorCalls2 });
        fund.callOnAdaptor(data);

        // If fund has no debt, but EMode is turned on so withdrawable should be zero.
        uint256 withdrawable = fund.maxWithdraw(address(this));
        assertEq(withdrawable, (assets / 2) + initialAssets, "Withdrawable should equal half the assets deposited.");
    }

    function testWithdrawalLogicNoEModeWithDebt() external {
        uint256 initialAssets = fund.totalAssets();
        // Add aV3WETH as a trusted position to the registry, then to the fund.
        registry.trustPosition(
            aV3WETHPosition,
            address(aaveATokenManagerAdaptor),
            abi.encode(DEFAULT_ACCOUNT, address(aV3WETH))
        );
        fund.addPositionToCatalogue(aV3WETHPosition);
        fund.addPosition(2, aV3WETHPosition, abi.encode(0), false);

        registry.trustPosition(
            debtWETHPosition,
            address(aaveDebtManagerAdaptor),
            abi.encode(DEFAULT_ACCOUNT, address(dV3WETH))
        );
        fund.addPositionToCatalogue(debtWETHPosition);
        fund.addPosition(1, debtWETHPosition, abi.encode(0), true);

        uint32 wethPosition = 2;
        registry.trustPosition(wethPosition, address(erc20Adaptor), abi.encode(WETH));
        fund.addPositionToCatalogue(wethPosition);
        fund.addPosition(3, wethPosition, abi.encode(0), false);

        // Change holding position to just be USDC.
        fund.setHoldingPosition(usdcPosition);

        // Have user join the fund.
        uint256 assets = 1_000_000e6;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        // Rebalance fund so that it has aV3USDC and aV3WETH positions.
        // Simulate swapping hald the assets by dealing appropriate amounts of WETH.
        uint256 wethAmount = priceRouter.getValue(USDC, assets / 2, WETH);
        deal(address(USDC), address(fund), assets / 2);
        deal(address(WETH), address(fund), wethAmount);
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](3);
        bytes[] memory adaptorCalls0 = new bytes[](2);
        adaptorCalls0[0] = _createBytesDataToLendOnAaveV3Manager(DEFAULT_ACCOUNT, aV3USDC, type(uint256).max);
        adaptorCalls0[1] = _createBytesDataToLendOnAaveV3Manager(DEFAULT_ACCOUNT, aV3WETH, type(uint256).max);
        data[0] = Fund.AdaptorCall({ adaptor: address(aaveATokenManagerAdaptor), callData: adaptorCalls0 });

        bytes[] memory adaptorCalls1 = new bytes[](1);
        adaptorCalls1[0] = _createBytesDataToBorrowFromAaveV3Manager(DEFAULT_ACCOUNT, dV3WETH, wethAmount / 10);
        data[1] = Fund.AdaptorCall({ adaptor: address(aaveDebtManagerAdaptor), callData: adaptorCalls1 });

        bytes[] memory adaptorCalls2 = new bytes[](1);
        adaptorCalls2[0] = _createBytesDataToLendOnAaveV3Manager(DEFAULT_ACCOUNT, aV3WETH, type(uint256).max);
        data[2] = Fund.AdaptorCall({ adaptor: address(aaveATokenManagerAdaptor), callData: adaptorCalls2 });
        fund.callOnAdaptor(data);

        // If fund has no debt, but EMode is turned on so withdrawable should be zero.
        uint256 withdrawable = fund.maxWithdraw(address(this));
        assertEq(withdrawable, (assets / 2) + initialAssets, "Withdrawable should equal half the assets deposited.");

        // Withdraw should work.
        fund.withdraw((assets / 2) + initialAssets, address(this), address(this));
    }

    function testTotalAssets(uint256 assets) external {
        uint256 initialAssets = fund.totalAssets();
        assets = bound(assets, 0.1e6, 1_000_000e6);
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));
        assertApproxEqAbs(fund.totalAssets(), assets + initialAssets, 1, "Total assets should equal assets deposited.");
    }

    function testTakingOutLoans() external {
        uint256 initialAssets = fund.totalAssets();
        uint256 assets = 100e6;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        assertApproxEqAbs(
            aV3USDC.balanceOf(_getAccountAddress(DEFAULT_ACCOUNT)),
            assets + initialAssets,
            1,
            "Fund should have aV3USDC worth of assets."
        );

        // Take out a USDC loan.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _createBytesDataToBorrowFromAaveV3Manager(DEFAULT_ACCOUNT, dV3USDC, assets / 2);

        data[0] = Fund.AdaptorCall({ adaptor: address(aaveDebtManagerAdaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        assertApproxEqAbs(
            dV3USDC.balanceOf(_getAccountAddress(DEFAULT_ACCOUNT)),
            assets / 2,
            1,
            "Fund should have dV3USDC worth of assets/2."
        );

        (ERC20[] memory tokens, uint256[] memory balances, bool[] memory isDebt) = fund.viewPositionBalances();
        assertEq(tokens.length, 3, "Should have length of 3.");
        assertEq(balances.length, 3, "Should have length of 3.");
        assertEq(isDebt.length, 3, "Should have length of 3.");

        assertEq(address(tokens[0]), address(USDC), "Should be USDC.");
        assertEq(address(tokens[1]), address(USDC), "Should be USDC.");
        assertEq(address(tokens[2]), address(USDC), "Should be USDC.");

        assertApproxEqAbs(balances[0], assets + initialAssets, 1, "Should equal assets.");
        assertEq(balances[1], assets / 2, "Should equal assets/2.");
        assertEq(balances[2], assets / 2, "Should equal assets/2.");

        assertEq(isDebt[0], false, "Should not be debt.");
        assertEq(isDebt[1], false, "Should not be debt.");
        assertEq(isDebt[2], true, "Should be debt.");
    }

    function testTakingOutLoansInUntrackedPosition() external {
        uint256 initialAssets = fund.totalAssets();
        uint256 assets = 100e6;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        assertApproxEqAbs(
            aV3USDC.balanceOf(_getAccountAddress(DEFAULT_ACCOUNT)),
            assets + initialAssets,
            1,
            "Fund should have aV3USDC worth of assets."
        );

        // Take out a USDC loan.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        uint256 usdcPrice = priceRouter.getExchangeRate(USDC, WETH);
        uint256 wethLoanAmount = assets.mulDivDown(10 ** WETH.decimals(), usdcPrice) / 2;
        adaptorCalls[0] = _createBytesDataToBorrowFromAaveV3Manager(DEFAULT_ACCOUNT, dV3WETH, wethLoanAmount);

        data[0] = Fund.AdaptorCall({ adaptor: address(aaveDebtManagerAdaptor), callData: adaptorCalls });
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    BaseAdaptor.BaseAdaptor__PositionNotUsed.selector,
                    abi.encode(DEFAULT_ACCOUNT, address(dV3WETH))
                )
            )
        );
        fund.callOnAdaptor(data);
    }

    function testRepayingLoans() external {
        uint256 initialAssets = fund.totalAssets();
        uint256 assets = 100e6;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        assertApproxEqAbs(
            aV3USDC.balanceOf(_getAccountAddress(DEFAULT_ACCOUNT)),
            assets + initialAssets,
            1,
            "Fund should have aV3USDC worth of assets."
        );

        // Take out a USDC loan.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _createBytesDataToBorrowFromAaveV3Manager(DEFAULT_ACCOUNT, dV3USDC, assets / 2);

        data[0] = Fund.AdaptorCall({ adaptor: address(aaveDebtManagerAdaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        assertApproxEqAbs(
            dV3USDC.balanceOf(_getAccountAddress(DEFAULT_ACCOUNT)),
            assets / 2,
            1,
            "Fund should have dV3USDC worth of assets/2."
        );

        // Repay the loan.
        adaptorCalls[0] = _createBytesDataToRepayToAaveV3Manager(DEFAULT_ACCOUNT, USDC, assets / 2);
        data[0] = Fund.AdaptorCall({ adaptor: address(aaveDebtManagerAdaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        assertApproxEqAbs(
            dV3USDC.balanceOf(_getAccountAddress(DEFAULT_ACCOUNT)),
            0,
            1,
            "Fund should have no dV3USDC left."
        );
    }

    function testWithdrawableFromaV3USDC() external {
        uint256 assets = 100e6;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        // Take out a USDC loan.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _createBytesDataToBorrowFromAaveV3Manager(DEFAULT_ACCOUNT, dV3USDC, assets / 2);

        data[0] = Fund.AdaptorCall({ adaptor: address(aaveDebtManagerAdaptor), callData: adaptorCalls });
        fund.callOnAdaptor(data);

        uint256 maxAssets = fund.maxWithdraw(address(this));
        fund.withdraw(maxAssets, address(this), address(this));

        assertEq(USDC.balanceOf(address(this)), maxAssets, "Should have withdraw max assets possible.");

        maxAssets = fund.maxWithdraw(address(this));
        fund.withdraw(maxAssets, address(this), address(this));

        assertEq(
            fund.totalAssetsWithdrawable(),
            0,
            "Fund should have remaining assets locked until strategist rebalances."
        );
    }

    function testWithdrawableFromaV3WETH() external {
        // First adjust fund to work primarily with WETH.
        // Make vanilla USDC the holding position.
        fund.swapPositions(0, 1, false);
        fund.setHoldingPosition(usdcPosition);

        // Adjust rebalance deviation so we can swap full amount of USDC for WETH.
        fund.setRebalanceDeviation(0.005e18);

        // Add WETH, aV3WETH, and dV3WETH as trusted positions to the registry.
        registry.trustPosition(
            aV3WETHPosition,
            address(aaveATokenManagerAdaptor),
            abi.encode(DEFAULT_ACCOUNT, address(aV3WETH))
        );
        fund.addPositionToCatalogue(aV3WETHPosition);
        fund.addPosition(2, aV3WETHPosition, abi.encode(0), false);

        registry.trustPosition(
            debtWETHPosition,
            address(aaveDebtManagerAdaptor),
            abi.encode(DEFAULT_ACCOUNT, address(dV3WETH))
        );
        fund.addPositionToCatalogue(debtWETHPosition);
        fund.addPosition(1, debtWETHPosition, abi.encode(0), true);

        uint32 wethPosition = 2;
        registry.trustPosition(wethPosition, address(erc20Adaptor), abi.encode(WETH));
        fund.addPositionToCatalogue(wethPosition);
        fund.addPosition(3, wethPosition, abi.encode(0), false);
        fund.addPositionToCatalogue(wethPosition);
        fund.addPositionToCatalogue(aV3WETHPosition);
        fund.addPositionToCatalogue(debtWETHPosition);

        // Withdraw from Aave V3 USDC.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _createBytesDataToWithdrawFromAaveV3Manager(DEFAULT_ACCOUNT, USDC, type(uint256).max);
        data[0] = Fund.AdaptorCall({ adaptor: address(aaveATokenManagerAdaptor), callData: adaptorCalls });

        fund.callOnAdaptor(data);

        // Remove dV3USDC and aV3USDC positions.
        fund.removePosition(1, false);
        fund.removePosition(0, true);

        // Deposit into the fund.
        uint256 assets = 10_000e6;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        // Perform several adaptor calls.
        // - Swap all USDC for WETH.
        // - Deposit all WETH into Aave.
        // - Take out a WETH loan on Aave.
        data = new Fund.AdaptorCall[](3);
        bytes[] memory adaptorCallsForFirstAdaptor = new bytes[](1);
        adaptorCallsForFirstAdaptor[0] = _createBytesDataForSwapWithUniv3(USDC, WETH, 500, assets);
        data[0] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCallsForFirstAdaptor });

        bytes[] memory adaptorCallsForSecondAdaptor = new bytes[](1);
        adaptorCallsForSecondAdaptor[0] = _createBytesDataToLendOnAaveV3Manager(
            DEFAULT_ACCOUNT,
            aV3WETH,
            type(uint256).max
        );
        data[1] = Fund.AdaptorCall({
            adaptor: address(aaveATokenManagerAdaptor),
            callData: adaptorCallsForSecondAdaptor
        });

        // Figure out roughly how much WETH the fund has on Aave.
        uint256 approxWETHCollateral = priceRouter.getValue(USDC, assets, WETH);
        bytes[] memory adaptorCallsForThirdAdaptor = new bytes[](1);
        adaptorCallsForThirdAdaptor[0] = _createBytesDataToBorrowFromAaveV3Manager(
            DEFAULT_ACCOUNT,
            dV3WETH,
            approxWETHCollateral / 2
        );
        data[2] = Fund.AdaptorCall({ adaptor: address(aaveDebtManagerAdaptor), callData: adaptorCallsForThirdAdaptor });
        fund.callOnAdaptor(data);

        uint256 maxAssets = fund.maxWithdraw(address(this));
        fund.withdraw(maxAssets, address(this), address(this));

        assertEq(
            fund.totalAssetsWithdrawable(),
            0,
            "Fund should have remaining assets locked until strategist rebalances."
        );
    }

    function testTakingOutAFlashLoan() external {
        uint256 initialAssets = fund.totalAssets();
        uint256 assets = 100e6;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        // Increase rebalance deviation so we can enter a larger position.
        // Flash loan fee is 0.09%, since we are taking a loan of 4x our assets, the total fee is 4x0.09% or 0.036%
        fund.setRebalanceDeviation(0.004e18);

        // Perform several adaptor calls.
        // - Use Flash loan to borrow `assets` USDC.
        //      - Deposit extra USDC into AAVE.
        //      - Take out USDC loan of (assets * 1.0009) against new collateral
        //      - Repay flash loan with new USDC loan.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCallsForFlashLoan = new bytes[](1);
        Fund.AdaptorCall[] memory dataInsideFlashLoan = new Fund.AdaptorCall[](2);
        bytes[] memory adaptorCallsInsideFlashLoanFirstAdaptor = new bytes[](1);
        bytes[] memory adaptorCallsInsideFlashLoanSecondAdaptor = new bytes[](1);
        adaptorCallsInsideFlashLoanFirstAdaptor[0] = _createBytesDataToLendOnAaveV3Manager(
            DEFAULT_ACCOUNT,
            aV3USDC,
            2 * assets
        );
        adaptorCallsInsideFlashLoanSecondAdaptor[0] = _createBytesDataToBorrowFromAaveV3Manager(
            DEFAULT_ACCOUNT,
            dV3USDC,
            2 * assets.mulWadDown(1.009e18)
        );
        dataInsideFlashLoan[0] = Fund.AdaptorCall({
            adaptor: address(aaveATokenManagerAdaptor),
            callData: adaptorCallsInsideFlashLoanFirstAdaptor
        });
        dataInsideFlashLoan[1] = Fund.AdaptorCall({
            adaptor: address(aaveDebtManagerAdaptor),
            callData: adaptorCallsInsideFlashLoanSecondAdaptor
        });
        address[] memory loanToken = new address[](1);
        loanToken[0] = address(USDC);
        uint256[] memory loanAmount = new uint256[](1);
        loanAmount[0] = 4 * assets;
        adaptorCallsForFlashLoan[0] = _createBytesDataToFlashLoanFromAaveV3Manager(
            loanToken,
            loanAmount,
            abi.encode(dataInsideFlashLoan)
        );
        data[0] = Fund.AdaptorCall({ adaptor: address(aaveDebtManagerAdaptor), callData: adaptorCallsForFlashLoan });
        fund.callOnAdaptor(data);

        assertApproxEqAbs(
            aV3USDC.balanceOf(_getAccountAddress(DEFAULT_ACCOUNT)),
            (3 * assets) + initialAssets,
            10,
            "Fund should have 3x its aave assets using a flash loan."
        );
    }

    function testMultipleATokensAndDebtTokens() external {
        // Add WETH, aV3WETH, and dV3WETH as trusted positions to the registry.
        registry.trustPosition(
            aV3WETHPosition,
            address(aaveATokenManagerAdaptor),
            abi.encode(DEFAULT_ACCOUNT, address(aV3WETH))
        );
        fund.addPositionToCatalogue(aV3WETHPosition);
        fund.addPosition(2, aV3WETHPosition, abi.encode(0), false);

        registry.trustPosition(
            debtWETHPosition,
            address(aaveDebtManagerAdaptor),
            abi.encode(DEFAULT_ACCOUNT, address(dV3WETH))
        );
        fund.addPositionToCatalogue(debtWETHPosition);
        fund.addPosition(1, debtWETHPosition, abi.encode(0), true);

        uint32 wethPosition = 2;
        registry.trustPosition(wethPosition, address(erc20Adaptor), abi.encode(WETH));
        fund.addPositionToCatalogue(wethPosition);
        fund.addPosition(3, wethPosition, abi.encode(0), false);

        uint256 assets = 100_000e6;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        // Perform several adaptor calls.
        // - Withdraw USDC from Aave.
        // - Swap USDC for WETH.
        // - Deposit WETH into Aave.
        // - Take out USDC loan.
        // - Take out WETH loan.
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](4);
        bytes[] memory adaptorCallsFirstAdaptor = new bytes[](1);
        bytes[] memory adaptorCallsSecondAdaptor = new bytes[](1);
        bytes[] memory adaptorCallsThirdAdaptor = new bytes[](1);
        bytes[] memory adaptorCallsFourthAdaptor = new bytes[](2);
        adaptorCallsFirstAdaptor[0] = _createBytesDataToWithdrawFromAaveV3Manager(DEFAULT_ACCOUNT, USDC, assets / 2);
        adaptorCallsSecondAdaptor[0] = _createBytesDataForSwapWithUniv3(USDC, WETH, 500, assets / 2);
        adaptorCallsThirdAdaptor[0] = _createBytesDataToLendOnAaveV3Manager(
            DEFAULT_ACCOUNT,
            aV3WETH,
            type(uint256).max
        );
        adaptorCallsFourthAdaptor[0] = _createBytesDataToBorrowFromAaveV3Manager(DEFAULT_ACCOUNT, dV3USDC, assets / 4);
        uint256 wethAmount = priceRouter.getValue(USDC, assets / 2, WETH) / 2; // To get approx a 50% LTV loan.
        adaptorCallsFourthAdaptor[1] = _createBytesDataToBorrowFromAaveV3Manager(DEFAULT_ACCOUNT, dV3WETH, wethAmount);

        data[0] = Fund.AdaptorCall({ adaptor: address(aaveATokenManagerAdaptor), callData: adaptorCallsFirstAdaptor });
        data[1] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCallsSecondAdaptor });
        data[2] = Fund.AdaptorCall({ adaptor: address(aaveATokenManagerAdaptor), callData: adaptorCallsThirdAdaptor });
        data[3] = Fund.AdaptorCall({ adaptor: address(aaveDebtManagerAdaptor), callData: adaptorCallsFourthAdaptor });
        fund.callOnAdaptor(data);

        uint256 maxAssets = fund.maxWithdraw(address(this));
        fund.withdraw(maxAssets, address(this), address(this));
    }

    // This check stops strategists from taking on any debt in positions they do not set up properly.
    // This stops the attack vector or strategists opening up an untracked debt position then depositing the funds into a vesting contract.
    function testTakingOutLoanInUntrackedPosition() external {
        uint256 assets = 100_000e6;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _createBytesDataToBorrowFromAaveV3Manager(DEFAULT_ACCOUNT, dV3WETH, 1e18);

        data[0] = Fund.AdaptorCall({ adaptor: address(aaveDebtManagerAdaptor), callData: adaptorCalls });
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    BaseAdaptor.BaseAdaptor__PositionNotUsed.selector,
                    abi.encode(DEFAULT_ACCOUNT, address(dV3WETH))
                )
            )
        );
        fund.callOnAdaptor(data);
    }

    function testRepayingDebtThatIsNotOwed() external {
        uint256 assets = 100_000e6;
        deal(address(USDC), address(this), assets);
        fund.deposit(assets, address(this));

        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _createBytesDataToRepayToAaveV3Manager(DEFAULT_ACCOUNT, USDC, 1e6);

        data[0] = Fund.AdaptorCall({ adaptor: address(aaveDebtManagerAdaptor), callData: adaptorCalls });

        // Error code 15: No debt of selected type.
        vm.expectRevert(bytes("39"));
        fund.callOnAdaptor(data);
    }

    function testBlockExternalReceiver() external {
        // Strategist tries to withdraw USDC to their own wallet using Adaptor's `withdraw` function.
        address maliciousStrategist = vm.addr(10);
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = abi.encodeWithSelector(
            AaveV3ATokenManagerAdaptor.withdraw.selector,
            100e6,
            maliciousStrategist,
            abi.encode(DEFAULT_ACCOUNT, address(aV3USDC)),
            abi.encode(0)
        );

        data[0] = Fund.AdaptorCall({ adaptor: address(aaveATokenManagerAdaptor), callData: adaptorCalls });

        vm.expectRevert(bytes(abi.encodeWithSelector(BaseAdaptor.BaseAdaptor__ExternalReceiverBlocked.selector)));
        fund.callOnAdaptor(data);
    }

    // ========================================== INTEGRATION TEST ==========================================

    function testIntegration() external {
        // Manage positions to reflect the following
        // 0) aV3USDC (holding)
        // 1) aV3WETH
        // 2) aV3WBTC

        // Debt Position
        // 0) dV3USDC
        registry.trustPosition(
            aV3WETHPosition,
            address(aaveATokenManagerAdaptor),
            abi.encode(DEFAULT_ACCOUNT, address(aV3WETH))
        );

        registry.trustPosition(
            aV3WBTCPosition,
            address(aaveATokenManagerAdaptor),
            abi.encode(DEFAULT_ACCOUNT, address(aV3WBTC))
        );
        fund.addPositionToCatalogue(aV3WETHPosition);
        fund.addPositionToCatalogue(aV3WBTCPosition);
        fund.addPosition(1, aV3WETHPosition, abi.encode(0), false);
        fund.addPosition(2, aV3WBTCPosition, abi.encode(0), false);
        fund.removePosition(3, false);

        // Have whale join the fund with 1M USDC.
        uint256 assets = 1_000_000e6;
        address whale = vm.addr(777);
        deal(address(USDC), whale, assets);
        vm.startPrank(whale);
        USDC.approve(address(fund), assets);
        fund.deposit(assets, whale);
        vm.stopPrank();

        // Strategist manages fund in order to achieve the following portfolio.
        // ~20% in aV3USDC.
        // ~40% Aave aV3WETH/dV3USDC with 2x LONG on WETH.
        // ~40% Aave aV3WBTC/dV3USDC with 3x LONG on WBTC.

        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](5);
        // Create data to withdraw USDC, swap for WETH and WBTC and lend them on Aave.
        uint256 amountToSwap = assets.mulDivDown(8, 10);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToWithdrawFromAaveV3Manager(
                DEFAULT_ACCOUNT,
                USDC,
                assets.mulDivDown(8, 10)
            );

            data[0] = Fund.AdaptorCall({ adaptor: address(aaveATokenManagerAdaptor), callData: adaptorCalls });
        }
        {
            bytes[] memory adaptorCalls = new bytes[](2);
            adaptorCalls[0] = _createBytesDataForSwapWithUniv3(USDC, WETH, 500, amountToSwap);
            amountToSwap = priceRouter.getValue(USDC, amountToSwap / 2, WETH);
            adaptorCalls[1] = _createBytesDataForSwapWithUniv3(WETH, WBTC, 500, amountToSwap);
            data[1] = Fund.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCalls });
        }

        {
            bytes[] memory adaptorCalls = new bytes[](2);

            adaptorCalls[0] = _createBytesDataToLendOnAaveV3Manager(DEFAULT_ACCOUNT, aV3WETH, type(uint256).max);
            adaptorCalls[1] = _createBytesDataToLendOnAaveV3Manager(DEFAULT_ACCOUNT, aV3WBTC, type(uint256).max);
            data[2] = Fund.AdaptorCall({ adaptor: address(aaveATokenManagerAdaptor), callData: adaptorCalls });
        }

        // Create data to flash loan USDC, sell it, and lend more WETH and WBTC on Aave.
        {
            // Want to borrow 3x 40% of assets
            uint256 USDCtoFlashLoan = assets.mulDivDown(12, 10);
            // Borrow the flash loan amount + premium.
            uint256 USDCtoBorrow = USDCtoFlashLoan.mulDivDown(1e3 + pool.FLASHLOAN_PREMIUM_TOTAL(), 1e3);

            bytes[] memory adaptorCallsForFlashLoan = new bytes[](1);
            Fund.AdaptorCall[] memory dataInsideFlashLoan = new Fund.AdaptorCall[](3);
            bytes[] memory adaptorCallsInsideFlashLoanFirstAdaptor = new bytes[](2);
            // Swap USDC for WETH.
            adaptorCallsInsideFlashLoanFirstAdaptor[0] = _createBytesDataForSwapWithUniv3(
                USDC,
                WETH,
                500,
                USDCtoFlashLoan
            );
            // Swap USDC for WBTC.
            uint256 amountToSwap0 = priceRouter.getValue(USDC, USDCtoFlashLoan.mulDivDown(2, 3), WETH);
            adaptorCallsInsideFlashLoanFirstAdaptor[1] = _createBytesDataForSwapWithUniv3(
                WETH,
                WBTC,
                500,
                amountToSwap0
            );
            // Lend USDC on Aave specifying to use the max amount available.
            bytes[] memory adaptorCallsInsideFlashLoanSecondAdaptor = new bytes[](2);
            adaptorCallsInsideFlashLoanSecondAdaptor[0] = _createBytesDataToLendOnAaveV3Manager(
                DEFAULT_ACCOUNT,
                aV3WETH,
                type(uint256).max
            );
            adaptorCallsInsideFlashLoanSecondAdaptor[1] = _createBytesDataToLendOnAaveV3Manager(
                DEFAULT_ACCOUNT,
                aV3WBTC,
                type(uint256).max
            );
            bytes[] memory adaptorCallsInsideFlashLoanThirdAdaptor = new bytes[](1);
            adaptorCallsInsideFlashLoanThirdAdaptor[0] = _createBytesDataToBorrowFromAaveV3Manager(
                DEFAULT_ACCOUNT,
                dV3USDC,
                USDCtoBorrow
            );
            dataInsideFlashLoan[0] = Fund.AdaptorCall({
                adaptor: address(swapWithUniswapAdaptor),
                callData: adaptorCallsInsideFlashLoanFirstAdaptor
            });
            dataInsideFlashLoan[1] = Fund.AdaptorCall({
                adaptor: address(aaveATokenManagerAdaptor),
                callData: adaptorCallsInsideFlashLoanSecondAdaptor
            });
            dataInsideFlashLoan[2] = Fund.AdaptorCall({
                adaptor: address(aaveDebtManagerAdaptor),
                callData: adaptorCallsInsideFlashLoanThirdAdaptor
            });
            address[] memory loanToken = new address[](1);
            loanToken[0] = address(USDC);
            uint256[] memory loanAmount = new uint256[](1);
            loanAmount[0] = USDCtoFlashLoan;
            adaptorCallsForFlashLoan[0] = _createBytesDataToFlashLoanFromAaveV3Manager(
                loanToken,
                loanAmount,
                abi.encode(dataInsideFlashLoan)
            );
            data[3] = Fund.AdaptorCall({
                adaptor: address(aaveDebtManagerAdaptor),
                callData: adaptorCallsForFlashLoan
            });
        }

        // Create data to lend remaining USDC on Aave.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToLendOnAaveV3Manager(DEFAULT_ACCOUNT, aV3USDC, type(uint256).max);

            data[4] = Fund.AdaptorCall({ adaptor: address(aaveATokenManagerAdaptor), callData: adaptorCalls });
        }
        // Adjust rebalance deviation to account for slippage and fees(swap and flash loan).

        fund.setRebalanceDeviation(0.03e18);

        fund.callOnAdaptor(data);
        assertLt(fund.totalAssetsWithdrawable(), assets, "Assets withdrawable should be less than assets.");

        // Whale withdraws as much as they can.
        vm.startPrank(whale);
        uint256 assetsToWithdraw = fund.maxWithdraw(whale);
        fund.withdraw(assetsToWithdraw, whale, whale);
        vm.stopPrank();

        assertEq(USDC.balanceOf(whale), assetsToWithdraw, "Amount withdrawn should equal maxWithdraw for Whale.");

        // Other user joins.
        assets = 100_000e6;
        address user = vm.addr(777);
        deal(address(USDC), user, assets);
        vm.startPrank(user);
        USDC.approve(address(fund), assets);
        fund.deposit(assets, user);
        vm.stopPrank();

        assertApproxEqAbs(
            fund.totalAssetsWithdrawable(),
            assets,
            1,
            "Total assets withdrawable should equal user deposit."
        );

        // Whale withdraws as much as they can.
        vm.startPrank(whale);
        assetsToWithdraw = fund.maxWithdraw(whale);
        fund.withdraw(assetsToWithdraw, whale, whale);
        vm.stopPrank();

        // Strategist must unwind strategy before any more withdraws can be made.
        assertEq(fund.totalAssetsWithdrawable(), 0, "There should be no more assets withdrawable.");

        // Strategist is more Bullish on WBTC than WETH, so they unwind the WETH position and keep the WBTC position.
        data = new Fund.AdaptorCall[](2);
        {
            uint256 fundAV3WETH = aV3WETH.balanceOf(_getAccountAddress(DEFAULT_ACCOUNT));
            // By lowering the USDC flash loan amount, we free up more aV3USDC for withdraw, but lower the health factor
            uint256 USDCtoFlashLoan = priceRouter.getValue(WETH, fundAV3WETH, USDC).mulDivDown(8, 10);

            bytes[] memory adaptorCallsForFlashLoan = new bytes[](1);
            Fund.AdaptorCall[] memory dataInsideFlashLoan = new Fund.AdaptorCall[](3);
            bytes[] memory adaptorCallsInsideFlashLoanFirstAdaptor = new bytes[](1);
            bytes[] memory adaptorCallsInsideFlashLoanSecondAdaptor = new bytes[](1);
            bytes[] memory adaptorCallsInsideFlashLoanThirdAdaptor = new bytes[](1);
            // Repay USDC debt.
            adaptorCallsInsideFlashLoanFirstAdaptor[0] = _createBytesDataToRepayToAaveV3Manager(
                DEFAULT_ACCOUNT,
                USDC,
                USDCtoFlashLoan
            );
            // Withdraw WETH and swap for USDC.
            adaptorCallsInsideFlashLoanSecondAdaptor[0] = _createBytesDataToWithdrawFromAaveV3Manager(
                DEFAULT_ACCOUNT,
                WETH,
                fundAV3WETH
            );
            adaptorCallsInsideFlashLoanThirdAdaptor[0] = _createBytesDataForSwapWithUniv3(WETH, USDC, 500, fundAV3WETH);
            dataInsideFlashLoan[0] = Fund.AdaptorCall({
                adaptor: address(aaveDebtManagerAdaptor),
                callData: adaptorCallsInsideFlashLoanFirstAdaptor
            });
            dataInsideFlashLoan[1] = Fund.AdaptorCall({
                adaptor: address(aaveATokenManagerAdaptor),
                callData: adaptorCallsInsideFlashLoanSecondAdaptor
            });
            dataInsideFlashLoan[2] = Fund.AdaptorCall({
                adaptor: address(swapWithUniswapAdaptor),
                callData: adaptorCallsInsideFlashLoanThirdAdaptor
            });
            address[] memory loanToken = new address[](1);
            loanToken[0] = address(USDC);
            uint256[] memory loanAmount = new uint256[](1);
            loanAmount[0] = USDCtoFlashLoan;
            adaptorCallsForFlashLoan[0] = _createBytesDataToFlashLoanFromAaveV3Manager(
                loanToken,
                loanAmount,
                abi.encode(dataInsideFlashLoan)
            );
            data[0] = Fund.AdaptorCall({
                adaptor: address(aaveDebtManagerAdaptor),
                callData: adaptorCallsForFlashLoan
            });
        }

        // Create data to lend remaining USDC on Aave.
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToLendOnAaveV3Manager(DEFAULT_ACCOUNT, aV3USDC, type(uint256).max);

            data[1] = Fund.AdaptorCall({ adaptor: address(aaveATokenManagerAdaptor), callData: adaptorCalls });
        }

        fund.callOnAdaptor(data);

        assertGt(
            fund.totalAssetsWithdrawable(),
            100_000e6,
            "There should a significant amount of assets withdrawable."
        );
    }

    function _getAccountAddress(uint8 accountId) internal view returns (address) {
        bytes32 salt = bytes32(uint256(accountId));
        bytes32 bytecodeHash = aaveATokenManagerAdaptor.accountBytecodeHash();

        return Create2.computeAddress(salt, bytecodeHash, address(fund));
    }
}
