// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Math } from "src/utils/Math.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Registry } from "src/Registry.sol";
import { Fund } from "src/base/Fund.sol";
import { PriceRouter } from "src/modules/price-router/PriceRouter.sol";

/**
 * @title Base Adaptor
 * @notice Base contract all adaptors must inherit from.
 * @dev Allows Funds to interact with arbritrary DeFi assets and protocols.
 * @author crispymangoes
 */
abstract contract BaseAdaptor {
    using SafeTransferLib for ERC20;
    using Math for uint256;

    /**
     * @notice Attempted to specify an external receiver during a Fund `callOnAdaptor` call.
     */
    error BaseAdaptor__ExternalReceiverBlocked();

    /**
     * @notice Attempted to deposit to a position where user deposits were not allowed.
     */
    error BaseAdaptor__UserDepositsNotAllowed();

    /**
     * @notice Attempted to withdraw from a position where user withdraws were not allowed.
     */
    error BaseAdaptor__UserWithdrawsNotAllowed();

    /**
     * @notice Attempted swap has bad slippage.
     */
    error BaseAdaptor__Slippage();

    /**
     * @notice Attempted swap used unsupported output asset.
     */
    error BaseAdaptor__PricingNotSupported(address asset);

    /**
     * @notice Attempted to set a constructor minimum health factor to a value
     *         below `MINIMUM_CONSTRUCTOR_HEALTH_FACTOR()`.
     */
    error BaseAdaptor__ConstructorHealthFactorTooLow();

    /**
     * @notice Attempted to interact with a position that is not used in the calling fund.
     */
    error BaseAdaptor__PositionNotUsed(bytes adaptorData);

    //============================================ Global Functions ===========================================
    /**
     * @dev Identifier unique to this adaptor for a shared registry.
     * Normally the identifier would just be the address of this contract, but this
     * Identifier is needed during Fund Delegate Call Operations, so getting the address
     * of the adaptor is more difficult.
     */
    function identifier() public pure virtual returns (bytes32) {
        return keccak256(abi.encode("Base Adaptor V 0.0"));
    }

    function SWAP_ROUTER_REGISTRY_SLOT() internal pure returns (uint256) {
        return 1;
    }

    function PRICE_ROUTER_REGISTRY_SLOT() internal pure returns (uint256) {
        return 2;
    }

    /**
     * @notice Max possible slippage when making a swap router swap.
     */
    function slippage() public pure virtual returns (uint32) {
        return 0.9e4;
    }

    /**
     * @notice The default minimum constructor health factor.
     * @dev Adaptors can choose to override this if they need a different value.
     */
    function MINIMUM_CONSTRUCTOR_HEALTH_FACTOR() internal pure virtual returns (uint256) {
        return 1.05e18;
    }

    //============================================ Implement Base Functions ===========================================
    //==================== Base Function Specification ====================
    // Base functions are functions designed to help the Fund interact with
    // an adaptor position, strategists are not intended to use these functions.
    // Base functions MUST be implemented in adaptor contracts, even if that is just
    // adding a revert statement to make them uncallable by normal user operations.
    //
    // All view Base functions will be called used normal staticcall.
    // All mutative Base functions will be called using delegatecall.
    //=====================================================================
    /**
     * @notice Function Funds call to deposit users funds into holding position.
     * @param assets the amount of assets to deposit
     * @param adaptorData data needed to deposit into a position
     * @param configurationData data settable when strategists add positions to their Fund
     *                          Allows strategist to control how the adaptor interacts with the position
     */
    function deposit(uint256 assets, bytes memory adaptorData, bytes memory configurationData) public virtual;

    /**
     * @notice Function Funds call to withdraw funds from positions to send to users.
     * @param receiver the address that should receive withdrawn funds
     * @param adaptorData data needed to withdraw from a position
     * @param configurationData data settable when strategists add positions to their Fund
     *                          Allows strategist to control how the adaptor interacts with the position
     */
    function withdraw(
        uint256 assets,
        address receiver,
        bytes memory adaptorData,
        bytes memory configurationData
    ) public virtual;

    /**
     * @notice Function Funds use to determine `assetOf` balance of an adaptor position.
     * @param adaptorData data needed to interact with the position
     * @return balance of the position in terms of `assetOf`
     */
    function balanceOf(bytes memory adaptorData) public view virtual returns (uint256);

    /**
     * @notice Functions Funds use to determine the withdrawable balance from an adaptor position.
     * @dev Debt positions MUST return 0 for their `withdrawableFrom`
     * @notice accepts adaptorData and configurationData
     * @return withdrawable balance of the position in terms of `assetOf`
     */
    function withdrawableFrom(bytes memory, bytes memory) public view virtual returns (uint256);

    /**
     * @notice Function Funds use to determine the underlying ERC20 asset of a position.
     * @param adaptorData data needed to withdraw from a position
     * @return the underlying ERC20 asset of a position
     */
    function assetOf(bytes memory adaptorData) public view virtual returns (ERC20);

    /**
     * @notice When positions are added to the Registry, this function can be used in order to figure out
     *         what assets this adaptor needs to price, and confirm pricing is properly setup.
     */
    function assetsUsed(bytes memory adaptorData) public view virtual returns (ERC20[] memory assets) {
        assets = new ERC20[](1);
        assets[0] = assetOf(adaptorData);
    }

    /**
     * @notice Functions Registry/Funds use to determine if this adaptor reports debt values.
     * @dev returns true if this adaptor reports debt values.
     */
    function isDebt() public view virtual returns (bool);

    //============================================ Strategist Functions ===========================================
    //==================== Strategist Function Specification ====================
    // Strategist functions are only callable by strategists through the Funds
    // `callOnAdaptor` function. A fund will never call any of these functions,
    // when a normal user interacts with a fund(depositing/withdrawing)
    //
    // All strategist functions will be called using delegatecall.
    // Strategist functions are intentionally "blind" to what positions the fund
    // is currently holding. This allows strategists to enter temporary positions
    // while rebalancing.
    // To mitigate strategist from abusing this and moving funds in untracked
    // positions, the fund will enforce a Total Value Locked check that
    // insures TVL has not deviated too much from `callOnAdaptor`.
    //===========================================================================

    //============================================ Helper Functions ===========================================
    /**
     * @notice Helper function that allows adaptor calls to use the max available of an ERC20 asset
     * by passing in type(uint256).max
     * @param token the ERC20 asset to work with
     * @param amount when `type(uint256).max` is used, this function returns `token`s `balanceOf`
     * otherwise this function returns amount.
     */
    function _maxAvailable(ERC20 token, uint256 amount) internal view virtual returns (uint256) {
        if (amount == type(uint256).max) return token.balanceOf(address(this));
        else return amount;
    }

    /**
     * @notice Helper function that checks if `spender` has any more approval for `asset`, and if so revokes it.
     */
    function _revokeExternalApproval(ERC20 asset, address spender) internal {
        if (asset.allowance(address(this), spender) > 0) asset.safeApprove(spender, 0);
    }

    /**
     * @notice Helper function that validates external receivers are allowed.
     */
    function _externalReceiverCheck(address receiver) internal view {
        if (receiver != address(this) && Fund(address(this)).blockExternalReceiver())
            revert BaseAdaptor__ExternalReceiverBlocked();
    }

    /**
     * @notice Verifies if the configured minimum health factor is in the allowed range.
     * @param minimumHealthFactor the configured minimum health factor to verify.
     */
    function _verifyConstructorMinimumHealthFactor(uint256 minimumHealthFactor) internal pure {
        if (minimumHealthFactor < MINIMUM_CONSTRUCTOR_HEALTH_FACTOR())
            revert BaseAdaptor__ConstructorHealthFactorTooLow();
    }

    /**
     * @notice Allows strategists to zero out an approval for a given `asset`.
     * @param asset the ERC20 asset to revoke `spender`s approval for
     * @param spender the address to revoke approval for
     */
    function revokeApproval(ERC20 asset, address spender) public {
        asset.safeApprove(spender, 0);
    }

    /**
     * @notice Allows fund to validate if a position is used in the calling fund.
     * If the fund is deployed (code size > 0), this function will check if the position is used.
     * If not deployed, this function will not check if the position is being used as it is assumed that it is
     * being used by the initial deposit function in the constructor which already adds the position to the fund.
     */
    function _verifyUsedPositionIfDeployed(bytes memory adaptorData) internal view {
        uint256 fundCodeSize;
        address fundAddress = address(this);

        /// @solidity memory-safe-assembly
        assembly {
            fundCodeSize := extcodesize(fundAddress)
        }

        if (fundCodeSize > 0) {
            _verifyUsedPosition(adaptorData);
        }
    }

    /**
     * @notice Allows fund to validate if a position is used in the calling fund.
     */
    function _verifyUsedPosition(bytes memory adaptorData) internal view {
        // Check that erc4626Vault position is setup to be used in the calling fund.
        bytes32 positionHash = keccak256(abi.encode(identifier(), isDebt(), adaptorData));
        uint32 positionId = Fund(address(this)).registry().getPositionHashToPositionId(positionHash);
        if (!Fund(address(this)).isPositionUsed(positionId)) revert BaseAdaptor__PositionNotUsed(adaptorData);
    }
}
