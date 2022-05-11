// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.11;

import { MultipositionCellar } from "../templates/MultipositionCellar.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockMultipositionCellar } from "./mocks/MockMultipositionCellar.sol";
import { MockERC4626 } from "./mocks/MockERC4626.sol";
import { MockSwapRouter } from "./mocks/MockSwapRouter.sol";
import { ERC20 } from "@rari-capital/solmate/src/tokens/ERC20.sol";
import { ISushiSwapRouter } from "../interfaces/ISushiSwapRouter.sol";
import { ERC4626 } from "../interfaces/ERC4626.sol";

import { DSTestPlus } from "./utils/DSTestPlus.sol";
import { MathUtils } from "../utils/MathUtils.sol";

contract MultipositionCellarTest is DSTestPlus {
    using MathUtils for uint256;

    MockMultipositionCellar private cellar;
    MockSwapRouter private swapRouter;

    MockERC20 private USDC;
    MockERC4626 private usdcCLR;

    MockERC20 private FRAX;
    MockERC4626 private fraxCLR;

    MockERC20 private FEI;
    MockERC4626 private feiCLR;

    function setUp() public {
        // TODO: test USDC with 6 decimals once cellar can handle multiple decimals
        USDC = new MockERC20("USDC", 18);
        usdcCLR = new MockERC4626(ERC20(address(USDC)), "USDC Cellar LP Token", "USDC-CLR", 18);

        FRAX = new MockERC20("FRAX", 18);
        fraxCLR = new MockERC4626(ERC20(address(FRAX)), "FRAX Cellar LP Token", "FRAX-CLR", 18);

        FEI = new MockERC20("FEI", 18);
        feiCLR = new MockERC4626(ERC20(address(FEI)), "FEI Cellar LP Token", "FEI-CLR", 18);

        // Set up stablecoin cellar:
        swapRouter = new MockSwapRouter();

        ERC4626[] memory positions = new ERC4626[](3);
        positions[0] = ERC4626(address(usdcCLR));
        positions[1] = ERC4626(address(fraxCLR));
        positions[2] = ERC4626(address(feiCLR));

        uint256 len = positions.length;

        address[][] memory paths = new address[][](len);
        for (uint256 i; i < len; i++) {
            address[] memory path = new address[](2);
            path[0] = address(positions[i].asset());
            path[1] = address(USDC);

            paths[i] = path;
        }

        uint32[] memory maxSlippages = new uint32[](len);
        for (uint256 i; i < len; i++) maxSlippages[i] = uint32(swapRouter.EXCHANGE_RATE());

        cellar = new MockMultipositionCellar(
            USDC, // TODO: change
            positions,
            paths,
            maxSlippages,
            "Ultimate Stablecoin Cellar LP Token",
            "stble-CLR",
            18,
            ISushiSwapRouter(address(swapRouter))
        );

        // Transfer ownership to this contract for testing.
        hevm.prank(address(cellar.gravityBridge()));
        cellar.transferOwnership(address(this));

        // Mint enough liquidity to swap router for swaps.
        for (uint256 i; i < positions.length; i++) {
            MockERC20 asset = MockERC20(address(positions[i].asset()));
            asset.mint(address(swapRouter), type(uint112).max);
        }

        // Initialize with non-zero timestamp to avoid issues with accrual.
        hevm.warp(365 days);
    }

    // TODO: test with fuzzing
    // function testDepositWithdraw(uint256 assets) public {
    function testDepositWithdraw() public {
        // TODO: implement maxDeposit
        // assets = bound(assets, 1, cellar.maxDeposit(address(this)));
        // NOTE: last time this was run, all test pass with the line below uncommented
        // assets = bound(assets, 1, type(uint128).max);
        uint256 assets = 100e18;

        // Test single deposit.
        USDC.mint(address(this), assets);
        USDC.approve(address(cellar), assets);
        uint256 shares = cellar.deposit(assets, address(this));

        assertEq(shares, assets); // Expect exchange rate to be 1:1 on initial deposit.
        assertEq(cellar.previewWithdraw(assets), shares);
        assertEq(cellar.previewDeposit(assets), shares);
        assertEq(cellar.totalBalance(), 0);
        assertEq(cellar.totalHoldings(), assets);
        assertEq(cellar.totalAssets(), assets);
        assertEq(cellar.totalSupply(), shares);
        assertEq(cellar.balanceOf(address(this)), shares);
        assertEq(cellar.convertToAssets(cellar.balanceOf(address(this))), assets);
        assertEq(USDC.balanceOf(address(this)), 0);

        // Test single withdraw.
        cellar.withdraw(assets, address(this), address(this));

        assertEq(cellar.totalBalance(), 0);
        assertEq(cellar.totalHoldings(), 0);
        assertEq(cellar.totalAssets(), 0);
        assertEq(cellar.totalSupply(), 0);
        assertEq(cellar.balanceOf(address(this)), 0);
        assertEq(cellar.convertToAssets(cellar.balanceOf(address(this))), 0);
        assertEq(USDC.balanceOf(address(this)), assets);
    }

    function testFailDepositWithNotEnoughApproval(uint256 amount) public {
        USDC.mint(address(this), amount / 2);
        USDC.approve(address(cellar), amount / 2);

        cellar.deposit(amount, address(this));
    }

    function testFailWithdrawWithNotEnoughBalance(uint256 amount) public {
        USDC.mint(address(this), amount / 2);
        USDC.approve(address(cellar), amount / 2);

        cellar.deposit(amount / 2, address(this));

        cellar.withdraw(amount, address(this), address(this));
    }

    function testFailRedeemWithNotEnoughBalance(uint256 amount) public {
        USDC.mint(address(this), amount / 2);
        USDC.approve(address(cellar), amount / 2);

        cellar.deposit(amount / 2, address(this));

        cellar.redeem(amount, address(this), address(this));
    }

    function testFailWithdrawWithNoBalance(uint256 amount) public {
        if (amount == 0) amount = 1;
        cellar.withdraw(amount, address(this), address(this));
    }

    function testFailRedeemWithNoBalance(uint256 amount) public {
        cellar.redeem(amount, address(this), address(this));
    }

    function testFailDepositWithNoApproval(uint256 amount) public {
        cellar.deposit(amount, address(this));
    }

    // TODO: test with fuzzing
    function testRebalance() external {
        uint256 assets = 100e18;

        ERC4626[] memory positions = cellar.getPositions();
        ERC4626 positionFrom = positions[0];
        ERC4626 positionTo = positions[1];

        MockERC20 assetFrom = MockERC20(address(positionFrom.asset()));

        assetFrom.mint(address(this), assets);
        assetFrom.approve(address(cellar), assets);
        cellar.deposit(assets, address(this));

        address[] memory path = new address[](2);

        // Test rebalancing from holding position.
        path[0] = address(assetFrom);
        path[1] = address(assetFrom);

        uint256 assetsRebalanced = cellar.rebalance(cellar, positionFrom, assets, assets, path);

        assertEq(assetsRebalanced, assets);
        assertEq(cellar.totalHoldings(), 0);
        assertEq(positionFrom.balanceOf(address(cellar)), assets);
        (, , uint112 fromBalance) = cellar.getPositionData(positionFrom);
        assertEq(fromBalance, assets);

        // Test rebalancing between positions.
        path[0] = address(assetFrom);
        path[1] = address(positionTo.asset());

        uint256 expectedAssetsOut = swapRouter.quote(assets, path);
        assetsRebalanced = cellar.rebalance(positionFrom, positionTo, assets, expectedAssetsOut, path);

        assertEq(assetsRebalanced, expectedAssetsOut);
        assertEq(positionFrom.balanceOf(address(cellar)), 0);
        assertEq(positionTo.balanceOf(address(cellar)), assetsRebalanced);
        (, , fromBalance) = cellar.getPositionData(positionFrom);
        assertEq(fromBalance, 0);
        (, , uint112 toBalance) = cellar.getPositionData(positionTo);
        assertEq(toBalance, assetsRebalanced);

        // Test rebalancing back to holding position.
        path[0] = address(positionTo.asset());
        path[1] = address(assetFrom);

        expectedAssetsOut = swapRouter.quote(assetsRebalanced, path);
        assetsRebalanced = cellar.rebalance(positionTo, cellar, assetsRebalanced, expectedAssetsOut, path);

        assertEq(assetsRebalanced, expectedAssetsOut);
        assertEq(positionTo.balanceOf(address(cellar)), 0);
        assertEq(cellar.totalHoldings(), assetsRebalanced);
        (, , toBalance) = cellar.getPositionData(positionTo);
        assertEq(toBalance, 0);
    }

    function testFailRebalanceIntoUntrustedPosition() external {
        uint256 assets = 100e18;

        ERC4626[] memory positions = cellar.getPositions();
        ERC4626 untrustedPosition = positions[positions.length - 1];

        cellar.setTrust(untrustedPosition, false);

        MockERC20 asset = MockERC20(address(cellar.asset()));

        asset.mint(address(this), assets);
        asset.approve(address(cellar), assets);
        cellar.deposit(assets, address(this));

        address[] memory path = new address[](2);

        // Test rebalancing from holding position to untrusted position.
        path[0] = address(asset);
        path[1] = address(untrustedPosition.asset());

        cellar.rebalance(cellar, untrustedPosition, assets, 0, path);
    }

    function testAccrue() external {
        // Scenario:
        // - Multiposition cellar has 3 positions.
        //
        // +==============+==============+==================+
        // | Total Assets | Total Locked | Performance Fees |
        // +==============+==============+==================+
        // | 1. Deposit 100 assets into each position.      |
        // +--------------+--------------+------------------+
        // |          300 |            0 |                0 |
        // +--------------+--------------+------------------+
        // | 2. Each position gains 50 assets of yield.     |
        // +--------------+--------------+------------------+
        // |          300 |            0 |                0 |
        // +--------------+--------------+------------------+
        // | 3. Accrue fees and begin accruing yield.       |
        // +--------------+--------------+------------------+
        // |          315 |          135 |               15 |
        // +--------------+--------------+------------------+
        // | 4. Half of first accrual period passes.        |
        // +--------------+--------------+------------------+
        // |        382.5 |         67.5 |               15 |
        // +--------------+--------------+------------------+
        // | 5. Deposit 200 assets into a position.         |
        // |    NOTE: For testing that deposit does not     |
        // |          effect yield and is not factored in   |
        // |          to later accrual.                     |
        // +--------------+--------------+------------------+
        // |        582.5 |         67.5 |               15 |
        // +--------------+--------------+------------------+
        // | 6. First accrual period passes.                |
        // +--------------+--------------+------------------+
        // |          650 |            0 |               15 |
        // +--------------+--------------+------------------+
        // | 7. Withdraw 100 assets from a position.        |
        // |    NOTE: For testing that withdraw does not    |
        // |          effect yield and is not factored in   |
        // |          to later accrual.                     |
        // +--------------+--------------+------------------+
        // |          550 |            0 |               15 |
        // +--------------+--------------+------------------+
        // | 8. Accrue fees and begin accruing yield.       |
        // |    NOTE: Should not accrue any yield or fees   |
        // |          since user deposits / withdraws are   |
        // |          not factored into yield.              |
        // +--------------+--------------+------------------+
        // |          550 |            0 |               15 |
        // +--------------+--------------+------------------+
        // | 9. Second accrual period passes.               |
        // +--------------+--------------+------------------+
        // |          550 |            0 |               15 |
        // +--------------+--------------+------------------+

        ERC4626[] memory positions = cellar.getPositions();
        for (uint256 i; i < positions.length; i++) {
            ERC4626 position = positions[i];
            MockERC20 asset = MockERC20(address(position.asset()));

            // 1. Deposit 100 assets into each position.
            asset.mint(address(this), 100e18);
            asset.approve(address(cellar), 100e18);
            cellar.depositIntoPosition(position, 100e18, address(this));

            assertEq(position.totalAssets(), 100e18);
            (, , uint112 balance) = cellar.getPositionData(position);
            assertEq(balance, 100e18);
            assertEq(cellar.totalBalance(), 100e18 * (i + 1));

            // 2. Each position gains 50 assets of yield.
            MockERC4626(address(position)).freeDeposit(50e18, address(cellar));

            assertEq(position.maxWithdraw(address(cellar)), 150e18);
        }

        assertEq(cellar.totalAssets(), 300e18);

        uint256 priceOfShareBefore = cellar.convertToShares(1e18);

        // 3. Accrue fees and begin accruing yield.
        cellar.accrue();

        uint256 priceOfShareAfter = cellar.convertToShares(1e18);
        assertEq(priceOfShareAfter, priceOfShareBefore);
        assertEq(cellar.lastAccrual(), block.timestamp);
        assertEq(cellar.totalLocked(), 135e18);
        assertEq(cellar.totalAssets(), 315e18);
        assertEq(cellar.totalBalance(), 450e18);
        assertEq(cellar.accruedPerformanceFees(), 15e18);

        // Position balances should have updated to reflect yield accrued per position.
        for (uint256 i; i < positions.length; i++) {
            ERC4626 position = positions[i];

            (, , uint112 balance) = cellar.getPositionData(position);
            assertEq(balance, 150e18);
        }

        // 4. Half of first accrual period passes.
        uint256 accrualPeriod = cellar.accrualPeriod();
        hevm.warp(block.timestamp + accrualPeriod / 2);

        assertEq(cellar.totalLocked(), 67.5e18);
        assertApproxEq(cellar.totalAssets(), 382.5e18, 1e17);
        assertApproxEq(cellar.totalBalance(), 450e18, 1e17);
        assertEq(cellar.accruedPerformanceFees(), 15e18);

        // 5. Deposit 200 assets into a position.
        USDC.mint(address(this), 200e18);
        USDC.approve(address(cellar), 200e18);
        cellar.depositIntoPosition(usdcCLR, 200e18, address(this));

        assertEq(cellar.totalLocked(), 67.5e18);
        assertApproxEq(cellar.totalAssets(), 582.5e18, 1e17);
        assertApproxEq(cellar.totalBalance(), 650e18, 1e17);
        assertEq(cellar.accruedPerformanceFees(), 15e18);

        // 6. First accrual period passes.
        hevm.warp(block.timestamp + accrualPeriod / 2);

        assertEq(cellar.totalLocked(), 0);
        assertApproxEq(cellar.totalAssets(), 650e18, 1e17);
        assertApproxEq(cellar.totalBalance(), 650e18, 1e17);
        assertEq(cellar.accruedPerformanceFees(), 15e18);

        // 7. Withdraw 100 assets from a position.
        cellar.withdrawFromPosition(fraxCLR, 100e18, address(this), address(this));

        assertEq(cellar.totalLocked(), 0);
        assertApproxEq(cellar.totalAssets(), 550e18, 1e17);
        assertApproxEq(cellar.totalBalance(), 550e18, 1e17);
        assertEq(cellar.accruedPerformanceFees(), 15e18);

        // 8. Accrue fees and begin accruing yield.
        cellar.accrue();

        assertEq(cellar.totalLocked(), 0);
        assertApproxEq(cellar.totalAssets(), 550e18, 1e17);
        assertApproxEq(cellar.totalBalance(), 550e18, 1e17);
        assertEq(cellar.accruedPerformanceFees(), 15e18);

        // 9. Second accrual period passes.
        hevm.warp(block.timestamp + accrualPeriod);

        assertEq(cellar.totalLocked(), 0);
        assertApproxEq(cellar.totalAssets(), 550e18, 1e17);
        assertApproxEq(cellar.totalBalance(), 550e18, 1e17);
        assertEq(cellar.accruedPerformanceFees(), 15e18);
    }

    // TODO: address possible error that could happen if not enough to withdraw from all positions
    // due to swap slippage while converting
    function testWithdrawWithoutEnoughHoldings() external {
        uint256 assets = 100e18;

        // Deposit assets directly into position.
        FRAX.mint(address(this), assets);
        FRAX.approve(address(cellar), assets);
        cellar.depositIntoPosition(fraxCLR, assets, address(this));

        FEI.mint(address(this), assets);
        FEI.approve(address(cellar), assets);
        cellar.depositIntoPosition(feiCLR, assets, address(this));

        assertEq(cellar.totalHoldings(), 0);

        // TODO: test withdrawing everything
        uint256 assetsToWithdraw = 10e18;
        cellar.withdraw(assetsToWithdraw, address(this), address(this));

        // TODO: check if totalHoldings percentage approximately equal to the target
        assertEq(USDC.balanceOf(address(this)), assetsToWithdraw);
    }

    function testDistrustingPosition() external {
        ERC4626 distrustedPosition = fraxCLR;

        cellar.setTrust(distrustedPosition, false);

        (bool isTrusted, , ) = cellar.getPositionData(distrustedPosition);
        assertFalse(isTrusted);

        ERC4626[] memory positions = cellar.getPositions();
        for (uint256 i; i < positions.length; i++) assertTrue(positions[i] != distrustedPosition);
    }

    // // TODO:
    // // [ ] test hitting depositLimit
    // // [ ] test hitting liquidityLimit

    // // Test deposit hitting liquidity limit.
    // function testDepositWithDepositLimits(uint256 assets) external {
    //     assets = bound(assets, 1, type(uint128).max);

    //     uint248 depositLimit = 50_000e18;
    //     usdcCLR.setDepositLimit(depositLimit);

    //     uint256 expectedAssets = MathUtils.min(depositLimit, assets);

    //     // Test with holdings limit.
    //     USDC.mint(address(this), assets);
    //     USDC.approve(address(cellar), assets);
    //     uint256 shares = cellar.deposit(assets, address(this));

    //     assertEq(cellar.totalAssets(), expectedAssets);
    //     assertEq(cellar.previewDeposit(expectedAssets), shares);
    // }

    // // Test deposit hitting deposit limit.
    // function testDepositWithLiquidityLimits(uint256 assets) external {
    //     assets = bound(assets, 1, type(uint128).max);

    //     uint248 liquidityLimit = 75_000e18;
    //     usdcCLR.setLiquidityLimit(liquidityLimit);

    //     uint256 expectedAssets = MathUtils.min(liquidityLimit, assets);

    //     // Test with liquidity limit.
    //     USDC.mint(address(this), assets);
    //     USDC.approve(address(cellar), assets);
    //     uint256 shares = cellar.deposit(assets, address(this));

    //     assertEq(cellar.totalAssets(), expectedAssets);
    //     assertEq(cellar.previewDeposit(expectedAssets), shares);
    // }

    // // Test deposit hitting both limits.
    // function testDepositWithAllLimits(uint256 assets) external {
    //     assets = bound(assets, 1, type(uint128).max);

    //     uint248 holdingsLimit = 25_000e18;
    //     cellar.setHoldingLimit(ERC4626(address(usdcCLR)), holdingsLimit);

    //     uint248 depositLimit = 50_000e18;
    //     usdcCLR.setDepositLimit(depositLimit);

    //     uint248 liquidityLimit = 75_000e18;
    //     usdcCLR.setLiquidityLimit(liquidityLimit);

    //     uint256 expectedAssets = MathUtils.min(holdingsLimit, assets);

    //     // Test with liquidity limit.
    //     USDC.mint(address(this), assets);
    //     USDC.approve(address(cellar), assets);
    //     uint256 shares = cellar.deposit(assets, address(this));

    //     assertEq(cellar.totalAssets(), expectedAssets);
    //     assertEq(cellar.previewDeposit(expectedAssets), shares);
    // }
}
