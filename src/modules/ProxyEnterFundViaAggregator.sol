// SPDX-License-Identifier: GPL-3.0-or-later
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.

// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <http://www.gnu.org/licenses/>.

/*
                                      s███
                                    ██████
                                   @██████
                              ,s███`
                           ,██████████████
                          █████████^@█████_
                         ██████████_ 7@███_            "█████████M
                        @██████████_     `_              "@█████b
                        ^^^^^^^^^^"                         ^"`
                         
                        ████████████████████p   _█████████████████████
                        @████████████████████   @███████████WT@██████b
                         ████████████████████   @███████████  ,██████
                         @███████████████████   @███████████████████b
                          @██████████████████   @██████████████████b
                           "█████████████████   @█████████████████b
                             @███████████████   @████████████████
                               %█████████████   @██████████████`
                                 ^%██████████   @███████████"
                                     ████████   @██████W"`
                                     1███████
                                      "@█████
                                         7W@█
*/

pragma solidity ^0.8.21;

import { Pausable } from "@openzeppelin/contracts/security/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { FundWithShareLockFlashLoansWhitelisting } from "src/base/permutations/FundWithShareLockFlashLoansWhitelisting.sol";
import { IWETH9 } from "src/interfaces/external/IWETH9.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";
import { console } from "@forge-std/console.sol";

/**
 * @title ProxyJoinExitViaAggregator
 */
