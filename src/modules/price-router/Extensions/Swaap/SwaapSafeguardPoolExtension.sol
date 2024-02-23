// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { IBalancerPool } from "src/interfaces/external/IBalancerPool.sol";
import { BalancerPoolExtension, PriceRouter, ERC20, Math, IVault, IERC20 } from "../Balancer/BalancerPoolExtension.sol";

/**
 * @title Swaap Price Router Swaap Safeguard Pool Extension
 * @notice Allows the Price Router to price Swaap Safeguard pool SPTs.
 */
contract SwaapSafeguardPoolExtension is BalancerPoolExtension {
    using Math for uint256;

    error SwaapSafeguardPoolExtension__ZeroAddressToken();

    error SwaapSafeguardPoolExtension__PoolTokensNotRegistered();

    error SwaapSafeguardPoolExtension__PoolNotRegistered();

    constructor(PriceRouter _priceRouter, IVault _swaapV2Vault) BalancerPoolExtension(_priceRouter, _swaapV2Vault) {}

    /**
     * @notice Balancer Stable Pool Extension Storage
     */
    mapping(ERC20 => bytes32) public poolAddressToId;

    /**
     * @notice Called by the price router during `_updateAsset` calls.
     * @param asset the BPT token
     * @dev _storage will have its poolId, and poolDecimals over written, but
     *      rateProviderDecimals, rateProviders, and underlyingOrConstituent
     *      MUST be correct, providing wrong values will result in inaccurate pricing.
     */
    function setupSource(ERC20 asset, bytes memory) external override onlyPriceRouter {
        IBalancerPool pool = IBalancerPool(address(asset));

        // Grab the poolId and decimals.
        bytes32 poolId = pool.getPoolId();

        // make sure the pool is registered in the vault
        (IERC20[] memory tokens, , ) = balancerVault.getPoolTokens(poolId);
        if (tokens.length < 2) revert SwaapSafeguardPoolExtension__PoolTokensNotRegistered();

        poolAddressToId[asset] = poolId;
    }

    /**
     * @notice Called during pricing operations.
     * @dev The price returned is the price of the underlying assets in USD with 8 decimals.
     * @param asset the BPT token
     */
    function getPriceInUSD(ERC20 asset) external view override returns (uint256) {
        // even though the swaap vault & safeguard pool are protected from reentrancy, it's still a good practice to check
        // for any ongoing operations on the vault
        ensureNotInVaultContext(balancerVault);

        IBalancerPool pool = IBalancerPool(address(asset));
        bytes32 poolId = poolAddressToId[asset];

        // this is done to prevent getting the price of a pool that is not trusted/registered in the adaptor
        if (poolId == bytes32(0)) revert SwaapSafeguardPoolExtension__PoolNotRegistered();

        (
            IERC20[] memory tokens,
            uint256[] memory balances, // lastChangeBlock,

        ) = balancerVault.getPoolTokens(poolId);

        // Get the price of each token in USD.
        uint256 length = tokens.length;
        uint256 priceBpt; // in USD with 8 decimals
        for (uint256 i; i < length; ++i) {
            address token = address(tokens[i]);
            if (token == address(0)) revert SwaapSafeguardPoolExtension__ZeroAddressToken();
            uint256 price = priceRouter.getPriceInUSD(ERC20(token));
            priceBpt += balances[i].mulDivDown(price, 10 ** ERC20(token).decimals());
        }

        uint256 totalSupply = pool.totalSupply();
        return priceBpt.mulDivDown(Math.WAD, totalSupply); // WAD = 1e18 - pool token decimals
    }
}
