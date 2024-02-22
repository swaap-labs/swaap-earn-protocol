// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IAaveToken is IERC20 {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}
