// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IBlockList {
    /// @notice 检查某个地址是否被封禁
    function isBlocked(address account) external view returns (bool);
}
