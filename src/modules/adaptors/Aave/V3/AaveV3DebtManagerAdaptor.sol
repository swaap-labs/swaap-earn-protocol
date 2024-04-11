// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BaseAdaptor, ERC20, SafeTransferLib, Fund, Registry } from "src/modules/adaptors/BaseAdaptor.sol";
import { IPoolV3 } from "src/interfaces/external/IPoolV3.sol";
import { IAaveToken } from "src/interfaces/external/IAaveToken.sol";
import { AaveV3AccountHelper } from "./AaveV3AccountHelper.sol";
import { ICreditDelegationToken } from "src/interfaces/external/ICreditDelegationToken.sol";
import { AaveV3AccountExtension } from "./AaveV3AccountExtension.sol";

/**
 * @title Aave debtToken Adaptor
 * @notice Allows Funds to interact with Aave debtToken positions.
 */
contract AaveV3DebtManagerAdaptor is BaseAdaptor, AaveV3AccountHelper {
    using SafeTransferLib for ERC20;

    //==================== Adaptor Data Specification ====================
    // adaptorData = abi.encode(uint8 accountId, address debtToken)
    // Where:
    // `accountId` is the account extension id this adaptor is working with
    // `debtToken` is the debtToken address position this adaptor is working with
    //================= Configuration Data Specification =================
    // NOT USED
    //====================================================================

    /**
     @notice Attempted borrow would lower Fund health factor too low.
     */
    error AaveV3DebtManagerAdaptor__HealthFactorTooLow();

    /**
     * @notice Minimum Health Factor enforced after every borrow.
     * @notice Overwrites strategist set minimums if they are lower.
     */
    uint256 public immutable minimumHealthFactor;

    constructor(address v3Pool, uint256 minHealthFactor) AaveV3AccountHelper(v3Pool) {
        _verifyConstructorMinimumHealthFactor(minHealthFactor);
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
        return keccak256(abi.encode("Aave V3 debtToken Account Manager Adaptor V 1.0"));
    }

    //============================================ Implement Base Functions ===========================================

    /**
     * @notice User deposits are NOT allowed into this position.
     */
    function deposit(uint256, bytes memory, bytes memory) public pure override {
        revert BaseAdaptor__UserDepositsNotAllowed();
    }

    /**
     * @notice User withdraws are NOT allowed from this position.
     */
    function withdraw(uint256, address, bytes memory, bytes memory) public pure override {
        revert BaseAdaptor__UserWithdrawsNotAllowed();
    }

    /**
     * @notice This position is a debt position, and user withdraws are not allowed so
     *         this position must return 0 for withdrawableFrom.
     */
    function withdrawableFrom(bytes memory, bytes memory) public pure override returns (uint256) {
        return 0;
    }

    /**
     * @notice Returns the funds balance of the positions debtToken.
     */
    function balanceOf(bytes memory adaptorData) public view override returns (uint256) {
        (address accountAddress, address debtToken) = _extractAdaptorData(adaptorData, msg.sender);
        // no need to check if the account extension exists, if it does not it can't / shouldn't have any debt as aave debt is not transferable
        return ERC20(debtToken).balanceOf(accountAddress);
    }

    /**
     * @notice Returns the positions debtToken underlying asset.
     */
    function assetOf(bytes memory adaptorData) public view override returns (ERC20) {
        (, address debtToken) = _extractAdaptorData(adaptorData, msg.sender);
        return ERC20(IAaveToken(debtToken).UNDERLYING_ASSET_ADDRESS());
    }

    /**
     * @notice This adaptor reports values in terms of debt.
     */
    function isDebt() public pure override returns (bool) {
        return true;
    }

    //============================================ Strategist Functions ===========================================

    /**
     * @notice Allows strategists to borrow assets from Aave.
     * @notice `debtTokenToBorrow` must be the debtToken, NOT the underlying ERC20.
     * @param debtTokenToBorrow the debtToken to borrow on Aave
     * @param amountToBorrow the amount of `debtTokenToBorrow` to borrow on Aave.
     */
    function borrowFromAave(uint8 accountId, ERC20 debtTokenToBorrow, uint256 amountToBorrow) public {
        _validateDebtToken(accountId, debtTokenToBorrow);

        // should revert if account extension does not exist
        address accountAddress = _getAccountAddressAndVerify(accountId, address(this));

        _requestAaveDebtDelegationIfNecessary(accountAddress, address(debtTokenToBorrow), amountToBorrow);

        // Open up new variable debt position on Aave.
        pool.borrow(
            IAaveToken(address(debtTokenToBorrow)).UNDERLYING_ASSET_ADDRESS(),
            amountToBorrow,
            2,
            0,
            accountAddress
        ); // 2 is the interest rate mode, either 1 for stable or 2 for variable

        // Check that health factor is above adaptor minimum.
        (, , , , , uint256 healthFactor) = pool.getUserAccountData(accountAddress);
        if (healthFactor < minimumHealthFactor) revert AaveV3DebtManagerAdaptor__HealthFactorTooLow();
    }

    /**
     * @notice Allows strategists to repay loan debt on Aave.
     * @dev Uses `_maxAvailable` helper function, see BaseAdaptor.sol
     * @param underlyingToken the underlying ERC20 token you want to repay, NOT the debtToken.
     * @param amountToRepay the amount of `tokenToRepay` to repay with.
     */
    function repayAaveDebt(uint8 accountId, ERC20 underlyingToken, uint256 amountToRepay) public {
        // we don't need to check if the debt token exists or if the adaptor data is valid,
        // as the debt is not transferable and there is no way to obtain it without borrowing it beforehand
        // by validating that the adaptor data is tracked by the fund
        // _validateDebtToken(accountId, IAaveToken(address(tokenToRepay))

        // should revert if account extension does not exist
        address accountAddress = _getAccountAddressAndVerify(accountId, address(this));
        underlyingToken.safeApprove(address(pool), amountToRepay);
        pool.repay(address(underlyingToken), amountToRepay, 2, accountAddress); // 2 is the interest rate mode,  either 1 for stable or 2 for variable

        // Zero out approvals if necessary.
        _revokeExternalApproval(underlyingToken, address(pool));
    }

    /**
     * @notice Allows strategist to use aTokens to repay debt tokens with the same underlying.
     */
    function repayWithATokens(uint8 accountId, ERC20 underlyingToken, uint256 amount) public {
        address accountAddress = _getAccountAddressAndVerify(accountId, address(this));
        AaveV3AccountExtension(accountAddress).repayWithATokens(underlyingToken, amount);
    }

    /**
     * @notice allows strategist to have Funds take out flash loans.
     * @param loanToken address array of tokens to take out loans
     * @param loanAmount uint256 array of loan amounts for each `loanToken`
     * @dev `modes` is always a zero array meaning that this flash loan can NOT take on new debt positions, it must be paid in full.
     */
    function flashLoan(address[] memory loanToken, uint256[] memory loanAmount, bytes memory params) public {
        require(loanToken.length == loanAmount.length, "Input length mismatch.");
        uint256[] memory modes = new uint256[](loanToken.length);
        pool.flashLoan(address(this), loanToken, loanAmount, modes, address(this), params, 0);
    }

    function _requestAaveDebtDelegationIfNecessary(address accountAddress, address debtToken, uint256 amount) internal {
        if (ICreditDelegationToken(debtToken).borrowAllowance(accountAddress, address(this)) < amount) {
            AaveV3AccountExtension(accountAddress).approveDebtDelegationToFund(debtToken);
        }
    }

    function _validateDebtToken(uint8 accountId, ERC20 debtToken) internal view {
        _verifyUsedPosition(abi.encode(accountId, debtToken));
    }
}
