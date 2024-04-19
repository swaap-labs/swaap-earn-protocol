// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV2V3Interface.sol";

interface IChainlinkAggregatorProxy is AggregatorV2V3Interface {
    function aggregator() external view returns (address);
}
