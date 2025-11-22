// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ILiquidityBuffer} from "./interfaces/ILiquidityBuffer.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {IStakingReturnsWrite} from "../interfaces/IStaking.sol";
import {IPauserRead} from "../interfaces/IPauser.sol";
import {IProtocolEvents} from "../interfaces/IProtocolEvents.sol";

/**
 * @title LiquidityBuffer - 流动性缓冲池
 * @notice 管理流动性分配到各种 DeFi 协议的头寸管理器
 * @dev 此合约作为资金中转枢纽，负责：
 *      1. 接收来自 Staking 合约的 ETH 存款
 *      2. 将资金分配到不同的头寸管理器（如 Aave、Compound 等）
 *      3. 收集各个头寸管理器产生的利息收益
 *      4. 将收益返还给 Staking 合约，并收取协议费用
 *      5. 管理头寸管理器的配置、额度和激活状态
 */
contract LiquidityBuffer is Initializable, AccessControlEnumerableUpgradeable, ILiquidityBuffer, IProtocolEvents {
    using Address for address;

    // ========================================= 常量定义 =========================================

    /// @notice 流动性管理员角色 - 可以执行资金分配和撤回操作
    bytes32 public constant LIQUIDITY_MANAGER_ROLE = keccak256("LIQUIDITY_MANAGER_ROLE");

    /// @notice 头寸管理员角色 - 可以添加/更新头寸管理器配置
    bytes32 public constant POSITION_MANAGER_ROLE = keccak256("POSITION_MANAGER_ROLE");

    /// @notice 利息充值角色 - 可以收集利息并返还给 Staking 合约
    bytes32 public constant INTEREST_TOPUP_ROLE = keccak256("INTEREST_TOPUP_ROLE");

    /// @notice 提款管理员角色 - 可以设置累计提款额度
    bytes32 public constant DRAWDOWN_MANAGER_ROLE = keccak256("DRAWDOWN_MANAGER_ROLE");

    /// @notice 基点分母，用于费率计算（10000 = 100%）
    uint16 internal constant _BASIS_POINTS_DENOMINATOR = 10_000;

    // ========================================= 状态变量 =========================================

    /// @notice Staking 合约地址 - 流动性缓冲池从该合约接收资金并返还资金
    IStakingReturnsWrite public stakingContract;

    /// @notice 暂停器合约 - 维护整个协议的暂停状态
    /// @dev 当协议暂停时，大部分操作将被禁止
    IPauserRead public pauser;

    /// @notice 头寸管理器总数
    uint256 public positionManagerCount;

    /// @notice 头寸管理器配置映射：管理器 ID => 配置信息
    /// @dev 包含管理器地址、分配上限和激活状态
    mapping(uint256 => PositionManagerConfig) public positionManagerConfigs;

    /// @notice 头寸会计信息映射：管理器 ID => 会计数据
    /// @dev 记录已分配余额和已收集的利息
    mapping(uint256 => PositionAccountant) public positionAccountants;

    /// @notice 从 Staking 合约累计接收的总资金
    uint256 public totalFundsReceived;

    /// @notice 返还给 Staking 合约的总资金
    uint256 public totalFundsReturned;

    /// @notice 所有头寸管理器的总分配余额
    uint256 public totalAllocatedBalance;

    /// @notice 从头寸管理器累计收集的总利息
    uint256 public totalInterestClaimed;

    /// @notice 累计返还给 Staking 合约的总利息
    uint256 public totalInterestToppedUp;

    /// @notice 所有管理器的总分配容量上限
    uint256 public totalAllocationCapacity;

    /// @notice 累计提款额度
    uint256 public cumulativeDrawdown;

    /// @notice 默认管理器 ID，用于存款和分配操作
    uint256 public defaultManagerId;

    /// @notice 协议费用接收地址
    address payable public feesReceiver;

    /// @notice 协议费率（基点）- 例如 100 = 1%
    uint16 public feesBasisPoints;

    /// @notice 累计收取的协议费用总额
    uint256 public totalFeesCollected;

    /// @notice 待处理的利息余额，可用于充值操作
    /// @dev 从头寸管理器收集但尚未返还给 Staking 的利息
    uint256 public pendingInterest;

    /// @notice 待处理的本金余额，可用于分配操作
    /// @dev 从 Staking 接收但尚未分配给头寸管理器的本金
    uint256 public pendingPrincipal;

    /// @notice 是否在 depositETH 方法中自动执行分配逻辑
    /// @dev 为 true 时会自动将存入的资金分配到默认管理器
    bool public shouldExecuteAllocation;

    /// @notice 记录管理器地址是否已注册的映射
    /// @dev 防止同一个地址被重复注册为管理器
    mapping(address => bool) public isRegisteredManager;

    /// @notice 初始化配置结构体
    /// @dev 包含合约初始化所需的所有地址和角色
    struct Init {
        address admin;                      // 管理员地址
        address liquidityManager;           // 流动性管理员地址
        address positionManager;            // 头寸管理员地址
        address interestTopUp;              // 利息充值管理员地址
        address drawdownManager;            // 提款管理员地址
        address payable feesReceiver;       // 费用接收地址
        IStakingReturnsWrite staking;       // Staking 合约地址
        IPauserRead pauser;                 // 暂停器合约地址
    }

    // ========================================= 错误定义 =========================================

    /// @dev 头寸管理器未找到
    error LiquidityBuffer__ManagerNotFound();

    /// @dev 头寸管理器未激活
    error LiquidityBuffer__ManagerInactive();

    /// @dev 管理器地址已被注册
    error LiquidityBuffer__ManagerAlreadyRegistered();

    /// @dev 超出分配上限
    error LiquidityBuffer__ExceedsAllocationCap();

    /// @dev 余额不足
    error LiquidityBuffer__InsufficientBalance();

    /// @dev 分配额度不足
    error LiquidityBuffer__InsufficientAllocation();

    /// @dev 不接受 ETH 转账（仅通过特定函数接收）
    error LiquidityBuffer__DoesNotReceiveETH();

    /// @dev 合约已暂停
    error LiquidityBuffer__Paused();

    /// @dev 无效的配置参数
    error LiquidityBuffer__InvalidConfiguration();

    /// @dev 地址为零地址
    error LiquidityBuffer__ZeroAddress();

    /// @dev 调用者不是 Staking 合约
    error LiquidityBuffer__NotStakingContract();

    /// @dev 调用者不是头寸管理器合约
    error LiquidityBuffer__NotPositionManagerContract();

    /// @dev 超出待处理利息余额
    error LiquidityBuffer__ExceedsPendingInterest();

    /// @dev 超出待处理本金余额
    error LiquidityBuffer__ExceedsPendingPrincipal();
    // ========================================= 初始化 =========================================

    /// @dev 禁用实现合约的初始化，只能通过代理合约初始化
    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化合约
    /// @dev 只能调用一次，设置所有必需的角色和合约地址
    /// @param init 包含所有初始化参数的结构体
    function initialize(Init memory init) external initializer {
        if (
            init.admin == address(0) || init.liquidityManager == address(0) || init.positionManager == address(0)
                || init.interestTopUp == address(0) || init.drawdownManager == address(0)
                || init.feesReceiver == address(0) || address(init.staking) == address(0)
                || address(init.pauser) == address(0)
        ) {
            revert LiquidityBuffer__ZeroAddress();
        }

        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(LIQUIDITY_MANAGER_ROLE, init.liquidityManager);
        _grantRole(POSITION_MANAGER_ROLE, init.positionManager);
        _grantRole(INTEREST_TOPUP_ROLE, init.interestTopUp);
        _grantRole(DRAWDOWN_MANAGER_ROLE, init.drawdownManager);

        stakingContract = init.staking;
        pauser = init.pauser;
        feesReceiver = init.feesReceiver;
        shouldExecuteAllocation = true;

        _grantRole(LIQUIDITY_MANAGER_ROLE, address(stakingContract));
    }

    // ========================================= 视图函数 =========================================

    /// @notice 获取指定管理器产生的利息金额
    /// @dev 计算公式：当前余额 - 已分配余额
    /// @param managerId 头寸管理器 ID
    /// @return 可收集的利息金额
    function getInterestAmount(uint256 managerId) public view returns (uint256) {
        PositionManagerConfig memory config = positionManagerConfigs[managerId];
        // Get current underlying balance from position manager
        IPositionManager manager = IPositionManager(config.managerAddress);
        uint256 currentBalance = manager.getUnderlyingBalance();

        // Calculate interest as: current balance - allocated balance
        PositionAccountant memory accounting = positionAccountants[managerId];

        if (currentBalance > accounting.allocatedBalance) {
            return currentBalance - accounting.allocatedBalance;
        }

        return 0;
    }

    /// @notice 获取可用的分配容量
    /// @dev 计算公式：总分配容量 - 已分配余额
    /// @return 剩余可分配的容量
    function getAvailableCapacity() public view returns (uint256) {
        return totalAllocationCapacity - totalAllocatedBalance;
    }

    /// @notice 获取可用的资金余额
    /// @dev 计算公式：已接收资金 - 已返还资金
    /// @return 可用余额
    function getAvailableBalance() public view returns (uint256) {
        return totalFundsReceived - totalFundsReturned;
    }

    /// @notice 获取流动性缓冲池控制的总余额
    /// @dev 包括本合约余额 + 所有活跃头寸管理器中的余额
    /// @return 总控制余额
    /// @custom:warning 此函数会循环调用外部合约，gas 消耗较高
    function getControlledBalance() public view returns (uint256) {
        uint256 totalBalance = address(this).balance;

        // 遍历所有头寸管理器配置并获取其余额
        // 注意：此函数在循环中进行外部调用，gas 消耗较高
        // 生产环境考虑使用缓存或其他优化方案
        for (uint256 i = 0; i < positionManagerCount; i++) {
            PositionManagerConfig storage config = positionManagerConfigs[i];
            if (config.isActive) {
                IPositionManager manager = IPositionManager(config.managerAddress);
                uint256 managerBalance = manager.getUnderlyingBalance();
                totalBalance += managerBalance;
            }
        }

        return totalBalance;
    }

    // ========================================= 管理员函数 =========================================

    /// @notice 添加新的头寸管理器
    /// @dev 只有拥有 POSITION_MANAGER_ROLE 的地址可以调用
    /// @param managerAddress 头寸管理器合约地址
    /// @param allocationCap 该管理器的分配上限
    /// @return managerId 新创建的管理器 ID
    function addPositionManager(address managerAddress, uint256 allocationCap)
        external
        onlyRole(POSITION_MANAGER_ROLE)
        notZeroAddress(managerAddress)
        returns (uint256 managerId)
    {
        if (isRegisteredManager[managerAddress]) {
            revert LiquidityBuffer__ManagerAlreadyRegistered();
        }
        managerId = positionManagerCount;
        positionManagerCount++;

        positionManagerConfigs[managerId] =
            PositionManagerConfig({managerAddress: managerAddress, allocationCap: allocationCap, isActive: true});
        positionAccountants[managerId] = PositionAccountant({allocatedBalance: 0, interestClaimedFromManager: 0});
        isRegisteredManager[managerAddress] = true;

        totalAllocationCapacity += allocationCap;
        emit ProtocolConfigChanged(
            this.addPositionManager.selector,
            "addPositionManager(address,uint256)",
            abi.encode(managerAddress, allocationCap)
        );
    }

    /// @notice 更新头寸管理器配置
    /// @dev 新的分配上限不能低于当前已分配余额
    /// @param managerId 头寸管理器 ID
    /// @param newAllocationCap 新的分配上限
    /// @param isActive 是否激活该管理器
    function updatePositionManager(uint256 managerId, uint256 newAllocationCap, bool isActive)
        external
        onlyRole(POSITION_MANAGER_ROLE)
    {
        if (managerId >= positionManagerCount) {
            revert LiquidityBuffer__ManagerNotFound();
        }

        PositionManagerConfig storage config = positionManagerConfigs[managerId];

        if (newAllocationCap < positionAccountants[managerId].allocatedBalance) {
            revert LiquidityBuffer__InvalidConfiguration();
        }

        // Update total allocation capacity
        totalAllocationCapacity = totalAllocationCapacity + newAllocationCap - config.allocationCap;

        config.allocationCap = newAllocationCap;
        config.isActive = isActive;

        emit ProtocolConfigChanged(
            this.updatePositionManager.selector,
            "updatePositionManager(uint256,uint256,bool)",
            abi.encode(managerId, newAllocationCap, isActive)
        );
    }

    /// @notice 设置累计提款额度
    /// @dev 提款额度不能超过总分配容量
    /// @param drawdownAmount 新的累计提款额度
    function setCumulativeDrawdown(uint256 drawdownAmount) external onlyRole(DRAWDOWN_MANAGER_ROLE) {
        if (drawdownAmount > totalAllocationCapacity) {
            revert LiquidityBuffer__ExceedsAllocationCap();
        }
        cumulativeDrawdown = drawdownAmount;

        emit ProtocolConfigChanged(
            this.setCumulativeDrawdown.selector, "setCumulativeDrawdown(uint256)", abi.encode(drawdownAmount)
        );
    }

    /// @notice 设置默认头寸管理器 ID
    /// @dev 默认管理器用于自动分配存款
    /// @param newDefaultManagerId 新的默认管理器 ID
    function setDefaultManagerId(uint256 newDefaultManagerId) external onlyRole(POSITION_MANAGER_ROLE) {
        if (newDefaultManagerId >= positionManagerCount) {
            revert LiquidityBuffer__ManagerNotFound();
        }

        if (!positionManagerConfigs[newDefaultManagerId].isActive) {
            revert LiquidityBuffer__ManagerInactive();
        }

        defaultManagerId = newDefaultManagerId;

        emit ProtocolConfigChanged(
            this.setDefaultManagerId.selector, "setDefaultManagerId(uint256)", abi.encode(newDefaultManagerId)
        );
    }

    /// @notice 设置协议费率（基点）
    /// @dev 费率不能超过 100%（10000 基点）
    /// @param newBasisPoints 新的费率基点（例如 100 = 1%）
    function setFeeBasisPoints(uint16 newBasisPoints) external onlyRole(POSITION_MANAGER_ROLE) {
        if (newBasisPoints > _BASIS_POINTS_DENOMINATOR) {
            revert LiquidityBuffer__InvalidConfiguration();
        }

        feesBasisPoints = newBasisPoints;
        emit ProtocolConfigChanged(
            this.setFeeBasisPoints.selector, "setFeeBasisPoints(uint16)", abi.encode(newBasisPoints)
        );
    }

    /// @notice 设置协议费用接收钱包地址
    /// @param newReceiver 新的费用接收地址
    function setFeesReceiver(address payable newReceiver)
        external
        onlyRole(POSITION_MANAGER_ROLE)
        notZeroAddress(newReceiver)
    {
        feesReceiver = newReceiver;
        emit ProtocolConfigChanged(this.setFeesReceiver.selector, "setFeesReceiver(address)", abi.encode(newReceiver));
    }

    /// @notice 设置是否在 depositETH 方法中自动执行分配逻辑
    /// @dev 启用时，存入的资金会自动分配到默认管理器
    /// @param executeAllocation 是否执行自动分配
    function setShouldExecuteAllocation(bool executeAllocation) external onlyRole(POSITION_MANAGER_ROLE) {
        if (shouldExecuteAllocation == executeAllocation) {
            revert LiquidityBuffer__InvalidConfiguration();
        }
        shouldExecuteAllocation = executeAllocation;
        emit ProtocolConfigChanged(
            this.setShouldExecuteAllocation.selector, "setShouldExecuteAllocation(bool)", abi.encode(executeAllocation)
        );
    }

    /// @notice 设置头寸管理器的激活状态
    /// @param managerId 头寸管理器 ID
    /// @param isActive 是否激活
    function setPositionManagerStatus(uint256 managerId, bool isActive) external onlyRole(POSITION_MANAGER_ROLE) {
        if (managerId >= positionManagerCount) {
            revert LiquidityBuffer__ManagerNotFound();
        }

        PositionManagerConfig storage config = positionManagerConfigs[managerId];
        if (config.isActive == isActive) {
            revert LiquidityBuffer__InvalidConfiguration();
        }
        config.isActive = isActive;
        emit ProtocolConfigChanged(
            this.setPositionManagerStatus.selector,
            "setPositionManagerStatus(uint256,bool)",
            abi.encode(managerId, isActive)
        );
    }

    // ========================================= 流动性管理 =========================================

    /// @notice 从 Staking 合约接收 ETH 存款
    /// @dev 只能由 Staking 合约调用，如果启用了自动分配，会将资金分配到默认管理器
    function depositETH() external payable onlyStakingContract {
        if (pauser.isLiquidityBufferPaused()) revert LiquidityBuffer__Paused();
        _receiveETHFromStaking(msg.value);
        if (shouldExecuteAllocation) {
            _allocateETHToManager(defaultManagerId, msg.value);
        }
    }

    /// @notice 从头寸管理器撤回资金并返还给 Staking 合约
    /// @param managerId 头寸管理器 ID
    /// @param amount 撤回金额
    function withdrawAndReturn(uint256 managerId, uint256 amount) external onlyRole(LIQUIDITY_MANAGER_ROLE) {
        if (pauser.isLiquidityBufferPaused()) revert LiquidityBuffer__Paused();
        _withdrawETHFromManager(managerId, amount);
        _returnETHToStaking(amount);
    }

    /// @notice 将 ETH 分配到指定的头寸管理器
    /// @param managerId 头寸管理器 ID
    /// @param amount 分配金额
    function allocateETHToManager(uint256 managerId, uint256 amount) external onlyRole(LIQUIDITY_MANAGER_ROLE) {
        if (pauser.isLiquidityBufferPaused()) revert LiquidityBuffer__Paused();
        _allocateETHToManager(managerId, amount);
    }

    /// @notice 从指定头寸管理器撤回 ETH
    /// @param managerId 头寸管理器 ID
    /// @param amount 撤回金额
    function withdrawETHFromManager(uint256 managerId, uint256 amount) external onlyRole(LIQUIDITY_MANAGER_ROLE) {
        if (pauser.isLiquidityBufferPaused()) revert LiquidityBuffer__Paused();
        _withdrawETHFromManager(managerId, amount);
    }

    /// @notice 将 ETH 返还给 Staking 合约
    /// @param amount 返还金额
    function returnETHToStaking(uint256 amount) external onlyRole(LIQUIDITY_MANAGER_ROLE) {
        if (pauser.isLiquidityBufferPaused()) revert LiquidityBuffer__Paused();
        _returnETHToStaking(amount);
    }

    /// @notice 接收来自头寸管理器的 ETH
    /// @dev 只能由已注册的活跃头寸管理器调用
    function receiveETHFromPositionManager() external payable onlyPositionManagerContract {
        if (pauser.isLiquidityBufferPaused()) revert LiquidityBuffer__Paused();
        // 此函数接收来自头寸管理器的 ETH
        // ETH 已经在合约余额中，无需额外处理
    }

    // ========================================= 利息管理 =========================================

    /// @notice 从指定头寸管理器收集利息
    /// @param managerId 头寸管理器 ID
    /// @param minAmount 最小收集金额，低于此值会回退交易
    /// @return 实际收集的利息金额
    function claimInterestFromManager(uint256 managerId, uint256 minAmount)
        external
        onlyRole(INTEREST_TOPUP_ROLE)
        returns (uint256)
    {
        if (pauser.isLiquidityBufferPaused()) revert LiquidityBuffer__Paused();
        uint256 amount = _claimInterestFromManager(managerId);
        if (amount < minAmount) {
            revert LiquidityBuffer__InsufficientBalance();
        }
        return amount;
    }

    /// @notice 将利息充值到 Staking 合约
    /// @dev 会扣除协议费用后再充值
    /// @param amount 充值金额（扣费前）
    /// @return 实际充值金额（扣费后）
    function topUpInterestToStaking(uint256 amount) external onlyRole(INTEREST_TOPUP_ROLE) returns (uint256) {
        if (pauser.isLiquidityBufferPaused()) revert LiquidityBuffer__Paused();
        if (address(this).balance < amount) {
            revert LiquidityBuffer__InsufficientBalance();
        }
        _topUpInterestToStakingAndCollectFees(amount);
        return amount;
    }

    /// @notice 收集利息并立即充值到 Staking 合约
    /// @dev 组合操作：claimInterestFromManager + topUpInterestToStaking
    /// @param managerId 头寸管理器 ID
    /// @param minAmount 最小收集金额
    /// @return 实际充值金额
    function claimInterestAndTopUp(uint256 managerId, uint256 minAmount)
        external
        onlyRole(INTEREST_TOPUP_ROLE)
        returns (uint256)
    {
        if (pauser.isLiquidityBufferPaused()) revert LiquidityBuffer__Paused();
        uint256 amount = _claimInterestFromManager(managerId);
        if (amount < minAmount) {
            revert LiquidityBuffer__InsufficientBalance();
        }
        _topUpInterestToStakingAndCollectFees(amount);

        return amount;
    }

    // ========================================= 内部函数 =========================================

    /// @notice 将利息充值到 Staking 合约并收取协议费用
    /// @dev 内部函数，处理费用计算和转账
    /// @param amount 充值金额（扣费前）
    function _topUpInterestToStakingAndCollectFees(uint256 amount) internal {
        if (amount > pendingInterest) {
            revert LiquidityBuffer__ExceedsPendingInterest();
        }
        pendingInterest -= amount;
        uint256 fees = Math.mulDiv(feesBasisPoints, amount, _BASIS_POINTS_DENOMINATOR);
        uint256 topUpAmount = amount - fees;
        stakingContract.topUp{value: topUpAmount}();
        totalInterestToppedUp += topUpAmount;
        emit InterestToppedUp(topUpAmount);

        if (fees > 0) {
            Address.sendValue(feesReceiver, fees);
            totalFeesCollected += fees;
            emit FeesCollected(fees);
        }
    }

    /// @notice 从头寸管理器收集利息的内部实现
    /// @dev 遵循 CEI 模式（检查-生效-交互）
    /// @param managerId 头寸管理器 ID
    /// @return 收集的利息金额
    function _claimInterestFromManager(uint256 managerId) internal returns (uint256) {
        // 获取利息金额
        uint256 interestAmount = getInterestAmount(managerId);

        if (interestAmount > 0) {
            PositionManagerConfig memory config = positionManagerConfigs[managerId];

            // 先更新状态，再进行外部调用（CEI 模式）
            positionAccountants[managerId].interestClaimedFromManager += interestAmount;
            totalInterestClaimed += interestAmount;
            pendingInterest += interestAmount;
            emit InterestClaimed(managerId, interestAmount);

            // 状态更新完成后，从头寸管理器撤回利息
            IPositionManager manager = IPositionManager(config.managerAddress);
            manager.withdraw(interestAmount);
        } else {
            emit InterestClaimed(managerId, interestAmount);
        }

        return interestAmount;
    }

    /// @notice 从头寸管理器撤回 ETH 的内部实现
    /// @param managerId 头寸管理器 ID
    /// @param amount 撤回金额
    function _withdrawETHFromManager(uint256 managerId, uint256 amount) internal {
        if (managerId >= positionManagerCount) revert LiquidityBuffer__ManagerNotFound();
        PositionManagerConfig memory config = positionManagerConfigs[managerId];
        if (!config.isActive) revert LiquidityBuffer__ManagerInactive();
        PositionAccountant storage accounting = positionAccountants[managerId];

        // 检查分配余额是否充足
        if (amount > accounting.allocatedBalance) {
            revert LiquidityBuffer__InsufficientAllocation();
        }

        // 先更新状态，再进行外部调用（CEI 模式）
        accounting.allocatedBalance -= amount;
        totalAllocatedBalance -= amount;
        pendingPrincipal += amount;
        emit ETHWithdrawnFromManager(managerId, amount);

        // 状态更新完成后，调用头寸管理器撤回资金
        IPositionManager manager = IPositionManager(config.managerAddress);
        manager.withdraw(amount);
    }

    /// @notice 将 ETH 返还给 Staking 合约的内部实现
    /// @param amount 返还金额
    function _returnETHToStaking(uint256 amount) internal {
        // 验证 Staking 合约地址不为零
        if (address(stakingContract) == address(0)) {
            revert LiquidityBuffer__ZeroAddress();
        }

        if (amount > pendingPrincipal) {
            revert LiquidityBuffer__ExceedsPendingPrincipal();
        }

        // 先更新状态，再进行外部调用（CEI 模式）
        totalFundsReturned += amount;
        pendingPrincipal -= amount;
        emit ETHReturnedToStaking(amount);

        // 状态更新完成后，向受信任的 Staking 合约发送 ETH
        // 注意：stakingContract 是初始化时设置的受信任合约
        stakingContract.receiveReturnsFromLiquidityBuffer{value: amount}();
    }

    /// @notice 将 ETH 分配到头寸管理器的内部实现
    /// @param managerId 头寸管理器 ID
    /// @param amount 分配金额
    function _allocateETHToManager(uint256 managerId, uint256 amount) internal {
        if (amount > pendingPrincipal) {
            revert LiquidityBuffer__ExceedsPendingPrincipal();
        }

        if (managerId >= positionManagerCount) revert LiquidityBuffer__ManagerNotFound();
        // 检查可用余额
        if (address(this).balance < amount) revert LiquidityBuffer__InsufficientBalance();

        // 检查头寸管理器是否激活
        PositionManagerConfig memory config = positionManagerConfigs[managerId];
        if (!config.isActive) revert LiquidityBuffer__ManagerInactive();
        // 检查分配上限
        PositionAccountant storage accounting = positionAccountants[managerId];
        if (accounting.allocatedBalance + amount > config.allocationCap) {
            revert LiquidityBuffer__ExceedsAllocationCap();
        }

        // 先更新状态，再进行外部调用（CEI 模式）
        accounting.allocatedBalance += amount;
        totalAllocatedBalance += amount;
        pendingPrincipal -= amount;
        emit ETHAllocatedToManager(managerId, amount);

        // 状态更新完成后，存入头寸管理器
        IPositionManager manager = IPositionManager(config.managerAddress);
        manager.deposit{value: amount}(0);
    }

    /// @notice 从 Staking 接收 ETH 的内部实现
    /// @param amount 接收金额
    function _receiveETHFromStaking(uint256 amount) internal {
        totalFundsReceived += amount;
        pendingPrincipal += amount;
        emit ETHReceivedFromStaking(amount);
    }

    /// @notice 确保给定地址不是零地址
    /// @param addr 要检查的地址
    modifier notZeroAddress(address addr) {
        if (addr == address(0)) {
            revert LiquidityBuffer__ZeroAddress();
        }
        _;
    }

    /// @dev 验证调用者是 Staking 合约
    modifier onlyStakingContract() {
        if (msg.sender != address(stakingContract)) {
            revert LiquidityBuffer__NotStakingContract();
        }
        _;
    }

    /// @dev 验证调用者是已注册的活跃头寸管理器
    modifier onlyPositionManagerContract() {
        bool isValidManager = false;

        // 遍历所有头寸管理器配置，检查调用者是否为有效管理器
        for (uint256 i = 0; i < positionManagerCount; i++) {
            PositionManagerConfig memory config = positionManagerConfigs[i];

            if (msg.sender == config.managerAddress && config.isActive) {
                isValidManager = true;
                break;
            }
        }

        if (!isValidManager) {
            revert LiquidityBuffer__NotPositionManagerContract();
        }
        _;
    }

    /// @dev 拒绝直接发送 ETH，只能通过特定函数接收
    receive() external payable {
        revert LiquidityBuffer__DoesNotReceiveETH();
    }

    /// @dev 拒绝所有未知函数调用
    fallback() external payable {
        revert LiquidityBuffer__DoesNotReceiveETH();
    }
}
