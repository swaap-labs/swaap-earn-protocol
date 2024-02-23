// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BaseAdaptor, ERC20, SafeTransferLib, Cellar, Registry, PriceRouter } from "src/modules/adaptors/BaseAdaptor.sol";
import { IVault, IERC20, IAsset, IFlashLoanRecipient } from "src/interfaces/external/Balancer/IVault.sol";
import { IBasePool } from "src/interfaces/external/Balancer/typically-npm/IBasePool.sol";
import { ISafeguardPool } from "src/interfaces/external/ISafeguardPool.sol";
import { BaseAdaptor } from "src/modules/adaptors/BaseAdaptor.sol";
import { PositionlessAdaptor } from "src/modules/adaptors/PositionlessAdaptor.sol";

/**
 * @title Swaap Pool Adaptor
 * @notice Allows Cellars to interact with Swaap Safeguard Pools.
 */
contract SwaapPoolAdaptor is PositionlessAdaptor {
    using SafeTransferLib for ERC20;

    //==================== Adaptor Data Specification ====================
    // adaptorData = abi.encode(ERC20 _spt)
    // Where:
    // `_spt` is the Swaap pool token of the Swaap LP market this adaptor is working with
    //================= Configuration Data Specification =================
    // NOT USED
    // **************************** IMPORTANT ****************************
    // This adaptor has the `assetOf` as a spt, and thus relies on the `PriceRouterv2` Swaap
    // Extensions corresponding with the type of spt the Cellar is working with.
    //====================================================================

    //============================================ Error Statements ===========================================

    /**
     * @notice Provided swap array length differs from expected tokens array length.
     */
    error SwaapPoolAdaptor___LengthMismatch();

    /**
     * @notice Provided pool token and expected token do not match.
     */
    error SwaapPoolAdaptor___PoolTokenAndExpectedTokenMismatch();

    //============================================ Global Vars && Specific Adaptor Constants ===========================================

    /**
     * @notice The Swaap Vault contract
     * @notice For mainnet use 0xd315a9C38eC871068FEC378E4Ce78AF528C76293
     */
    IVault public immutable SWAAP_VAULT;

    bytes32 public immutable ERC20_ADAPTOR_IDENTIFIER;

    /**
     * @notice The enum value needed to specify the join and exit type on Safeguard pools.
     */
    enum JoinKind {
        INIT,
        ALL_TOKENS_IN_FOR_EXACT_SPT_OUT,
        EXACT_TOKENS_IN_FOR_SPT_OUT
    }
    enum ExitKind {
        EXACT_SPT_IN_FOR_TOKENS_OUT,
        SPT_IN_FOR_EXACT_TOKENS_OUT
    }

    //============================================ Constructor ===========================================

    /**
     * @notice Constructs the Swaap Pool Adaptor
     * @param _swaapVault the address of the Swaap Vault
     * @param _erc20Adaptor the address of the ERC20 Adaptor
     */
    constructor(address _swaapVault, address _erc20Adaptor) {
        SWAAP_VAULT = IVault(_swaapVault);
        ERC20_ADAPTOR_IDENTIFIER = BaseAdaptor(_erc20Adaptor).identifier();
    }

    //============================================ Global Functions ===========================================

    /**
     * @notice Identifier unique to this adaptor for a shared registry.
     * Normally the identifier would just be the address of this contract, but this identifier is needed during Cellar Delegate Call Operations, so getting the address of the adaptor is more difficult.
     * @return encoded adaptor identifier
     */
    function identifier() public pure virtual override returns (bytes32) {
        return keccak256(abi.encode("Swaap Pool Adaptor V 1.0"));
    }

    //============================================ Strategist Functions ===========================================

    /**
     * @notice Allows strategists to join Swaap pools using all tokens (without swaps) when allowlist in on.
     */
    function joinPoolWithAllowlistOn(
        ERC20 targetPool,
        ERC20[] memory expectedTokensIn,
        uint256[] memory maxAmountsIn,
        uint256 requestedSpt,
        uint256 deadline,
        bytes memory allowlistSignatureData
    ) external {
        if (!ISafeguardPool(address(targetPool)).isAllowlistEnabled()) {
            joinPool(targetPool, expectedTokensIn, maxAmountsIn, requestedSpt);
        } else {
            bytes memory userData = abi.encode(
                deadline,
                allowlistSignatureData,
                abi.encode(JoinKind.ALL_TOKENS_IN_FOR_EXACT_SPT_OUT, requestedSpt)
            );

            _joinPool(targetPool, expectedTokensIn, maxAmountsIn, userData);
        }
    }

    /**
     * @notice Allows strategists to join Swaap pools using all tokens (without swaps).
     */
    function joinPool(
        ERC20 targetPool,
        ERC20[] memory expectedTokensIn,
        uint256[] memory maxAmountsIn,
        uint256 requestedSpt
    ) public {
        bytes memory userData = abi.encode(JoinKind.ALL_TOKENS_IN_FOR_EXACT_SPT_OUT, requestedSpt);
        _joinPool(targetPool, expectedTokensIn, maxAmountsIn, userData);
    }

    function _joinPool(
        ERC20 targetPool,
        ERC20[] memory expectedTokensIn,
        uint256[] memory maxAmountsIn,
        bytes memory userData
    ) internal {
        // verify that the spt is used and tracked in the calling cellar
        _validateTokenIsUsed(targetPool);

        uint256 length = expectedTokensIn.length;
        if (length != maxAmountsIn.length) revert SwaapPoolAdaptor___LengthMismatch();

        bytes32 poolId = IBasePool(address(targetPool)).getPoolId();

        // Start formulating request.
        IVault.JoinPoolRequest memory request;

        (IERC20[] memory poolTokens, , ) = SWAAP_VAULT.getPoolTokens(poolId);

        // Ensure pool tokens has the same length as expectedTokensIn.
        if (poolTokens.length != expectedTokensIn.length) revert SwaapPoolAdaptor___LengthMismatch();

        request.assets = new IAsset[](length);

        for (uint256 i; i < length; ++i) {
            if (address(poolTokens[i]) != address(expectedTokensIn[i]))
                revert SwaapPoolAdaptor___PoolTokenAndExpectedTokenMismatch();
            request.assets[i] = IAsset(address(poolTokens[i]));
            expectedTokensIn[i].safeApprove(address(SWAAP_VAULT), maxAmountsIn[i]);
        }

        request.maxAmountsIn = maxAmountsIn;

        request.userData = userData;

        SWAAP_VAULT.joinPool(poolId, address(this), address(this), request);

        // If we had to swap for an asset, revoke any unused approval from join.
        for (uint256 i; i < length; ++i) {
            // Revoke input asset approval.
            _revokeExternalApproval(expectedTokensIn[i], address(SWAAP_VAULT));
        }
    }

    /**
     * @notice Allows strategists to exit Swaap pools with all tokens (no swaps).
     */
    function exitPool(
        ERC20 targetPool,
        ERC20[] memory expectedTokensOut,
        uint256[] memory minAmountsOut,
        uint256 burnSpt
    ) external {
        uint256 length = expectedTokensOut.length;
        if (length != minAmountsOut.length) revert SwaapPoolAdaptor___LengthMismatch();

        bytes32 poolId = IBasePool(address(targetPool)).getPoolId();

        // Start formulating request.
        IVault.ExitPoolRequest memory request;

        (IERC20[] memory poolTokens, , ) = SWAAP_VAULT.getPoolTokens(poolId);

        // Ensure pool tokens has the same length as expectedTokensOut.
        if (poolTokens.length != expectedTokensOut.length) revert SwaapPoolAdaptor___LengthMismatch();

        request.assets = new IAsset[](length);

        for (uint256 i; i < length; ++i) {
            if (address(poolTokens[i]) != address(expectedTokensOut[i]))
                revert SwaapPoolAdaptor___PoolTokenAndExpectedTokenMismatch();
            _validateTokenIsUsed(expectedTokensOut[i]);
            request.assets[i] = IAsset(address(poolTokens[i]));
        }

        request.minAmountsOut = minAmountsOut;
        request.userData = abi.encode(ExitKind.EXACT_SPT_IN_FOR_TOKENS_OUT, burnSpt);

        SWAAP_VAULT.exitPool(poolId, address(this), payable(address(this)), request);
    }

    /**
     * @notice Start a flash loan using Swaap.
     */
    function makeFlashLoan(IERC20[] memory tokens, uint256[] memory amounts, bytes memory data) public {
        SWAAP_VAULT.flashLoan(IFlashLoanRecipient(address(this)), tokens, amounts, data);
    }

    //============================================ Helper Functions ===========================================

    function _validateTokenIsUsed(ERC20 token) internal view {
        bytes memory adaptorData = abi.encode(token);
        // This adaptor has no underlying position, so no need to validate token out.
        bytes32 positionHash = keccak256(abi.encode(ERC20_ADAPTOR_IDENTIFIER, false, adaptorData));
        uint32 positionId = Cellar(address(this)).registry().getPositionHashToPositionId(positionHash);
        if (!Cellar(address(this)).isPositionUsed(positionId)) revert BaseAdaptor__PositionNotUsed(adaptorData);
    }
}
