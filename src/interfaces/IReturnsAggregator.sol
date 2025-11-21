// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OracleRecord} from "./IOracle.sol";

interface IReturnsAggregatorWrite {
    /// @notice 从预言机获取记录，相应地聚合净收益并将其转发到质押合约。
    function processReturns(uint256 rewardAmount, uint256 principalAmount, bool shouldIncludeELRewards) external;
}
