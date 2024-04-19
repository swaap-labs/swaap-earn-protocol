// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BaseAdaptor, ERC20, SafeTransferLib, Fund, PriceRouter, Math } from "src/modules/adaptors/BaseAdaptor.sol";
import { IAaveToken } from "src/interfaces/external/IAaveToken.sol";
import { IAaveOracle } from "src/interfaces/external/IAaveOracle.sol";
import { AaveV3AccountHelper, Address } from "./AaveV3AccountHelper.sol";
import { AaveV3AccountExtension } from "./AaveV3AccountExtension.sol";

/**
 * @title Aave aToken Adaptor
 * @notice Allows Funds to interact with Aave aToken positions.
 */
contract AaveV3ATokenManagerAdaptor is BaseAdaptor, AaveV3AccountHelper {
    using SafeTransferLib for ERC20;
    using Math for uint256;

    //==================== Adaptor Data Specification ====================
    // adaptorData = abi.encode(uint8 accountId, address aToken)
    // Where:
    // `accountId` is the account extension id this adaptor is working with
    // `aToken` is the aToken address the position this adaptor is working with
    //================= Configuration Data Specification =================
    // configurationData = abi.encode(minimumHealthFactor uint256)
    // Where:
    // `minimumHealthFactor` dictates how much assets can be taken from this position
    // If zero:
    //      position returns ZERO for `withdrawableFrom`
    // else:
    //      position calculates `withdrawableFrom` based off minimum specified
    //      position reverts if a user withdraw lowers health factor below minimum
    //
    // **************************** IMPORTANT ****************************
    // It's advised for Funds with multiple aToken positions to specify the minimum
    // health factor on ONE of the positions only as withdrawing from multiple positions
    // can lead to a lower health factor than expected and thus revert.
    // An aToken should always have a position in the fund as well as a position
    // for its underlying asset. The adapter does not check the latter for gas optimzation purposes.
    //====================================================================

    /**
     @notice Attempted withdraw would lower Fund health factor too low.
     */
    error AaveV3ATokenAdaptor__HealthFactorTooLow();

    /**
     * @notice Aave V3 oracle uses a different base asset than this contract was designed for.
     */
    error AaveV3ATokenAdaptor__OracleUsesDifferentBase();

    /**
     * @notice This value is used to prevent calculation errors when computing the max withdrawable
     * amount before going under the minimum configured HF.
     * @dev This value can be modified based on testing.
     */
    uint256 internal constant _CUSHION = 0.01e18;

    /// @dev Used to convert from BPS (4 decimals) to WAD (18 decimals).
    uint256 internal constant _BPS_TO_WAD = 1e14;

    /// @dev expected USD units as base currency.
    uint256 internal constant _USD_CURRENCY_UNIT = 1e8;

    /**
     * @notice The Aave V3 Oracle on current network.
     * @dev For mainnet use 0x54586bE62E3c3580375aE3723C145253060Ca0C2.
     */
    IAaveOracle public immutable aaveOracle;

    /**
     * @notice Minimum Health Factor enforced after every aToken withdraw.
     * @notice Overwrites strategist set minimums if they are lower.
     */
    uint256 public immutable minimumHealthFactor;

    constructor(address v3Pool, address v3Oracle, uint256 minHealthFactor) AaveV3AccountHelper(v3Pool) {
        _verifyConstructorMinimumHealthFactor(minHealthFactor);
        aaveOracle = IAaveOracle(v3Oracle);
        minimumHealthFactor = minHealthFactor;
    }

    //============================================ Global Functions ===========================================
    /**
     * @dev Identifier unique to this adaptor for a shared registry.
     * Normally the identifier would just be the address of this contract, but this
     * Identifier is needed during Fund Delegate Call Operations, so getting the address
     * of the adaptor is more difficult.
     */
    function identifier() public pure override returns (bytes32) {
        return keccak256(abi.encode("Aave V3 aToken Account Manager Adaptor V 1.0"));
    }

    //============================================ Implement Base Functions ===========================================
    /**
     * @notice Fund must approve Pool to spend its assets, then call deposit to lend its assets.
     * @param assets the amount of assets to lend on Aave
     * @param adaptorData adaptor data containining the abi encoded aToken
     * @dev configurationData is NOT used because this action will only increase the health factor
     */
    function deposit(uint256 assets, bytes memory adaptorData, bytes memory) public override {
        // we need to verify that the position is used by the fund before depositing assets
        // this is to prevent the strategist from depositing assets into a position that is not used by the fund
        _verifyUsedPositionIfDeployed(adaptorData);

        // Deposit assets to Aave.
        (uint8 accountId, address aToken) = _decodeAdaptorData(adaptorData);

        address accountAddress = _createAccountExtensionIfNeeded(accountId);

        ERC20 token = ERC20(IAaveToken(aToken).UNDERLYING_ASSET_ADDRESS());

        // instead of transferting the assets to the account, we deposit to the pool on behalf of the account
        // for gas optimization purposes
        token.safeApprove(address(pool), assets);
        pool.supply(address(token), assets, accountAddress, 0);

        // Zero out approvals if necessary.
        _revokeExternalApproval(token, address(pool));
    }

    /**
     @notice Funds must withdraw from Aave, check if a minimum health factor is specified
     *       then transfer assets to receiver.
     * @dev Important to verify that external receivers are allowed if receiver is not Fund address.
     * @param assets the amount of assets to withdraw from Aave
     * @param receiver the address to send withdrawn assets to
     * @param adaptorData adaptor data containining the abi encoded aToken
     * @param configData abi encoded minimum health factor, if zero user withdraws are not allowed.
     */
    function withdraw(
        uint256 assets,
        address receiver,
        bytes memory adaptorData,
        bytes memory configData
    ) public override {
        // Run external receiver check.
        _externalReceiverCheck(receiver);

        // Withdraw assets from Aave.
        (address accountAddress, address aToken) = _extractAdaptorDataAndVerify(adaptorData, address(this));
        address underlyingAsset = IAaveToken(aToken).UNDERLYING_ASSET_ADDRESS();

        AaveV3AccountExtension(accountAddress).withdrawFromAave(receiver, underlyingAsset, assets);

        (, uint256 totalDebtBase, , , , uint256 healthFactor) = pool.getUserAccountData(accountAddress);
        if (totalDebtBase > 0) {
            // If fund has entered an EMode, and has debt, user withdraws are not allowed.
            if (pool.getUserEMode(accountAddress) != 0) revert BaseAdaptor__UserWithdrawsNotAllowed();

            // Run minimum health factor checks.
            uint256 minHealthFactor = abi.decode(configData, (uint256));
            if (minHealthFactor == 0) {
                revert BaseAdaptor__UserWithdrawsNotAllowed();
            }
            // Check if adaptor minimum health factor is more conservative than strategist set.
            if (minHealthFactor < minimumHealthFactor) minHealthFactor = minimumHealthFactor;
            if (healthFactor < minHealthFactor) revert AaveV3ATokenAdaptor__HealthFactorTooLow();
        }
    }

    /**
     * @notice Uses configurartion data minimum health factor to calculate withdrawable assets from Aave.
     * @dev Applies a `cushion` value to the health factor checks and calculation.
     *      The goal of this is to minimize scenarios where users are withdrawing a very small amount of
     *      assets from Aave. This function returns zero if
     *      -minimum health factor is NOT set.
     *      -the current health factor is less than the minimum health factor + 2x `cushion`
     *      Otherwise this function calculates the withdrawable amount using
     *      minimum health factor + `cushion` for its calcualtions.
     * @dev It is possible for the math below to lose a small amount of precision since it is only
     *      maintaining 18 decimals during the calculation, but this is desired since
     *      doing so lowers the withdrawable from amount which in turn raises the health factor.
     */
    function withdrawableFrom(
        bytes memory adaptorData,
        bytes memory configData
    ) public view override returns (uint256) {
        (address accountAddress, address aToken) = _extractAdaptorData(adaptorData, msg.sender);

        // if the account does not exist (yet) but has aToken sent to it, we still want to return 0
        // because the fund cannot withdraw from it unless it has been created
        if (!Address.isContract(accountAddress)) return 0;

        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            ,
            uint256 currentLiquidationThreshold,
            ,
            uint256 healthFactor
        ) = pool.getUserAccountData(accountAddress);

        // If Fund has no Aave debt, then return the funds balance of the aToken.
        if (totalDebtBase == 0) return ERC20(aToken).balanceOf(accountAddress);

        // Fund has Aave debt, so if fund is entered into a non zero emode, return 0.
        if (pool.getUserEMode(accountAddress) != 0) return 0;

        // Otherwise we need to look at minimum health factor.
        uint256 minHealthFactor = abi.decode(configData, (uint256));
        // Check if minimum health factor is set.
        // If not the strategist does not want users to withdraw from this position.
        if (minHealthFactor == 0) return 0;
        // Check if adaptor minimum health factor is more conservative than strategist set.
        if (minHealthFactor < minimumHealthFactor) minHealthFactor = minimumHealthFactor;

        uint256 maxBorrowableWithMin;

        // Add cushion to min health factor.
        minHealthFactor += _CUSHION;

        // If current health factor is less than the minHealthFactor + 2X cushion, return 0.
        if (healthFactor < (minHealthFactor + _CUSHION)) return 0;
        // Calculate max amount withdrawable while preserving minimum health factor.
        else {
            maxBorrowableWithMin =
                totalCollateralBase -
                minHealthFactor.mulDivDown(totalDebtBase, (currentLiquidationThreshold * _BPS_TO_WAD));
        }
        /// @dev We want right side of "-" to have 8 decimals, so we need to dviide by 18 decimals.
        // `currentLiquidationThreshold` has 4 decimals, so multiply by 1e14 to get 18 decimals on denominator.

        // Need to convert Base into position underlying.
        ERC20 underlyingAsset = ERC20(IAaveToken(aToken).UNDERLYING_ASSET_ADDRESS());

        // Convert `maxBorrowableWithMin` from Base to position underlying asset.
        PriceRouter priceRouter = Fund(msg.sender).priceRouter();
        uint256 underlyingAssetToUSD = priceRouter.getPriceInUSD(underlyingAsset);
        uint256 withdrawable = maxBorrowableWithMin.mulDivDown(10 ** underlyingAsset.decimals(), underlyingAssetToUSD);
        uint256 balance = ERC20(aToken).balanceOf(accountAddress);
        // Check if withdrawable is greater than the position balance and if so return the balance instead of withdrawable.
        return withdrawable > balance ? balance : withdrawable;
    }

    /**
     * @notice Returns the funds balance of the positions aToken.
     */
    function balanceOf(bytes memory adaptorData) public view override returns (uint256) {
        (address accountAddress, address aToken) = _extractAdaptorData(adaptorData, msg.sender);

        // if the account does not exist (yet) but has aToken sent to it, we still want to return 0
        // because the fund cannot withdraw from it unless it has been created
        if (!Address.isContract(accountAddress)) return 0;

        return ERC20(aToken).balanceOf(accountAddress);
    }

    /**
     * @notice Returns the positions aToken underlying asset.
     */
    function assetOf(bytes memory adaptorData) public view override returns (ERC20) {
        (, address aToken) = _decodeAdaptorData(adaptorData);
        return ERC20(IAaveToken(aToken).UNDERLYING_ASSET_ADDRESS());
    }

    function assetsUsed(bytes memory adaptorData) public view override returns (ERC20[] memory assets) {
        assets = new ERC20[](1);
        assets[0] = assetOf(adaptorData);

        // Make sure Aave Oracle uses USD base asset with 8 decimals.
        // BASE_CURRENCY and BASE_CURRENCY_UNIT are both immutable values, so only check this on initial position setup.
        if (aaveOracle.BASE_CURRENCY() != address(0) || aaveOracle.BASE_CURRENCY_UNIT() != _USD_CURRENCY_UNIT)
            revert AaveV3ATokenAdaptor__OracleUsesDifferentBase();
    }

    /**
     * @notice This adaptor returns collateral, and not debt.
     */
    function isDebt() public pure override returns (bool) {
        return false;
    }

    //============================================ Strategist Functions ===========================================
    /**
     * @notice Allows strategists to lend assets on Aave.
     * @dev Uses `_maxAvailable` helper function, see BaseAdaptor.sol
     * @param accountId the account id to lend on Aave
     * @param aToken the token to lend on Aave (corresponds to the aToken)
     * @param amountToDeposit the amount of `tokenToDeposit` to lend on Aave.
     */
    function depositToAave(uint8 accountId, IAaveToken aToken, uint256 amountToDeposit) public {
        // since this function can be called by the strategist, we need to verify that the adaptorData is defined in
        // in a position that is used by the fund
        _validateAToken(accountId, aToken);

        address accountAddress = _createAccountExtensionIfNeeded(accountId);

        ERC20 tokenToDeposit = ERC20(aToken.UNDERLYING_ASSET_ADDRESS());

        amountToDeposit = _maxAvailable(tokenToDeposit, amountToDeposit);
        tokenToDeposit.safeApprove(address(pool), amountToDeposit);
        pool.supply(address(tokenToDeposit), amountToDeposit, accountAddress, 0);

        // Zero out approvals if necessary.
        _revokeExternalApproval(tokenToDeposit, address(pool));
    }

    /**
     * @notice Allows strategists to withdraw assets from Aave.
     * @param underlyingToken the underlying token to withdraw from Aave.
     * @param amountToWithdraw the amount of `tokenToWithdraw` to withdraw from Aave
     */
    function withdrawFromAave(uint8 accountId, address underlyingToken, uint256 amountToWithdraw) public {
        // should revert if account extension does not exist
        address accountAddress = _getAccountAddressAndVerify(accountId, address(this));

        AaveV3AccountExtension(accountAddress).withdrawFromAave(address(this), underlyingToken, amountToWithdraw);

        // Check that health factor is above adaptor minimum.
        (, , , , , uint256 healthFactor) = pool.getUserAccountData(accountAddress);
        if (healthFactor < minimumHealthFactor) revert AaveV3ATokenAdaptor__HealthFactorTooLow();
    }

    /**
     * @notice Allows strategists to adjust an asset's isolation mode.
     * @param accountId the account id to adjust isolation mode / colalteral mode for
     * @param underlyingToken the underlying asset to adjust isolation mode / collateral mode for
     * @param useAsCollateral whether to use the asset as collateral or not
     */
    function adjustIsolationModeAssetAsCollateral(
        uint8 accountId,
        address underlyingToken,
        bool useAsCollateral
    ) public {
        // should revert if account extension does not exist
        address accountAddress = _getAccountAddressAndVerify(accountId, address(this));

        AaveV3AccountExtension(accountAddress).adjustIsolationModeAssetAsCollateral(underlyingToken, useAsCollateral);

        // Check that health factor is above adaptor minimum.
        (, , , , , uint256 healthFactor) = pool.getUserAccountData(accountAddress);
        if (healthFactor < minimumHealthFactor) revert AaveV3ATokenAdaptor__HealthFactorTooLow();
    }

    /**
     * @notice Allows strategist to use aTokens to repay debt tokens with the same underlying.
     * @param accountId the id of the account used as an extension to the fund.
     * @param aToken any aave aToken used in the account that is used by a position in the fund.
     */
    function createAccountExtension(uint8 accountId, IAaveToken aToken) public returns (address) {
        _validateAToken(accountId, aToken);
        return _createAccountExtensionIfNeeded(accountId);
    }

    function _validateAToken(uint8 accountId, IAaveToken aToken) internal view {
        // should revert if account extension does not exist
        _verifyUsedPosition(abi.encode(accountId, address(aToken)));
    }
}
