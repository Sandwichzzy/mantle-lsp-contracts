// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ILiquidityBuffer - 流动性缓冲池接口
 * @notice 定义流动性缓冲池合约的接口，用于管理流动性分配到头寸管理器
 * @dev 此接口定义了流动性缓冲池的核心功能和数据结构
 */
interface ILiquidityBuffer {
    // ========================================= 数据结构 =========================================

    /// @notice 头寸管理器配置结构体
    /// @dev 存储每个头寸管理器的基本配置信息
    struct PositionManagerConfig {
        address managerAddress;     // 头寸管理器合约地址
        uint256 allocationCap;      // 该管理器的最大分配上限
        bool isActive;              // 该头寸管理器是否处于激活状态
    }

    /// @notice 头寸会计信息结构体
    /// @dev 记录每个头寸管理器的资金分配和收益情况
    struct PositionAccountant {
        uint256 allocatedBalance;           // 已分配给该管理器的总余额
        uint256 interestClaimedFromManager; // 从该管理器收集的累计利息
    }

    // ========================================= 事件 =========================================

    /// @notice 当从头寸管理器撤回 ETH 时触发
    /// @param managerId 头寸管理器 ID
    /// @param amount 撤回金额
    event ETHWithdrawnFromManager(uint256 indexed managerId, uint256 amount);

    /// @notice 当 ETH 返还给 Staking 合约时触发
    /// @param amount 返还金额
    event ETHReturnedToStaking(uint256 amount);

    /// @notice 当 ETH 分配到头寸管理器时触发
    /// @param managerId 头寸管理器 ID
    /// @param amount 分配金额
    event ETHAllocatedToManager(uint256 indexed managerId, uint256 amount);

    /// @notice 当从 Staking 合约接收 ETH 时触发
    /// @param amount 接收金额
    event ETHReceivedFromStaking(uint256 amount);

    /// @notice 当收取协议费用时触发
    /// @param amount 费用金额
    event FeesCollected(uint256 amount);

    /// @notice 当从头寸管理器收集利息时触发
    /// @param managerId 头寸管理器 ID
    /// @param interestAmount 利息金额
    event InterestClaimed(uint256 indexed managerId, uint256 interestAmount);

    /// @notice 当利息充值到 Staking 合约时触发
    /// @param amount 充值金额
    event InterestToppedUp(uint256 amount);

    // ========================================= 外部函数 =========================================

    /// @notice 从 Staking 合约接收 ETH 存款
    /// @dev 只能由 Staking 合约调用
    function depositETH() external payable;

    /// @notice 接收来自头寸管理器的 ETH
    /// @dev 只能由已注册的头寸管理器调用
    function receiveETHFromPositionManager() external payable;

    /// @notice 获取可用的本金余额用于分配
    /// @dev 计算公式：totalFundsReceived - totalFundsReturned
    /// @return 可用余额
    function getAvailableBalance() external view returns (uint256);

    /// @notice 获取累计提款额度
    /// @return 累计提款金额
    function cumulativeDrawdown() external view returns (uint256);
}
