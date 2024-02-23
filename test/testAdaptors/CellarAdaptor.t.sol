// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { SwaapFundAdaptor } from "src/modules/adaptors/Swaap/SwaapFundAdaptor.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";

import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";

contract SwaapFundAdaptorTest is MainnetStarterTest, AdaptorHelperFunctions {
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using stdStorage for StdStorage;

    SwaapFundAdaptor private swaapFundAdaptor;
    Fund private fund;

    uint32 private usdcPosition = 1;
    uint32 private wethPosition = 2;
    uint32 private fundPosition = 3;

    function setUp() external {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 16869780;
        _startFork(rpcKey, blockNumber);

        // Run Starter setUp code.
        _setUp();

        swaapFundAdaptor = new SwaapFundAdaptor();

        PriceRouter.ChainlinkDerivativeStorage memory stor;

        PriceRouter.AssetSettings memory settings;

        uint256 price = uint256(IChainlinkAggregator(WETH_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, WETH_USD_FEED);
        priceRouter.addAsset(WETH, settings, abi.encode(stor), price);

        price = uint256(IChainlinkAggregator(USDC_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, USDC_USD_FEED);
        priceRouter.addAsset(USDC, settings, abi.encode(stor), price);

        // Setup Fund:

        // Add adaptors and positions to the registry.
        registry.trustAdaptor(address(swaapFundAdaptor));

        registry.trustPosition(usdcPosition, address(erc20Adaptor), abi.encode(USDC));
        registry.trustPosition(wethPosition, address(erc20Adaptor), abi.encode(WETH));

        string memory fundName = "Dummy Fund V0.0";
        uint256 initialDeposit = 1e6;

        fund = _createFund(fundName, USDC, usdcPosition, abi.encode(true), initialDeposit);

        fund.setRebalanceDeviation(0.01e18);

        USDC.safeApprove(address(fund), type(uint256).max);
    }

    function testUsingIlliquidFundPosition() external {
        registry.trustPosition(fundPosition, address(swaapFundAdaptor), abi.encode(address(fund)));

        string memory fundName = "Meta Fund V0.0";
        uint256 initialDeposit = 1e6;

        Fund metaFund = _createFund(fundName, USDC, usdcPosition, abi.encode(true), initialDeposit);
        uint256 initialAssets = metaFund.totalAssets();

        metaFund.addPositionToCatalogue(fundPosition);
        metaFund.addAdaptorToCatalogue(address(swaapFundAdaptor));
        metaFund.addPosition(0, fundPosition, abi.encode(false), false);
        metaFund.setHoldingPosition(fundPosition);

        USDC.safeApprove(address(metaFund), type(uint256).max);

        // Deposit into meta fund.
        uint256 assets = 100_000e6;
        deal(address(USDC), address(this), assets);

        metaFund.deposit(assets, address(this));

        uint256 assetsDeposited = fund.totalAssets();
        assertEq(assetsDeposited, assets + initialAssets, "All assets should have been deposited into fund.");

        uint256 liquidAssets = metaFund.maxWithdraw(address(this));
        assertEq(liquidAssets, initialAssets, "Meta Fund only liquid assets should be USDC deposited in constructor.");

        // Check logic in the withdraw function by having strategist call withdraw, passing in isLiquid = false.
        bool isLiquid = false;
        Fund.AdaptorCall[] memory data = new Fund.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = abi.encodeWithSelector(
            SwaapFundAdaptor.withdraw.selector,
            assets,
            address(this),
            abi.encode(fund),
            abi.encode(isLiquid)
        );

        data[0] = Fund.AdaptorCall({ adaptor: address(swaapFundAdaptor), callData: adaptorCalls });

        vm.expectRevert(bytes(abi.encodeWithSelector(BaseAdaptor.BaseAdaptor__UserWithdrawsNotAllowed.selector)));
        metaFund.callOnAdaptor(data);
    }
}
