// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.0;

interface ISafeguardPool {    
    /// @notice Returns if the pool whitelist is enabled
    function isAllowlistEnabled() external view returns (bool);

    /// @dev returns the yearly fees, yearly rate and the latest fee claim time
    function getManagementFeesParams() external view returns(uint256, uint256, uint256);
}
