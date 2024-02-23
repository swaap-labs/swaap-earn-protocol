// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BaseAdaptor, ERC20, SafeTransferLib, Fund } from "src/modules/adaptors/BaseAdaptor.sol";

/**
 * @title Swaap Fund Adaptor
 * @notice Allows Funds to interact with other Fund positions.
 * @author crispymangoes
 */
contract SwaapFundAdaptor is BaseAdaptor {
    using SafeTransferLib for ERC20;

    //==================== Adaptor Data Specification ====================
    // adaptorData = abi.encode(Fund fund)
    // Where:
    // `fund` is the underling Fund this adaptor is working with
    //================= Configuration Data Specification =================
    // configurationData = abi.encode(bool isLiquid)
    // Where:
    // `isLiquid` dictates whether the position is liquid or not
    // If true:
    //      position can support use withdraws
    // else:
    //      position can not support user withdraws
    //
    //====================================================================

    /**
     * @notice Strategist attempted to interact with a Fund with no position setup for it.
     */
    error SwaapFundAdaptor__FundPositionNotUsed(address fund);

    //============================================ Global Functions ===========================================
    /**
     * @dev Identifier unique to this adaptor for a shared registry.
     * Normally the identifier would just be the address of this contract, but this
     * Identifier is needed during Fund Delegate Call Operations, so getting the address
     * of the adaptor is more difficult.
     */
    function identifier() public pure override returns (bytes32) {
        return keccak256(abi.encode("Swaap Fund Adaptor V 1.1"));
    }

    //============================================ Implement Base Functions ===========================================
    /**
     * @notice Fund must approve Fund position to spend its assets, then deposit into the Fund position.
     * @param assets the amount of assets to deposit into the Fund position
     * @param adaptorData adaptor data containining the abi encoded Fund
     * @dev configurationData is NOT used
     */
    function deposit(uint256 assets, bytes memory adaptorData, bytes memory) public override {
        // Deposit assets to `fund`.
        Fund fund = abi.decode(adaptorData, (Fund));
        _verifyFundPositionIsUsed(address(fund));
        ERC20 asset = fund.asset();
        asset.safeApprove(address(fund), assets);
        fund.deposit(assets, address(this));

        // Zero out approvals if necessary.
        _revokeExternalApproval(asset, address(fund));
    }

    /**
     * @notice Fund needs to call withdraw on Fund position.
     * @dev Important to verify that external receivers are allowed if receiver is not Fund address.
     * @param assets the amount of assets to withdraw from the Fund position
     * @param receiver address to send assets to'
     * @param adaptorData data needed to withdraw from the Fund position
     * @param configurationData abi encoded bool indicating whether the position is liquid or not
     */
    function withdraw(
        uint256 assets,
        address receiver,
        bytes memory adaptorData,
        bytes memory configurationData
    ) public override {
        // Check that position is setup to be liquid.
        bool isLiquid = abi.decode(configurationData, (bool));
        if (!isLiquid) revert BaseAdaptor__UserWithdrawsNotAllowed();

        // Run external receiver check.
        _externalReceiverCheck(receiver);

        // Withdraw assets from `fund`.
        Fund fund = abi.decode(adaptorData, (Fund));
        _verifyFundPositionIsUsed(address(fund));
        fund.withdraw(assets, receiver, address(this));
    }

    /**
     * @notice Fund needs to call `maxWithdraw` to see if its assets are locked.
     */
    function withdrawableFrom(
        bytes memory adaptorData,
        bytes memory configurationData
    ) public view override returns (uint256) {
        bool isLiquid = abi.decode(configurationData, (bool));
        if (isLiquid) {
            Fund fund = abi.decode(adaptorData, (Fund));
            return fund.maxWithdraw(msg.sender);
        } else return 0;
    }

    /**
     * @notice Uses ERC4626 `previewRedeem` to determine Funds balance in Fund position.
     */
    function balanceOf(bytes memory adaptorData) public view override returns (uint256) {
        Fund fund = abi.decode(adaptorData, (Fund));
        return fund.previewRedeem(fund.balanceOf(msg.sender));
    }

    /**
     * @notice Returns the asset the Fund position uses.
     */
    function assetOf(bytes memory adaptorData) public view override returns (ERC20) {
        Fund fund = abi.decode(adaptorData, (Fund));
        return fund.asset();
    }

    /**
     * @notice This adaptor returns collateral, and not debt.
     */
    function isDebt() public pure override returns (bool) {
        return false;
    }

    //============================================ Strategist Functions ===========================================
    /**
     * @notice Allows strategists to deposit into Fund positions.
     * @dev Uses `_maxAvailable` helper function, see BaseAdaptor.sol
     * @param fund the Fund to deposit `assets` into
     * @param assets the amount of assets to deposit into `fund`
     */
    function depositToFund(Fund fund, uint256 assets) public {
        _verifyFundPositionIsUsed(address(fund));
        ERC20 asset = fund.asset();
        assets = _maxAvailable(asset, assets);
        asset.safeApprove(address(fund), assets);
        fund.deposit(assets, address(this));

        // Zero out approvals if necessary.
        _revokeExternalApproval(asset, address(fund));
    }

    /**
     * @notice Allows strategists to withdraw from Fund positions.
     * @param fund the Fund to withdraw `assets` from
     * @param assets the amount of assets to withdraw from `fund`
     */
    function withdrawFromFund(Fund fund, uint256 assets) public {
        _verifyFundPositionIsUsed(address(fund));
        if (assets == type(uint256).max) assets = fund.maxWithdraw(address(this));
        fund.withdraw(assets, address(this), address(this));
    }

    //============================================ Helper Functions ===========================================

    /**
     * @notice Reverts if a given `fund` is not set up as a position in the calling Fund.
     * @dev This function is only used in a delegate call context, hence why address(this) is used
     *      to get the calling Fund.
     */
    function _verifyFundPositionIsUsed(address fund) internal view {
        // Check that fund position is setup to be used in the fund.
        bytes32 positionHash = keccak256(abi.encode(identifier(), false, abi.encode(fund)));
        uint32 positionId = Fund(address(this)).registry().getPositionHashToPositionId(positionHash);
        if (!Fund(address(this)).isPositionUsed(positionId)) revert SwaapFundAdaptor__FundPositionNotUsed(fund);
    }
}
