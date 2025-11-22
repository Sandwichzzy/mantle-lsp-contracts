// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPositionManager - 头寸管理器接口
 * @notice 定义 Aave V3 头寸管理器的接口
 * @dev 此接口规定了管理 DeFi 协议头寸的操作方法
 */
interface IPositionManager {
    // ========================================= 事件 =========================================

    /// @notice 当存款成功时触发
    /// @param caller 调用者地址
    /// @param amount 存款金额
    /// @param aTokenAmount 获得的 aToken 数量
    event Deposit(address indexed caller, uint256 amount, uint256 aTokenAmount);

    /// @notice 当取款成功时触发
    /// @param caller 调用者地址
    /// @param amount 取款金额
    event Withdraw(address indexed caller, uint256 amount);

    /// @notice 当设置新的流动性缓冲池地址时触发
    /// @param liquidityBuffer 新的流动性缓冲池地址
    event SetLiquidityBuffer(address indexed liquidityBuffer);

    /// @notice 当批准代币授权时触发
    /// @param token 代币地址
    /// @param addr 被授权的地址
    /// @param wad 授权数量
    event ApproveToken(address indexed token, address indexed addr, uint256 wad);

    /// @notice 当撤销代币授权时触发
    /// @param token 代币地址
    /// @param addr 被撤销授权的地址
    event RevokeToken(address indexed token, address indexed addr);

    /// @notice 当执行紧急代币转移时触发
    /// @param token 代币地址
    /// @param to 接收地址
    /// @param amount 转移数量
    event EmergencyTokenTransfer(address indexed token, address indexed to, uint256 amount);

    /// @notice 当执行紧急 ETH 转移时触发
    /// @param to 接收地址
    /// @param amount 转移数量
    event EmergencyEtherTransfer(address indexed to, uint256 amount);

    // ========================================= 外部函数 =========================================

    /// @notice 存入 ETH 到协议
    /// @param referralCode 推荐码（Aave 协议使用）
    function deposit(uint16 referralCode) external payable;

    /// @notice 从协议撤回资金
    /// @param amount 撤回金额
    function withdraw(uint256 amount) external;

    /// @notice 获取底层资产余额
    /// @return 底层资产余额
    function getUnderlyingBalance() external view returns (uint256);

    /// @notice 批准代币授权
    /// @param token 代币地址
    /// @param addr 被授权的地址
    /// @param wad 授权数量
    function approveToken(address token, address addr, uint256 wad) external;

    /// @notice 撤销代币授权
    /// @param token 代币地址
    /// @param addr 被撤销授权的地址
    function revokeToken(address token, address addr) external;
}
