// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ERC20, SafeTransferLib, Cellar, PriceRouter, Registry, Math } from "src/modules/adaptors/BaseAdaptor.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { PositionlessAdaptor } from "src/modules/adaptors/PositionlessAdaptor.sol";
import { BaseAdaptor } from "src/modules/adaptors/BaseAdaptor.sol";

/**
 * @title 1inch Adaptor
 * @notice Allows Cellars to swap with 1Inch.
 */
contract OneInchAdaptor is PositionlessAdaptor {
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using Address for address;

    //==================== Adaptor Data Specification ====================
    // NOT USED
    //================= Configuration Data Specification =================
    // NOT USED
    // **************************** IMPORTANT ****************************
    // This adaptor has NO underlying position, its only purpose is to
    // expose the swap function to strategists during rebalances.
    //====================================================================

    /**
     * @notice The 1inch swap target contract on current network.
     * @notice For mainnet use 0x1111111254EEB25477B68fb85Ed929f73A960582.
     */
    address public immutable target;

    /**
     * @notice The erc20 adaptor contract used by the cellars on the current network.
     */
    bytes32 public immutable erc20AdaptorIdentifier;

    constructor(address _target, address _erc20Adaptor) {
        target = _target;
        erc20AdaptorIdentifier = BaseAdaptor(_erc20Adaptor).identifier();
    }

    //============================================ Global Functions ===========================================
    /**
     * @dev Identifier unique to this adaptor for a shared registry.
     * Normally the identifier would just be the address of this contract, but this
     * Identifier is needed during Cellar Delegate Call Operations, so getting the address
     * of the adaptor is more difficult.
     */
    function identifier() public pure virtual override returns (bytes32) {
        return keccak256(abi.encode("1Inch Adaptor V 1.1"));
    }

    //============================================ Strategist Functions ===========================================

    /**
     * @notice Allows strategists to make ERC20 swaps using 1Inch.
     */
    function swapWithOneInch(ERC20 tokenIn, ERC20 tokenOut, uint256 amount, bytes memory swapCallData) public {
        _validateTokenOutIsUsed(address(tokenOut));
        
        PriceRouter priceRouter = Cellar(address(this)).priceRouter();

        tokenIn.safeApprove(target, amount);

        // Save token balances.
        uint256 tokenInBalance = tokenIn.balanceOf(address(this));
        uint256 tokenOutBalance = tokenOut.balanceOf(address(this));

        // Perform Swap.
        target.functionCall(swapCallData);

        uint256 tokenInAmountIn = tokenInBalance - tokenIn.balanceOf(address(this));
        uint256 tokenOutAmountOut = tokenOut.balanceOf(address(this)) - tokenOutBalance;

        uint256 tokenInValueOut = priceRouter.getValue(tokenOut, tokenOutAmountOut, tokenIn);

        if (tokenInValueOut < tokenInAmountIn.mulDivDown(slippage(), 1e4)) revert BaseAdaptor__Slippage();

        // Ensure spender has zero approval.
        _revokeExternalApproval(tokenIn, target);
    }

    function _validateTokenOutIsUsed(address tokenOut) internal view {
        bytes memory adaptorData = abi.encode(tokenOut);
        // This adaptor has no underlying position, so no need to validate token out.
        bytes32 positionHash = keccak256(abi.encode(erc20AdaptorIdentifier, false, adaptorData));
        uint32 positionId = Cellar(address(this)).registry().getPositionHashToPositionId(positionHash);
        if (!Cellar(address(this)).isPositionUsed(positionId))
            revert BaseAdaptor__PositionNotUsed(adaptorData);
    }
}
