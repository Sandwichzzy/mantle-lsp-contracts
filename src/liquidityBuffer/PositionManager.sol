// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPool} from "aave-v3-origin/src/contracts//interfaces/IPool.sol";
import {DataTypes} from "aave-v3-origin/src/contracts/protocol/libraries/types/DataTypes.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {ILiquidityBuffer} from "../liquidityBuffer/interfaces/ILiquidityBuffer.sol";

/**
 * @title PositionManager - Aave V3 头寸管理器
 * @notice 基于角色的访问控制的头寸管理器，用于管理 Aave V3 协议中的资金
 * @dev 此合约受 WrappedTokenGatewayV3 启发（地址：0xd01607c3c5ecaba394d8be377a08590149325722）
 *      主要功能：
 *      1. 将 ETH 包装成 WETH 并存入 Aave V3 协议赚取收益
 *      2. 从 Aave 撤回 WETH 并转换回 ETH 返还给流动性缓冲池
 *      3. 查询 Aave 中的资金余额（aWETH）
 *      4. 提供紧急情况下的资金救援机制
 */
contract PositionManager is Initializable, AccessControlEnumerableUpgradeable, IPositionManager {
    using SafeERC20 for IERC20;

    // ========================================= 角色定义 =========================================

    /// @notice 执行者角色 - 可以执行存款和取款操作
    /// @dev 通常授予 LiquidityBuffer 合约
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    /// @notice 管理员角色 - 可以批准/撤销代币授权和设置 LiquidityBuffer
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @notice 紧急角色 - 可以执行紧急资金救援操作
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // ========================================= 状态变量 =========================================

    /// @notice Aave V3 协议的 Pool 合约地址
    IPool public pool;

    /// @notice WETH 代币合约地址
    IWETH public weth;

    /// @notice 流动性缓冲池合约地址
    ILiquidityBuffer public liquidityBuffer;

    /// @notice 初始化配置结构体
    /// @dev 包含合约初始化所需的所有地址和角色
    struct Init {
        address admin;                      // 管理员地址
        address manager;                    // 管理角色地址
        ILiquidityBuffer liquidityBuffer;   // 流动性缓冲池地址
        IWETH weth;                         // WETH 合约地址
        IPool pool;                         // Aave Pool 合约地址
    }

    /// @dev 禁用实现合约的初始化，只能通过代理合约初始化
    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化合约
    /// @dev 只能调用一次，设置所有必需的角色和合约地址，并授权 Pool 使用 WETH
    /// @param init 包含所有初始化参数的结构体
    function initialize(Init memory init) external initializer {
        if (
            init.admin == address(0) || init.manager == address(0) || address(init.liquidityBuffer) == address(0)
                || address(init.weth) == address(0) || address(init.pool) == address(0)
        ) {
            revert("Invalid initialize parameters");
        }
        __AccessControlEnumerable_init();

        weth = init.weth;
        pool = init.pool;
        liquidityBuffer = init.liquidityBuffer;

        // 设置角色权限
        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(MANAGER_ROLE, init.manager);
        _grantRole(EXECUTOR_ROLE, address(init.liquidityBuffer));

        // 授权 Pool 合约可以使用无限量的 WETH
        weth.approve(address(pool), type(uint256).max);
    }

    // ========================================= IPositionManager 接口实现 =========================================

    /// @notice 存入 ETH 到 Aave 协议
    /// @dev 只能由拥有 EXECUTOR_ROLE 的地址调用（通常是 LiquidityBuffer）
    ///      流程：ETH -> WETH -> Aave Pool -> aWETH
    /// @param referralCode Aave 推荐码，通常为 0
    function deposit(uint16 referralCode) external payable override onlyRole(EXECUTOR_ROLE) {
        if (msg.value == 0) {
            revert("Deposit amount cannot be 0");
        }
        // 将 ETH 包装成 WETH
        weth.deposit{value: msg.value}();

        // 将 WETH 存入 Aave Pool
        pool.deposit(address(weth), msg.value, address(this), referralCode);

        emit Deposit(msg.sender, msg.value, msg.value);
    }

    /// @notice 从 Aave 协议撤回资金
    /// @dev 只能由拥有 EXECUTOR_ROLE 的地址调用（通常是 LiquidityBuffer）
    ///      流程：aWETH -> WETH -> ETH -> LiquidityBuffer
    /// @param amount 撤回金额，使用 type(uint256).max 表示撤回全部余额
    function withdraw(uint256 amount) external override onlyRole(EXECUTOR_ROLE) {
        require(amount > 0, "Invalid amount");

        // 获取 aWETH 代币合约
        IERC20 aWETH = IERC20(pool.getReserveAToken(address(weth)));
        uint256 userBalance = aWETH.balanceOf(address(this));

        uint256 amountToWithdraw = amount;
        if (amount == type(uint256).max) {
            amountToWithdraw = userBalance;
        }

        require(amountToWithdraw <= userBalance, "Insufficient balance");

        // 从 Aave Pool 撤回 WETH
        pool.withdraw(address(weth), amountToWithdraw, address(this));

        // 将 WETH 解包成 ETH
        weth.withdraw(amountToWithdraw);

        // 通过 receiveETHFromPositionManager 将 ETH 转账给 LiquidityBuffer
        liquidityBuffer.receiveETHFromPositionManager{value: amountToWithdraw}();

        emit Withdraw(msg.sender, amountToWithdraw);
    }

    /// @notice 获取在 Aave 中的底层资产余额
    /// @dev 返回持有的 aWETH 数量，等同于底层 WETH 数量（含收益）
    /// @return Aave 中的 WETH 余额
    function getUnderlyingBalance() external view returns (uint256) {
        IERC20 aWETH = IERC20(pool.getReserveAToken(address(weth)));
        return aWETH.balanceOf(address(this));
    }

    /// @notice 批准某个地址使用指定代币
    /// @dev 只能由拥有 MANAGER_ROLE 的地址调用
    /// @param token 代币合约地址
    /// @param addr 被授权的地址
    /// @param wad 授权数量
    function approveToken(address token, address addr, uint256 wad)
        external
        override
        onlyRole(MANAGER_ROLE)
        notZeroAddress(addr)
    {
        IERC20(token).approve(addr, wad);
        emit ApproveToken(token, addr, wad);
    }

    /// @notice 撤销某个地址对指定代币的授权
    /// @dev 只能由拥有 MANAGER_ROLE 的地址调用
    /// @param token 代币合约地址
    /// @param addr 被撤销授权的地址
    function revokeToken(address token, address addr) external override onlyRole(MANAGER_ROLE) notZeroAddress(addr) {
        IERC20(token).approve(addr, 0);
        emit RevokeToken(token, addr);
    }

    /// @notice 设置新的流动性缓冲池地址
    /// @dev 会将 EXECUTOR_ROLE 从旧地址转移到新地址
    /// @param _liquidityBuffer 新的流动性缓冲池地址
    function setLiquidityBuffer(address _liquidityBuffer)
        external
        onlyRole(MANAGER_ROLE)
        notZeroAddress(_liquidityBuffer)
    {
        _revokeRole(EXECUTOR_ROLE, address(liquidityBuffer));
        _grantRole(EXECUTOR_ROLE, _liquidityBuffer);
        liquidityBuffer = ILiquidityBuffer(_liquidityBuffer);
        emit SetLiquidityBuffer(_liquidityBuffer);
    }

    // ========================================= 紧急救援函数 =========================================

    /// @notice 紧急转移 ERC20 代币
    /// @dev 用于救援因直接转账而卡在合约中的 ERC20 代币
    ///      只能由拥有 EMERGENCY_ROLE 的地址调用
    /// @param token 代币地址
    /// @param to 接收地址
    /// @param amount 转账数量
    function emergencyTokenTransfer(address token, address to, uint256 amount)
        external
        onlyRole(EMERGENCY_ROLE)
        notZeroAddress(to)
    {
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyTokenTransfer(token, to, amount);
    }

    /// @notice 紧急转移原生 ETH
    /// @dev 用于救援因 selfdestruct 或预计算地址转账而卡在合约中的 ETH
    ///      只能由拥有 EMERGENCY_ROLE 的地址调用
    /// @param to 接收地址
    /// @param amount 转账数量
    function emergencyEtherTransfer(address to, uint256 amount) external onlyRole(EMERGENCY_ROLE) notZeroAddress(to) {
        _safeTransferETH(to, amount);
        emit EmergencyEtherTransfer(to, amount);
    }

    // ========================================= 内部函数 =========================================

    /// @notice 安全地转移 ETH
    /// @dev 如果转账失败则回退交易
    /// @param to 接收地址
    /// @param value 转账金额
    function _safeTransferETH(address to, uint256 value) internal {
        (bool success,) = to.call{value: value}(new bytes(0));
        require(success, "ETH_TRANSFER_FAILED");
    }

    // ========================================= 接收 ETH =========================================

    /// @notice 接收 ETH
    /// @dev 只允许 WETH 合约发送 ETH，防止其他地址直接转账
    receive() external payable {
        require(msg.sender == address(weth), "Receive not allowed");
    }

    /// @notice 拒绝所有未知函数调用
    fallback() external payable {
        revert("Fallback not allowed");
    }

    // ========================================= 修饰器 =========================================

    /// @notice 确保给定地址不是零地址
    /// @param addr 要检查的地址
    modifier notZeroAddress(address addr) {
        if (addr == address(0)) {
            revert("Not a zero address");
        }
        _;
    }
}
