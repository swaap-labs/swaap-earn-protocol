// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Fund, Registry, ERC20, Math, SafeTransferLib } from "src/base/Fund.sol";
import { IFlashLoanRecipient, IERC20 } from "@balancer/interfaces/contracts/vault/IFlashLoanRecipient.sol";
import { FundWithShareLockPeriod } from "src/base/permutations/FundWithShareLockPeriod.sol";
import { EIP712, ECDSA } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title Fund with a Share Lock Period, Flash Loans, and Whitelisting.
 */
contract FundWithShareLockFlashLoansWhitelisting is FundWithShareLockPeriod, EIP712 {
    using SafeTransferLib for ERC20;

    uint256 internal constant WHITELIST_VALIDITY_PERIOD = 5 minutes;
    bytes32 public constant WHITELIST_TYPEHASH =
        keccak256("Whitelist(address sender,address receiver,uint256 signedAt)");

    /**
     * @notice The Balancer Vault contract on current network.
     * @dev For mainnet use 0xBA12222222228d8Ba445958a75a0704d566BF2C8.
     */
    address public immutable balancerVault;
    bool public isWhitelistEnabled;

    /// @notice Emitted when the whitelisting requirement to enter is enabled or disabled.
    event WhitelistingChanged(bool isWhitelistEnabled);

    constructor(
        address _owner,
        Registry _registry,
        ERC20 _asset,
        string memory _name,
        string memory _symbol,
        uint32 _holdingPosition,
        bytes memory _holdingPositionConfig,
        uint256 _initialDeposit,
        uint192 _shareSupplyCap,
        address _balancerVault
    )
        FundWithShareLockPeriod(
            _owner,
            _registry,
            _asset,
            _name,
            _symbol,
            _holdingPosition,
            _holdingPositionConfig,
            _initialDeposit,
            _shareSupplyCap
        )
        EIP712("FundWithShareLockFlashLoansWhitelisting", "1.0")
    {
        balancerVault = _balancerVault;
    }

    // ========================================= Balancer Flash Loan Support =========================================
    /**
     * @notice External contract attempted to initiate a flash loan.
     */
    error Fund__ExternalInitiator();

    /**
     * @notice receiveFlashLoan was not called by Balancer Vault.
     */
    error Fund__CallerNotBalancerVault();

    /**
     * @notice Allows rebalancers to utilize balancer flashloans while rebalancing the fund.
     * @dev Balancer does not provide an initiator, so instead insure we are in the `callOnAdaptor` context
     *      by reverting if `blockExternalReceiver` is false.
     */
    function receiveFlashLoan(
        IERC20[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata userData
    ) external {
        if (msg.sender != balancerVault) revert Fund__CallerNotBalancerVault();
        if (!blockExternalReceiver) revert Fund__ExternalInitiator();

        AdaptorCall[] memory data = abi.decode(userData, (AdaptorCall[]));

        // Run all adaptor calls.
        _makeAdaptorCalls(data);

        // Approve pool to repay all debt.
        for (uint256 i; i < amounts.length; ++i) {
            ERC20(address(tokens[i])).safeTransfer(balancerVault, (amounts[i] + feeAmounts[i]));
        }
    }

    // ========================================= Whitelisting Support =========================================

    /**
     * @notice Emitted when the whitelist is enabled and a signature is required to join.
     * @dev The user must use "whitelistDeposit" or "whitelistMint" to deposit or mint shares when
     *      whitelist is enabled.
     */
    error Fund__WhitelistEnabled();

    /**
     * @notice Emitted when the signature deadline is invalid.
     */
    error Fund__InvalidSignatureDeadline();

    /**
     * @notice Emitted when the signature is invalid.
     */
    error Fund__InvalidSignature();

    /**
     * @notice Deposits assets into the fund, and returns shares to receiver.
     * @dev The nonReentrant modifier is defined in the parent contract.
     * @param assets amount of assets deposited by user.
     * @param receiver address to receive the shares.
     * @return shares amount of shares given for deposit.
     */
    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        if (isWhitelistEnabled) revert Fund__WhitelistEnabled();
        return super.deposit(assets, receiver);
    }

    /**
     * @notice Mints shares from the fund, and returns shares to receiver.
     * @dev The nonReentrant modifier is defined in the parent contract.
     * @param shares amount of shares requested by user.
     * @param receiver address to receive the shares.
     * @return assets amount of assets deposited into the fund.
     */
    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        if (isWhitelistEnabled) revert Fund__WhitelistEnabled();
        return super.mint(shares, receiver);
    }

    /**
     * @notice Deposits assets into the fund, and returns shares to receiver.
     * @param assets amount of assets deposited by user.
     * @param receiver address to receive the shares.
     * @param signedAt timestamp of when the signature was created.
     * @param signature signature of the whitelist permission.
     * @return shares amount of shares given for deposit.
     */
    function whitelistDeposit(
        uint256 assets,
        address receiver,
        uint256 signedAt,
        bytes memory signature
    ) external returns (uint256 shares) {
        _verifyWhitelistSignature(receiver, signedAt, signature);
        return super.deposit(assets, receiver);
    }

    /**
     * @notice Mints shares from the fund, and returns shares to receiver.
     * @param shares amount of shares requested by user.
     * @param receiver address to receive the shares.
     * @param signedAt timestamp of when the signature was created.
     * @param signature signature of the whitelist permission.
     * @return assets amount of assets deposited into the fund.
     */
    function whitelistMint(
        uint256 shares,
        address receiver,
        uint256 signedAt,
        bytes memory signature
    ) external returns (uint256 assets) {
        _verifyWhitelistSignature(receiver, signedAt, signature);
        return super.mint(shares, receiver);
    }

    function _verifyWhitelistSignature(address receiver, uint256 signedAt, bytes memory signature) internal view {
        if (isWhitelistEnabled) {
            // verify deadline is still valid
            if (block.timestamp > signedAt + WHITELIST_VALIDITY_PERIOD) revert Fund__InvalidSignatureDeadline();
            if (block.timestamp < signedAt) revert Fund__InvalidSignatureDeadline();

            bytes32 digest = _hashTypedDataV4(
                keccak256(abi.encode(WHITELIST_TYPEHASH, msg.sender, receiver, signedAt))
            );

            address signer = ECDSA.recover(digest, signature);

            if (signer != automationActions && signer != owner()) revert Fund__InvalidSignature();
        }
    }

    /**
     * @notice Enables the whitelist.
     */
    function enableWhitelist() external onlyOwner {
        isWhitelistEnabled = true;
        emit WhitelistingChanged(true);
    }

    /**
     * @notice Disables the whitelist.
     */
    function disableWhitelist() external onlyOwner {
        isWhitelistEnabled = false;
        emit WhitelistingChanged(false);
    }
}
