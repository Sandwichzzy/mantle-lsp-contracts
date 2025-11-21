// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IProtocolEvents} from "../interfaces/IProtocolEvents.sol";
import {IDepositContract} from "../interfaces/IDepositContract.sol";
import {IMETH} from "../interfaces/IMETH.sol";
import {IOracleReadRecord, OracleRecord} from "../interfaces/IOracle.sol";
import {IPauserRead} from "../interfaces/IPauser.sol";
import {IStaking, IStakingReturnsWrite, IStakingInitiationRead} from "../interfaces/IStaking.sol";
import {UnstakeRequest, IUnstakeRequestsManager} from "../interfaces/IUnstakeRequestsManager.sol";

import {ILiquidityBuffer} from "../liquidityBuffer/interfaces/ILiquidityBuffer.sol";

contract Staking is Initializable, AccessControlEnumerableUpgradeable, IStaking, IProtocolEvents {
    /// @notice 允许触发管理任务的角色，例如向解除质押请求管理器分配资金 / 提取盈余，以及设置合约的各种参数。
    bytes32 public constant STAKING_MANAGER_ROLE = keccak256("STAKING_MANAGER_ROLE");

    /// @notice 允许向解除质押请求管理器分配资金并预留资金以存入验证者的角色。
    bytes32 public constant ALLOCATOR_SERVICE_ROLE = keccak256("ALLOCATER_SERVICE_ROLE");

    /// @notice 允许通过将资金从 allocatedETHForDeposits 余额发送到信标链存款合约来启动新验证者的角色。
    bytes32 public constant INITIATOR_SERVICE_ROLE = keccak256("INITIATOR_SERVICE_ROLE");

    /// @notice 管理质押白名单的角色。
    bytes32 public constant STAKING_ALLOWLIST_MANAGER_ROLE = keccak256("STAKING_ALLOWLIST_MANAGER_ROLE");

    /// @notice 当白名单启用时允许质押 ETH 的角色。
    bytes32 public constant STAKING_ALLOWLIST_ROLE = keccak256("STAKING_ALLOWLIST_ROLE");

    /// @notice 允许为协议中未分配的 ETH 充值的角色。
    bytes32 public constant TOP_UP_ROLE = keccak256("TOP_UP_ROLE");

    /// @notice 为验证者初始化提交的负载结构体。
    /// @dev 另见 {initiateValidatorsWithDeposits}。
    struct ValidatorParams {
        uint256 operatorID;
        uint256 depositAmount;
        bytes pubkey;
        bytes withdrawalCredentials;
        bytes signature;
        bytes32 depositDataRoot;
    }

    /// @notice 跟踪已经启动的验证者。
    /// @dev 跟踪此项是为了确保我们不会为同一个验证者公钥存款两次，这是本合约和相关链下会计的基本假设。
    mapping(bytes pubkey => bool exists) public usedValidators;

    /// @inheritdoc IStakingInitiationRead
    /// @dev 这是为了记录仍在传输中的 ETH，即已发送到存款合约但尚未被信标链处理的 ETH。
    /// 一旦链下预言机检测到这些存款，它们将在预言机合约中记录为 `totalDepositsProcessed` 以避免重复计数。
    /// 另见 {totalControlled}。
    uint256 public totalDepositedInValidators;

    /// @inheritdoc IStakingInitiationRead
    uint256 public numInitiatedValidators;

    /// @notice 用于分配给存款和填充待处理解除质押请求的 ETH 数量。
    uint256 public unallocatedETH;

    /// @notice 用于存入验证者的 ETH 数量。
    uint256 public allocatedETHForDeposits;

    /// @notice 用户可以质押的最小 ETH 数量。
    uint256 public minimumStakeBound;

    /// @notice 用户可以解除质押的最小 mETH 数量。
    uint256 public minimumUnstakeBound;

    /// @notice 在以太坊质押时，验证者必须通过入口队列将资金带入系统，并通过退出队列将资金带出。
    /// 随着更多人想要质押，入口队列的规模会增加。当资金在入口队列中时，它不会赚取任何奖励。
    /// 当验证者处于活跃状态或在退出队列中时，它会赚取奖励。一旦验证者进入入口队列，
    /// 唯一可以取回资金的方式是等待它变为活跃状态，然后再次退出。截至 2023 年 7 月，
    /// 入口队列大约需要 40 天，退出队列为 0 天（加上约 6 天的处理时间）。
    ///
    /// 在协议的非最优情况下，用户可以质押（例如）32 ETH 以接收 mETH，等待验证者进入队列，
    /// 然后请求解除质押以收回他们的 32 ETH。现在我们在系统中有 32 ETH，这会影响汇率，但不会赚取奖励。
    ///
    /// 在这种情况下，"公平"的做法是让用户在队列处理完成之前等待再返还他们的资金。
    /// 然而，由于代币是可互换的，我们无法将"待处理"的质押匹配到特定用户。
    /// 这意味着为了快速满足解除质押请求，我们必须退出不同的验证者来返还用户的资金。
    /// 如果我们退出验证者，我们可以在约 5 天后返还资金，但原始的 32 ETH 将在另外 35 天内不会赚取收益，
    /// 导致协议的小规模但可重复的社会化效率损失。由于我们只能以 32 ETH 的块退出验证者，
    /// 这种情况也因用户解除质押较小金额的 ETH 而加剧。
    ///
    /// 为了补偿这两个队列长度不同的事实，我们对汇率应用调整以反映差异并减轻其对协议的影响。
    /// 这保护了协议免受上述情况和遵循相同原则的恶意攻击。本质上，当你质押时，
    /// 你会收到一个折扣约 35 天奖励的 mETH 价值，以换取在解除质押时无需等待完整的 40 天即可访问你的资金。
    /// 由于调整应用于汇率，这会对所有现有质押者的汇率产生小幅"改善"（即这不是协议本身征收的费用）。
    ///
    /// 由于调整应用于汇率，结果会反映在显示质押时收到的 mETH 数量的任何用户界面中，
    /// 这意味着用户在质押或解除质押时不会感到惊讶。
    /// @dev 该值以基点（1/10000）为单位。
    uint16 public exchangeAdjustmentRate;

    /// @dev 基点（通常表示为 bp，1bp = 0.01%）是金融中用于描述金融工具百分比变化的度量单位。
    /// 这是一个设置为 10000 的常量值，以基点表示 100%。
    uint16 internal constant _BASIS_POINTS_DENOMINATOR = 10_000;

    /// @notice 管理员可以设置的最大汇率调整率（10%）。
    uint16 internal constant _MAX_EXCHANGE_ADJUSTMENT_RATE = _BASIS_POINTS_DENOMINATOR / 10; // 10%

    /// @notice 质押合约可以发送到存款合约以启动新验证者的最小 ETH 数量。
    /// @dev 这用作额外的保障，以防止发送会导致未激活验证者的存款（因为我们不做充值），
    /// 这些验证者需要再次退出才能拿回 ETH。
    uint256 public minimumDepositAmount;

    /// @notice 质押合约可以发送到存款合约以启动新验证者的最大 ETH 数量。
    /// @dev 这用作额外的保障，以防止发送过大的存款。虽然这不是关键问题，
    /// 因为任何超过 32 ETH（在撰写时）的盈余将在某个时候自动再次提取，
    /// 但仍然不理想，因为它会在往返期间锁定不赚取收益的 ETH，从而降低协议的效率。
    uint256 public maximumDepositAmount;

    /// @notice 信标链存款合约。
    /// @dev ETH 将在验证者初始化期间发送到那里。
    IDepositContract public depositContract;

    /// @notice mETH 代币合约。
    /// @dev 代币将在质押/解除质押期间铸造/销毁。
    IMETH public mETH;

    /// @notice 预言机合约。
    /// @dev 跟踪信标链上的 ETH 和其他会计相关数量。
    IOracleReadRecord public oracle;

    /// @notice 暂停器合约。
    /// @dev 保持整个协议的暂停状态。
    IPauserRead public pauser;

    /// @notice 跟踪解除质押请求以及相关分配和索赔操作的合约。
    IUnstakeRequestsManager public unstakeRequestsManager;

    /// @notice 接收信标链提款（即验证者奖励和退出）的地址。
    /// @dev 更改此变量不会立即生效，因为所有现有验证者仍将设置原始值。
    address public withdrawalWallet;

    /// @notice 收益聚合器合约推送资金的地址。
    /// @dev 另见 {receiveReturns}。
    address public returnsAggregator;

    /// @notice 质押白名单标志，启用时仅允许白名单中的地址进行质押。
    bool public isStakingAllowlist;

    /// @inheritdoc IStakingInitiationRead
    /// @dev 这将用于为链下服务提供一个合理的起始时间点来开始他们的分析。
    uint256 public initializationBlockNumber;

    /// @notice 在质押过程中可以铸造的最大 mETH 数量。
    /// @dev 这用作额外的保障，在协议中创建最大质押金额。随着协议规模扩大，此值将增加以允许更多质押。
    uint256 public maximumMETHSupply;

    /// @notice 流动性缓冲合约推送资金的地址。
    /// @dev 另见 {receiveReturnsFromLiquidityBuffer}。
    ILiquidityBuffer public liquidityBuffer;

    /// @notice 合约初始化的配置。
    struct Init {
        address admin;
        address manager;
        address allocatorService;
        address initiatorService;
        address returnsAggregator;
        address withdrawalWallet;
        IMETH mETH;
        IDepositContract depositContract;
        IOracleReadRecord oracle;
        IPauserRead pauser;
        IUnstakeRequestsManager unstakeRequestsManager;
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化合约。
    /// @dev 必须在合约升级期间调用以设置代理的状态。
    function initialize(Init memory init) external initializer {
        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(STAKING_MANAGER_ROLE, init.manager);
        _grantRole(ALLOCATOR_SERVICE_ROLE, init.allocatorService);
        _grantRole(INITIATOR_SERVICE_ROLE, init.initiatorService);
        // 故意不将任何人设置为 TOP_UP_ROLE，因为它只会在需要充值功能的特殊情况下授予。

        // 设置质押白名单的角色。故意不授予任何人 STAKING_ALLOWLIST_MANAGER_ROLE，因为它将在以后授予。
        _setRoleAdmin(STAKING_ALLOWLIST_MANAGER_ROLE, STAKING_MANAGER_ROLE);
        _setRoleAdmin(STAKING_ALLOWLIST_ROLE, STAKING_ALLOWLIST_MANAGER_ROLE);

        mETH = init.mETH;
        depositContract = init.depositContract;
        oracle = init.oracle;
        pauser = init.pauser;
        returnsAggregator = init.returnsAggregator;
        unstakeRequestsManager = init.unstakeRequestsManager;
        withdrawalWallet = init.withdrawalWallet;

        minimumStakeBound = 0.1 ether;
        minimumUnstakeBound = 0.01 ether;
        minimumDepositAmount = 32 ether;
        maximumDepositAmount = 32 ether;
        isStakingAllowlist = true;
        initializationBlockNumber = block.number;

        // 将最大 mETH 供应量设置为某个合理的金额，预计随着协议的扩大将发生变化。
        maximumMETHSupply = 1024 ether;
    }

    function initializeV2(ILiquidityBuffer lb) public reinitializer(2) notZeroAddress(address(lb)) {
        liquidityBuffer = lb;
    }

    /// @notice 用户使用协议质押 ETH 的接口。注意：当白名单启用时，只有白名单中的用户可以质押。
    /// @dev 根据质押在协议控制的总 ETH 中的份额，向用户铸造相应数量的 mETH。
    /// @param minMETHAmount 用户期望获得的最小 mETH 数量。
    function stake(uint256 minMETHAmount) external payable {
        if (pauser.isStakingPaused()) {
            revert Paused();
        }

        if (isStakingAllowlist) {
            _checkRole(STAKING_ALLOWLIST_ROLE);
        }

        if (msg.value < minimumStakeBound) {
            revert MinimumStakeBoundNotSatisfied();
        }

        uint256 mETHMintAmount = ethToMETH(msg.value);
        if (mETHMintAmount + mETH.totalSupply() > maximumMETHSupply) {
            revert MaximumMETHSupplyExceeded();
        }
        if (mETHMintAmount < minMETHAmount) {
            revert StakeBelowMinimumMETHAmount(mETHMintAmount, minMETHAmount);
        }

        // 在计算汇率后增加未分配的 ETH，以确保一致的汇率。
        unallocatedETH += msg.value;

        emit Staked(msg.sender, msg.value, mETHMintAmount);
        mETH.mint(msg.sender, mETHMintAmount);
    }

    /// @notice 用户提交解除质押请求的接口。
    /// @dev 将指定数量的 mETH 转移到质押合约并锁定在那里，直到在请求claim时被销毁。
    /// 因此，质押合约必须被批准代表用户移动用户的 mETH。
    /// @param methAmount 要解除质押的 mETH 数量。
    /// @param minETHAmount 用户期望获得的最小 ETH 数量。
    /// @return 请求 ID。
    function unstakeRequest(uint128 methAmount, uint128 minETHAmount) external returns (uint256) {
        return _unstakeRequest(methAmount, minETHAmount);
    }

    /// @notice 用户使用 ERC20 许可提交解除质押请求的接口。
    /// @dev 将指定数量的 mETH 转移到质押合约并锁定在那里，直到在请求claim时被销毁。
    /// 因此，许可必须允许质押合约代表用户移动用户的 mETH。
    /// @return 请求 ID。
    function unstakeRequestWithPermit(
        uint128 methAmount,
        uint128 minETHAmount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256) {
        IMETH(address(mETH)).permit(msg.sender, address(this), methAmount, deadline, v, r, s);
        return _unstakeRequest(methAmount, minETHAmount);
    }

    /// @notice 通过将相应的 mETH 转移到质押合约并在解除质押请求管理器上创建请求来处理用户的解除质押请求。
    /// @param methAmount 要解除质押的 mETH 数量。
    /// @param minETHAmount 用户期望获得的最小 ETH 数量。
    function _unstakeRequest(uint128 methAmount, uint128 minETHAmount) internal returns (uint256) {
        if (pauser.isUnstakeRequestsAndClaimsPaused()) {
            revert Paused();
        }

        if (methAmount < minimumUnstakeBound) {
            revert MinimumUnstakeBoundNotSatisfied();
        }

        uint128 ethAmount = uint128(mETHToETH(methAmount));
        if (ethAmount < minETHAmount) {
            revert UnstakeBelowMinimumETHAmount(ethAmount, minETHAmount);
        }

        uint256 requestID =
            unstakeRequestsManager.create({requester: msg.sender, mETHLocked: methAmount, ethRequested: ethAmount});
        emit UnstakeRequested({id: requestID, staker: msg.sender, ethAmount: ethAmount, mETHLocked: methAmount});

        SafeERC20.safeTransferFrom(IERC20(address(mETH)), msg.sender, address(unstakeRequestsManager), methAmount);

        return requestID;
    }

    /// @notice Interface for users to claim their finalized and filled unstaking requests.
    /// @dev 另见 {UnstakeRequestsManager} 以获取有关完成和请求填充的更详细说明。
    function claimUnstakeRequest(uint256 unstakeRequestID) external {
        if (pauser.isUnstakeRequestsAndClaimsPaused()) {
            revert Paused();
        }
        emit UnstakeRequestClaimed(unstakeRequestID, msg.sender);
        unstakeRequestsManager.claim(unstakeRequestID, msg.sender);
    }

    /// @notice 返回请求的状态，包括是否已完成以及已填充了多少 ETH。
    /// 另见 {UnstakeRequestsManager.requestInfo} 以获取有关完成和请求填充的更详细说明。
    /// @param unstakeRequestID 解除质押请求的 ID。
    /// @return 指示解除质押请求是否已完成的布尔值，以及已填充的 ETH 数量。
    function unstakeRequestInfo(uint256 unstakeRequestID) external view returns (bool, uint256) {
        return unstakeRequestsManager.requestInfo(unstakeRequestID);
    }

    /// @notice 从解除质押请求管理器提取任何盈余。
    /// @dev 请求管理器预计将通过使用 {receiveFromUnstakeRequestsManager} 推送资金来返还资金。
    function reclaimAllocatedETHSurplus() external onlyRole(STAKING_MANAGER_ROLE) {
        // 调用 receiveFromUnstakeRequestsManager()，我们在那里执行会计处理。
        unstakeRequestsManager.withdrawAllocatedETHSurplus();
    }

    /// @notice 从 unallocatedETH 余额中分配 ETH 到解除质押请求管理器以填充待处理的请求，
    /// 并添加到用于启动新验证者的 allocatedETHForDeposits 余额。
    function allocateETH(
        uint256 allocateToUnstakeRequestsManager,
        uint256 allocateToDeposits,
        uint256 allocateToLiquidityBuffer
    ) external onlyRole(ALLOCATOR_SERVICE_ROLE) {
        if (pauser.isAllocateETHPaused()) {
            revert Paused();
        }

        if (allocateToUnstakeRequestsManager + allocateToDeposits + allocateToLiquidityBuffer > unallocatedETH) {
            revert NotEnoughUnallocatedETH();
        }

        unallocatedETH -= allocateToUnstakeRequestsManager + allocateToDeposits + allocateToLiquidityBuffer;

        if (allocateToDeposits > 0) {
            allocatedETHForDeposits += allocateToDeposits;
            emit AllocatedETHToDeposits(allocateToDeposits);
        }

        if (allocateToUnstakeRequestsManager > 0) {
            emit AllocatedETHToUnstakeRequestsManager(allocateToUnstakeRequestsManager);
            unstakeRequestsManager.allocateETH{value: allocateToUnstakeRequestsManager}();
        }

        if (allocateToLiquidityBuffer > 0) {
            emit AllocatedETHToLiquidityBuffer(allocateToLiquidityBuffer);
            liquidityBuffer.depositETH{value: allocateToLiquidityBuffer}();
        }
    }

    /// @notice 通过将 ETH 发送到信标链存款合约来启动新验证者。
    /// @dev 不能两次启动同一个验证者（公钥）。由于 BLS 签名无法在 EVM 上可行地验证，
    /// 调用者必须仔细确保发送的负载（公钥 + 签名）是正确的，否则发送的 ETH 将丢失。
    function initiateValidatorsWithDeposits(ValidatorParams[] calldata validators, bytes32 expectedDepositRoot)
        external
        onlyRole(INITIATOR_SERVICE_ROLE)
    {
        if (pauser.isInitiateValidatorsPaused()) {
            revert Paused();
        }
        if (validators.length == 0) {
            return;
        }

        // 检查存款根是否与给定值匹配。这确保自提交交易以来存款合约状态没有改变，
        // 这意味着恶意节点运营商无法抢跑存款交易。
        bytes32 actualRoot = depositContract.get_deposit_root();
        if (expectedDepositRoot != actualRoot) {
            revert InvalidDepositRoot(actualRoot);
        }

        // 第一个循环是检查所有验证者是否符合我们的约束，并记录验证者以及我们存入的金额。
        uint256 amountDeposited = 0;
        for (uint256 i = 0; i < validators.length; ++i) {
            ValidatorParams calldata validator = validators[i];

            if (usedValidators[validator.pubkey]) {
                revert PreviouslyUsedValidator();
            }

            if (validator.depositAmount < minimumDepositAmount) {
                revert MinimumValidatorDepositNotSatisfied();
            }

            if (validator.depositAmount > maximumDepositAmount) {
                revert MaximumValidatorDepositExceeded();
            }

            _requireProtocolWithdrawalAccount(validator.withdrawalCredentials);

            usedValidators[validator.pubkey] = true;
            amountDeposited += validator.depositAmount;

            emit ValidatorInitiated({
                id: keccak256(validator.pubkey),
                operatorID: validator.operatorID,
                pubkey: validator.pubkey,
                amountDeposited: validator.depositAmount
            });
        }

        if (amountDeposited > allocatedETHForDeposits) {
            revert NotEnoughDepositETH();
        }

        allocatedETHForDeposits -= amountDeposited;
        totalDepositedInValidators += amountDeposited;
        numInitiatedValidators += validators.length;

        // 第二个循环是将存款发送到存款合约。将外部调用与状态更改分开。
        for (uint256 i = 0; i < validators.length; ++i) {
            ValidatorParams calldata validator = validators[i];
            depositContract.deposit{
                value: validator.depositAmount
            }({
                pubkey: validator.pubkey,
                withdrawal_credentials: validator.withdrawalCredentials,
                signature: validator.signature,
                deposit_data_root: validator.depositDataRoot
            });
        }
    }

    /// @inheritdoc IStakingReturnsWrite
    /// @dev 旨在在由 reclaimAllocatedETHSurplus() 启动的同一交易中调用。
    /// 这应该只在紧急情况下调用，例如，如果解除质押请求管理器已取消未完成的请求并且存在盈余余额。
    /// 将接收到的资金添加到未分配余额。
    function receiveFromUnstakeRequestsManager() external payable onlyUnstakeRequestsManager {
        unallocatedETH += msg.value;
    }

    /// @notice 为未分配的 ETH 余额充值以增加协议中的 ETH 数量。
    /// @dev 绕过收益聚合器费用收集，直接将 ETH 注入协议。
    function topUp() external payable onlyRole(TOP_UP_ROLE) {
        unallocatedETH += msg.value;
    }

    /// @notice 使用当前汇率将 ETH 转换为 mETH。
    /// 汇率由 mETH 的总供应量和协议控制的总 ETH 给出。
    function ethToMETH(uint256 ethAmount) public view returns (uint256) {
        // 首次质押时的 1:1 汇率。
        // 使用 `mETH.totalSupply` 而不是 `totalControlled` 来检查协议是否处于引导阶段，
        // 因为后者可以被操纵，例如通过将资金转移到 `ExecutionLayerReturnsReceiver`，
        // 因此在进行首次质押时可能为非零。
        if (mETH.totalSupply() == 0) {
            return ethAmount;
        }

        // deltaMETH = (1 - exchangeAdjustmentRate) * (mETHSupply / totalControlled) * ethAmount
        // 在 `(1 - exchangeAdjustmentRate) * ethAmount * mETHSupply < totalControlled` 的情况下，这会向下舍入为零。
        // 虽然这种情况在理论上是可能的，但只能在协议的引导阶段以及 `totalControlled` 和 `mETHSupply`
        // 可以相互独立更改的情况下实现。由于前者是需要权限的，后者不被协议允许，因此攻击者无法利用这一点。
        return Math.mulDiv(
            ethAmount,
            mETH.totalSupply() * uint256(_BASIS_POINTS_DENOMINATOR - exchangeAdjustmentRate),
            totalControlled() * uint256(_BASIS_POINTS_DENOMINATOR)
        );
    }

    /// @notice 使用当前汇率将 mETH 转换为 ETH。
    /// 汇率由 mETH 的总供应量和协议控制的总 ETH 给出。
    function mETHToETH(uint256 mETHAmount) public view returns (uint256) {
        // 首次质押时的 1:1 汇率。
        // 使用 `mETH.totalSupply` 而不是 `totalControlled` 来检查协议是否处于引导阶段，
        // 因为后者可以被操纵，例如通过将资金转移到 `ExecutionLayerReturnsReceiver`，
        // 因此在进行首次质押时可能为非零。
        if (mETH.totalSupply() == 0) {
            return mETHAmount;
        }

        // deltaETH = (totalControlled / mETHSupply) * mETHAmount
        // 在 `mETHAmount * totalControlled < mETHSupply` 的情况下，这会向下舍入为零。
        // 虽然这种情况在理论上是可能的，但只能在协议的引导阶段以及 `totalControlled` 和 `mETHSupply`
        // 可以相互独立更改的情况下实现。由于前者是需要权限的，后者不被协议允许，因此攻击者无法利用这一点。
        return Math.mulDiv(mETHAmount, totalControlled(), mETH.totalSupply());
    }

    /// @notice 协议控制的 ETH 总量。
    /// @dev 对各种合约的余额和来自预言机的信标链信息求和。
    function totalControlled() public view returns (uint256) {
        OracleRecord memory record = oracle.latestRecord();
        uint256 total = 0;
        total += unallocatedETH;
        total += allocatedETHForDeposits;
        /// 存入信标链的总 ETH 必须减去链下预言机处理的存款，
        /// 因为从那时起它将在 currentTotalValidatorBalance 中记录。
        total += totalDepositedInValidators - record.cumulativeProcessedDepositAmount;
        total += record.currentTotalValidatorBalance;
        total += liquidityBuffer.getAvailableBalance();
        total -= liquidityBuffer.cumulativeDrawdown();
        total += unstakeRequestsManager.balance();
        return total;
    }

    /// @notice 检查给定的提款凭证是否是有效的 0x01 前缀提款地址。
    /// @dev 另见
    /// https://github.com/ethereum/consensus-specs/blob/master/specs/phase0/validator.md#eth1_address_withdrawal_prefix
    function _requireProtocolWithdrawalAccount(bytes calldata withdrawalCredentials) internal view {
        if (withdrawalCredentials.length != 32) {
            revert InvalidWithdrawalCredentialsWrongLength(withdrawalCredentials.length);
        }

        // 检查 ETH1_ADDRESS_WITHDRAWAL_PREFIX 以及所有其他字节是否为零。
        bytes12 prefixAndPadding = bytes12(withdrawalCredentials[:12]);
        if (prefixAndPadding != 0x010000000000000000000000) {
            revert InvalidWithdrawalCredentialsNotETH1(prefixAndPadding);
        }

        address addr = address(bytes20(withdrawalCredentials[12:32]));
        if (addr != withdrawalWallet) {
            revert InvalidWithdrawalCredentialsWrongAddress(addr);
        }
    }

    /// @inheritdoc IStakingReturnsWrite
    /// @dev 将接收到的资金添加到未分配余额。
    function receiveReturns() external payable onlyReturnsAggregator {
        emit ReturnsReceived(msg.value);
        unallocatedETH += msg.value;
    }

    /// @dev 将接收到的资金添加到未分配余额。
    function receiveReturnsFromLiquidityBuffer() external payable onlyLiquidityBuffer {
        emit ReturnsReceivedFromLiquidityBuffer(msg.value);
        unallocatedETH += msg.value;
    }

    /// @notice 确保调用者是收益聚合器。
    modifier onlyReturnsAggregator() {
        if (msg.sender != returnsAggregator) {
            revert NotReturnsAggregator();
        }
        _;
    }

    /// @notice 确保调用者是流动性缓冲池。
    modifier onlyLiquidityBuffer() {
        if (msg.sender != address(liquidityBuffer)) {
            revert NotLiquidityBuffer();
        }
        _;
    }

    /// @notice 确保调用者是解除质押请求管理器。
    modifier onlyUnstakeRequestsManager() {
        if (msg.sender != address(unstakeRequestsManager)) {
            revert NotUnstakeRequestsManager();
        }
        _;
    }

    /// @notice 确保给定地址不是零地址。
    modifier notZeroAddress(address addr) {
        if (addr == address(0)) {
            revert ZeroAddress();
        }
        _;
    }

    /// @notice 设置用户可以质押的最小 ETH 数量。
    function setMinimumStakeBound(uint256 minimumStakeBound_) external onlyRole(STAKING_MANAGER_ROLE) {
        minimumStakeBound = minimumStakeBound_;
        emit ProtocolConfigChanged(
            this.setMinimumStakeBound.selector, "setMinimumStakeBound(uint256)", abi.encode(minimumStakeBound_)
        );
    }

    /// @notice 设置用户可以解除质押的最小 mETH 数量。
    function setMinimumUnstakeBound(uint256 minimumUnstakeBound_) external onlyRole(STAKING_MANAGER_ROLE) {
        minimumUnstakeBound = minimumUnstakeBound_;
        emit ProtocolConfigChanged(
            this.setMinimumUnstakeBound.selector, "setMinimumUnstakeBound(uint256)", abi.encode(minimumUnstakeBound_)
        );
    }

    /// @notice 设置质押调整率。
    function setExchangeAdjustmentRate(uint16 exchangeAdjustmentRate_) external onlyRole(STAKING_MANAGER_ROLE) {
        if (exchangeAdjustmentRate_ > _MAX_EXCHANGE_ADJUSTMENT_RATE) {
            revert InvalidConfiguration();
        }

        // 即使此检查与上面的检查冗余，但由于此函数很少使用，我们将其保留为未来升级的提醒，绝不能违反此规则。
        assert(exchangeAdjustmentRate_ <= _BASIS_POINTS_DENOMINATOR);

        exchangeAdjustmentRate = exchangeAdjustmentRate_;
        emit ProtocolConfigChanged(
            this.setExchangeAdjustmentRate.selector,
            "setExchangeAdjustmentRate(uint16)",
            abi.encode(exchangeAdjustmentRate_)
        );
    }

    /// @notice 设置质押合约可以发送到存款合约以启动新验证者的最小 ETH 数量。
    function setMinimumDepositAmount(uint256 minimumDepositAmount_) external onlyRole(STAKING_MANAGER_ROLE) {
        minimumDepositAmount = minimumDepositAmount_;
        emit ProtocolConfigChanged(
            this.setMinimumDepositAmount.selector, "setMinimumDepositAmount(uint256)", abi.encode(minimumDepositAmount_)
        );
    }

    /// @notice 设置质押合约可以发送到存款合约以启动新验证者的最大 ETH 数量。
    function setMaximumDepositAmount(uint256 maximumDepositAmount_) external onlyRole(STAKING_MANAGER_ROLE) {
        maximumDepositAmount = maximumDepositAmount_;
        emit ProtocolConfigChanged(
            this.setMaximumDepositAmount.selector, "setMaximumDepositAmount(uint256)", abi.encode(maximumDepositAmount_)
        );
    }

    /// @notice 设置 maximumMETHSupply 变量。
    /// 注意：我们故意允许将其设置为低于当前 totalSupply，以便通过解除质押可以向下调整金额。
    /// 另见 {maximumMETHSupply}。
    function setMaximumMETHSupply(uint256 maximumMETHSupply_) external onlyRole(STAKING_MANAGER_ROLE) {
        maximumMETHSupply = maximumMETHSupply_;
        emit ProtocolConfigChanged(
            this.setMaximumMETHSupply.selector, "setMaximumMETHSupply(uint256)", abi.encode(maximumMETHSupply_)
        );
    }

    /// @notice 设置接收信标链提款（即验证者奖励和退出）的地址。
    /// @dev 更改此变量不会立即生效，因为所有现有验证者仍将设置原始值。
    function setWithdrawalWallet(address withdrawalWallet_)
        external
        onlyRole(STAKING_MANAGER_ROLE)
        notZeroAddress(withdrawalWallet_)
    {
        withdrawalWallet = withdrawalWallet_;
        emit ProtocolConfigChanged(
            this.setWithdrawalWallet.selector, "setWithdrawalWallet(address)", abi.encode(withdrawalWallet_)
        );
    }

    /// @notice 设置质押白名单标志。
    function setStakingAllowlist(bool isStakingAllowlist_) external onlyRole(STAKING_MANAGER_ROLE) {
        isStakingAllowlist = isStakingAllowlist_;
        emit ProtocolConfigChanged(
            this.setStakingAllowlist.selector, "setStakingAllowlist(bool)", abi.encode(isStakingAllowlist_)
        );
    }

    receive() external payable {
        revert DoesNotReceiveETH();
    }

    fallback() external payable {
        revert DoesNotReceiveETH();
    }
}
