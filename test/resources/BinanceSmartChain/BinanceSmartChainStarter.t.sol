// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

// Import Protocol Resources
import { Deployer } from "src/Deployer.sol";
import { Fund } from "src/base/Fund.sol";
import { Registry } from "src/Registry.sol";
import { PriceRouter } from "src/modules/price-router/PriceRouter.sol";

// Import Helpers
import { Math } from "src/utils/Math.sol";
import { ERC4626 } from "src/base/ERC4626.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { MainnetAddresses } from "test/resources/MainnetAddresses.sol";
import { IChainlinkAggregator } from "src/interfaces/external/IChainlinkAggregator.sol";

// Import Frequently Used Adaptors
import { BaseAdaptor } from "src/modules/adaptors/BaseAdaptor.sol";
import { ERC20Adaptor } from "src/modules/adaptors/ERC20Adaptor.sol";
import { SwapWithUniswapAdaptor } from "src/modules/adaptors/Uniswap/SwapWithUniswapAdaptor.sol";

// Import Testing Resources
import { Test, stdStorage, StdStorage, stdError, console } from "@forge-std/Test.sol";

/**
 * @notice This base contract should hold the most often repeated test code.
 */
contract MainnetStarterTest is Test, MainnetAddresses {
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using stdStorage for StdStorage;

    Deployer public deployer;
    Registry public registry;
    PriceRouter public priceRouter;
    ERC20Adaptor public erc20Adaptor;
    SwapWithUniswapAdaptor public swapWithUniswapAdaptor;

    uint8 public constant CHAINLINK_DERIVATIVE = 1;
    uint8 public constant TWAP_DERIVATIVE = 2;
    uint8 public constant EXTENSION_DERIVATIVE = 3;

    function _setUp() internal {
        address[] memory deployers = new address[](1);
        deployers[0] = address(this);
        deployer = new Deployer(address(this), deployers);

        bytes memory creationCode;
        bytes memory constructorArgs;

        // Deploy the registry.
        creationCode = type(Registry).creationCode;
        constructorArgs = abi.encode(address(this), address(this), address(this), address(this));
        registry = Registry(deployer.deployContract("Registry V0.0", creationCode, constructorArgs));

        // Deploy the price router.
        creationCode = type(PriceRouter).creationCode;
        constructorArgs = abi.encode(address(this), registry, WETH);
        priceRouter = PriceRouter(deployer.deployContract("PriceRouter V0.0", creationCode, constructorArgs));

        // Update price router in registry.
        registry.setAddress(2, address(priceRouter));

        // Deploy ERC20Adaptor.
        creationCode = type(ERC20Adaptor).creationCode;
        constructorArgs = hex"";
        erc20Adaptor = ERC20Adaptor(deployer.deployContract("ERC20 Adaptor V0.0", creationCode, constructorArgs));

        // Deploy SwapWithUniswapAdaptor.
        creationCode = type(SwapWithUniswapAdaptor).creationCode;
        constructorArgs = abi.encode(uniV2Router, uniV3Router);
        swapWithUniswapAdaptor = SwapWithUniswapAdaptor(
            deployer.deployContract("Swap With Uniswap Adaptor V0.0", creationCode, constructorArgs)
        );

        // Trust Adaptors in Regsitry.
        registry.trustAdaptor(address(erc20Adaptor));
        registry.trustAdaptor(address(swapWithUniswapAdaptor));
    }

    function _startFork(string memory rpcKey, uint256 blockNumber) internal returns (uint256 forkId) {
        forkId = vm.createFork(vm.envString(rpcKey), blockNumber);
        vm.selectFork(forkId);
    }

    function _createFund(
        string memory fundName,
        ERC20 holdingAsset,
        uint32 holdingPosition,
        bytes memory holdingPositionConfig,
        uint256 initialDeposit
    ) internal returns (Fund) {
        // Approve new fund to spend assets.
        address fundAddress = deployer.getAddress(fundName);
        deal(address(holdingAsset), address(this), initialDeposit);
        holdingAsset.approve(fundAddress, initialDeposit);

        bytes memory creationCode;
        bytes memory constructorArgs;
        creationCode = type(Fund).creationCode;
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

        return Fund(deployer.deployContract(fundName, creationCode, constructorArgs));
    }
}