contract ProxyEnterFundViaAggregator is ReentrancyGuard, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;
    using Address for address;
    using Address for address payable;

    /// @notice Raised when the deadline is passed for an action
    error ProxyEnterFundViaAggregator__InvalidAggregator();
    error ProxyEnterFundViaAggregator__ETHTransfer();
    error ProxyEnterFundViaAggregator__InvalidCallSelector();
    error ProxyEnterFundViaAggregator__InvalidETHTransferAmount();
    error ProxyEnterFundViaAggregator__MinBoughtTokensNotMet();
    error ProxyEnterFundViaAggregator__MinBoughtSharesNotMet();
    error ProxyEnterFundViaAggregator__PermitFailed();
    error ProxyEnterFundViaAggregator__PassedDeadline();
    error ProxyEnterFundViaAggregator__SAME_TOKENS();

    struct Quote {
        address targetAggregator;
        address spender;
        uint256 buyAmount;
        bytes quoteCallData;
    }

    modifier beforeDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert ProxyEnterFundViaAggregator__PassedDeadline();
        _;
    }

    address public constant NATIVE_ADDRESS = address(0);

    IWETH9 public immutable WETH;
    address public immutable PARASWAP;
    address public immutable ONE_INCH;
    address public immutable ODOS;
    address public immutable ZERO_EX;

    constructor(address owner, address weth, address paraswap, address oneInch, address odos, address zeroEx) {
        WETH = IWETH9(weth);
        PARASWAP = paraswap;
        ONE_INCH = oneInch;
        ODOS = odos;
        ZERO_EX = zeroEx;
        transferOwnership(owner);
    }

    /**
     * @notice Executes multiple calls in a single transaction.
     * @dev This function can allow a user to permit one or multiple tokens and then enter a fund in a single transaction.
     */
    function multicall(bytes[] calldata data) external payable {
        for (uint256 i; i < data.length; ++i) address(this).functionDelegateCall(data[i]);
    }

    /**
     * @notice Gets token allowance using permit.
     * @param assetToUse Address of the token to convert (wrapping or trading) to the fund's asset
     * @param permitAllowance Amount of token to allow
     * @param permitDeadline Deadline for the permit
     * @param v Component of the signature
     * @param r Component of the signature
     * @param s Component of the signature
     */
    function permitERC20ToProxy(
        address assetToUse,
        uint256 permitAllowance,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external whenNotPaused nonReentrant {
        uint256 nonceBefore = IERC20Permit(assetToUse).nonces(msg.sender);

        (bool success, ) = assetToUse.call(
            abi.encodeWithSelector(
                IERC20Permit.permit.selector,
                msg.sender,
                address(this),
                permitAllowance,
                permitDeadline,
                v,
                r,
                s
            )
        );

        if (!success) revert ProxyEnterFundViaAggregator__PermitFailed();

        uint256 nonceAfter = IERC20Permit(assetToUse).nonces(msg.sender);

        if (!success || nonceAfter != nonceBefore + 1) revert ProxyEnterFundViaAggregator__PermitFailed();
    }

    /**
     * @notice Trades with an aggregator and then deposits into a fund.
     * @param fund Address of the fund to deposit into
     * @param assetToUse Address of the token to convert (wrapping or trading) to the fund's asset
     * @param maxAmountToUse Max amount of token to use for conversion
     * @param minSharesOut Min amount of shares to receive from the fund
     * @param deadline Deadline for the action
     * @param fillQuote Quote data for the trade
     * @param permissionSignedAt Timestamp when the whitelisting permission was signed at
     * @param permitData Permit data for the whitelisting
     */
    function whitelistDepositViaAggregator(
        address fund,
        address assetToUse,
        uint256 maxAmountToUse,
        uint256 minSharesOut,
        uint256 deadline,
        Quote calldata fillQuote,
        uint256 permissionSignedAt,
        bytes calldata permitData
    ) external payable whenNotPaused nonReentrant beforeDeadline(deadline) returns (uint256 sharesOut) {
        (address fundDepositAsset, uint256 fundDepositAmount, uint256 sharesBefore) = _beforeEnter(
            fund,
            assetToUse,
            maxAmountToUse,
            fillQuote
        );

        FundWithShareLockFlashLoansWhitelisting(fund).whitelistDeposit(
            fundDepositAmount,
            msg.sender,
            permissionSignedAt,
            permitData
        );

        sharesOut = _afterEnter(fund, fundDepositAsset, assetToUse, minSharesOut, sharesBefore);

        return sharesOut;
    }

    /**
     * @notice Trades with an aggregator and then deposits into a fund.
     * @param fund Address of the fund to deposit into
     * @param assetToUse Address of the token to convert (wrapping or trading) to the fund's asset
     * @param maxAmountToUse Max amount of token to use for conversion
     * @param minSharesOut Min amount of shares to receive from the fund
     * @param deadline Deadline for the action
     * @param fillQuote Quote data for the trade
     */
    function depositViaAggregator(
        address fund,
        address assetToUse,
        uint256 maxAmountToUse,
        uint256 minSharesOut,
        uint256 deadline,
        Quote calldata fillQuote
    ) external payable whenNotPaused nonReentrant beforeDeadline(deadline) returns (uint256 sharesOut) {
        (address fundDepositAsset, uint256 fundDepositAmount, uint256 sharesBefore) = _beforeEnter(
            fund,
            assetToUse,
            maxAmountToUse,
            fillQuote
        );

        FundWithShareLockFlashLoansWhitelisting(fund).deposit(fundDepositAmount, msg.sender);

        sharesOut = _afterEnter(fund, fundDepositAsset, assetToUse, minSharesOut, sharesBefore);

        return sharesOut;
    }

    /**
     * @notice Trades with an aggregator and mints a fixed amount shares from a fund.
     * @param fund Address of the fund to mint shares from
     * @param assetToUse Address of the token to convert (wrapping or trading) to the fund's asset
     * @param maxAmountToUse Max amount of token to use for conversion
     * @param expectedSharesOut Fixed amount of shares to receive from the fund
     * @param deadline Deadline for the action
     * @param fillQuote Quote data for the trade
     * @param permissionSignedAt Timestamp when the whitelisting permission was signed at
     * @param permitData Permit data for the whitelisting
     */
    function whitelistMintViaAggregator(
        address fund,
        address assetToUse,
        uint256 maxAmountToUse,
        uint256 expectedSharesOut,
        uint256 deadline,
        Quote calldata fillQuote,
        uint256 permissionSignedAt,
        bytes calldata permitData
    ) external payable whenNotPaused nonReentrant beforeDeadline(deadline) returns (uint256 usedAssets) {
        (address fundDepositAsset, , uint256 sharesBefore) = _beforeEnter(fund, assetToUse, maxAmountToUse, fillQuote);

        usedAssets = FundWithShareLockFlashLoansWhitelisting(fund).whitelistMint(
            expectedSharesOut,
            msg.sender,
            permissionSignedAt,
            permitData
        );

        _afterEnter(fund, fundDepositAsset, assetToUse, expectedSharesOut, sharesBefore);

        return usedAssets;
    }

    /**
     * @notice Trades with an aggregator and mints a fixed amount shares from a fund.
     * @param fund Address of the fund to mint shares from
     * @param assetToUse Address of the token to convert (wrapping or trading) to the fund's asset
     * @param maxAmountToUse Max amount of token to use for conversion
     * @param expectedSharesOut Fixed amount of shares to receive from the fund
     * @param deadline Deadline for the action
     * @param fillQuote Quote data for the trade
     */
    function mintViaAggregator(
        address fund,
        address assetToUse,
        uint256 maxAmountToUse,
        uint256 expectedSharesOut,
        uint256 deadline,
        Quote calldata fillQuote
    ) external payable whenNotPaused nonReentrant beforeDeadline(deadline) returns (uint256 usedAssets) {
        (address fundDepositAsset, , uint256 sharesBefore) = _beforeEnter(fund, assetToUse, maxAmountToUse, fillQuote);

        usedAssets = FundWithShareLockFlashLoansWhitelisting(fund).mint(expectedSharesOut, msg.sender);

        _afterEnter(fund, fundDepositAsset, assetToUse, expectedSharesOut, sharesBefore);

        return usedAssets;
    }

    function _beforeEnter(
        address fund,
        address assetToUse,
        uint256 maxAmountToUse,
        Quote calldata fillQuote
    ) internal returns (address fundDepositAsset, uint256 fundDepositAmount, uint256 sharesBefore) {
        _transferFromAll(assetToUse, maxAmountToUse);

        if (_isNative(assetToUse)) {
            assetToUse = address(WETH);
        }

        fundDepositAsset = address(FundWithShareLockFlashLoansWhitelisting(fund).asset());

        fundDepositAmount = assetToUse != fundDepositAsset
            ? _tradeAssetsExternally(assetToUse, fundDepositAsset, maxAmountToUse, fillQuote)
            : maxAmountToUse;

        _getApproval(fundDepositAsset, fund, fundDepositAmount);

        sharesBefore = FundWithShareLockFlashLoansWhitelisting(fund).balanceOf(msg.sender);

        return (fundDepositAsset, fundDepositAmount, sharesBefore);
    }

    function _afterEnter(
        address fund,
        address fundDepositAsset,
        address assetToUse,
        uint256 minSharesOut,
        uint256 sharesBefore
    ) internal returns (uint256 sharesOut) {
        sharesOut = FundWithShareLockFlashLoansWhitelisting(fund).balanceOf(msg.sender) - sharesBefore;

        if (sharesOut < minSharesOut) revert ProxyEnterFundViaAggregator__MinBoughtSharesNotMet();

        // Tranfer any unused fund asset back to the user
        _transferAll(fundDepositAsset, _getBalance(fundDepositAsset));

        // transfer any remainings from the initial token back to the user
        _transferAll(assetToUse, _getBalance(assetToUse));
    }

    function _tradeAssetsExternally(
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        Quote calldata quote
    ) internal returns (uint256 boughtAmount) {
        if (quote.targetAggregator == PARASWAP) {
            boughtAmount = _tradeWithAggregator(PARASWAP, sellToken, buyToken, sellAmount, quote);
        } else if (quote.targetAggregator == ONE_INCH) {
            boughtAmount = _tradeWithAggregator(ONE_INCH, sellToken, buyToken, sellAmount, quote);
        } else if (quote.targetAggregator == ODOS) {
            boughtAmount = _tradeWithAggregator(ODOS, sellToken, buyToken, sellAmount, quote);
        } else if (quote.targetAggregator == ZERO_EX) {
            boughtAmount = _tradeWithAggregator(ZERO_EX, sellToken, buyToken, sellAmount, quote);
        } else {
            revert ProxyEnterFundViaAggregator__InvalidAggregator();
        }
    }

    function _tradeWithAggregator(
        address aggregator,
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        Quote memory quote
    ) private returns (uint256 boughtAmount) {
        sellToken = _isNative(sellToken) ? address(WETH) : sellToken;

        if (buyToken == sellToken) revert ProxyEnterFundViaAggregator__SAME_TOKENS();

        _getApproval(sellToken, quote.spender, sellAmount);

        _performExternalCall(aggregator, quote.quoteCallData);

        boughtAmount = _getBalance(buyToken);

        if (boughtAmount < quote.buyAmount) revert ProxyEnterFundViaAggregator__MinBoughtTokensNotMet();
    }

    function _performExternalCall(address target, bytes memory data) private returns (bytes memory) {
        bytes32 selector;

        assembly {
            selector := mload(add(data, 0x20))
        }

        if (bytes4(selector) == IERC20.transferFrom.selector) revert ProxyEnterFundViaAggregator__InvalidCallSelector();

        (bool success, bytes memory returnData) = target.call(data);

        if (!success) {
            assembly {
                revert(add(data, 32), mload(returnData))
            }
        }

        return returnData;
    }

    function _transferFromAll(address token, uint256 amount) internal {
        if (_isNative(token)) {
            if (msg.value != amount) revert ProxyEnterFundViaAggregator__InvalidETHTransferAmount();
            // The 'amount' input is not used in the payable case in order to convert all the
            // native token to wrapped native token. This is useful in function _transferAll where only
            // one transfer is needed when a fraction of the wrapped tokens are used.
            WETH.deposit{ value: amount }();
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    function _getApproval(address token, address target, uint256 amount) internal {
        if (IERC20(token).allowance(address(this), target) < amount) {
            IERC20(token).safeApprove(target, type(uint256).max);
        }
    }

    function _getBalance(address token) internal view returns (uint256) {
        if (_isNative(token)) {
            return IERC20(address(WETH)).balanceOf(address(this));
        } else {
            return IERC20(token).balanceOf(address(this));
        }
    }

    function _transferAll(address token, uint256 amount) internal {
        if (amount != 0) {
            if (_isNative(token)) {
                IWETH9(WETH).withdraw(amount);
                payable(msg.sender).sendValue(amount);
            } else {
                IERC20(token).safeTransfer(msg.sender, amount);
            }
        }
    }

    receive() external payable {
        if (msg.sender != address(WETH)) revert ProxyEnterFundViaAggregator__ETHTransfer();
    }

    function _revokeApproval(address spender, IERC20 token) internal {
        if (token.allowance(address(this), spender) != 0) token.safeApprove(spender, 0);
    }

    function _isNative(address token) internal pure returns (bool) {
        return (token == NATIVE_ADDRESS);
    }

    // Pause functions
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
