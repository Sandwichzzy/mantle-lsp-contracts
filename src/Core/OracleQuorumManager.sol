// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

import {OracleRecord, IOracle} from "../interfaces/IOracle.sol";
import {IProtocolEvents} from "../interfaces/IProtocolEvents.sol";

// ============================================
// 事件接口
// ============================================

interface OracleQuorumManagerEvents {
    /// @notice 当记录达到法定人数并提交给预言机时发出
    /// @param block 记录最终确定的区块
    event ReportQuorumReached(uint64 indexed block);

    /// @notice 当记录被报告者报告时发出
    /// @param block 记录被记录的区块
    /// @param reporter 报告记录的报告者
    /// @param recordHash 报告的记录哈希
    /// @param record 收到的记录
    event ReportReceived(
        uint64 indexed block, address indexed reporter, bytes32 indexed recordHash, OracleRecord record
    );

    /// @notice 当预言机未能从预言机法定人数管理器接收记录时发出
    /// @param reason 失败原因，即捕获的错误
    event OracleRecordReceivedError(bytes reason);
}

/// @title OracleQuorumManager
/// @notice 负责管理预言机报告者的法定人数
contract OracleQuorumManager is
    Initializable,
    AccessControlEnumerableUpgradeable,
    OracleQuorumManagerEvents,
    IProtocolEvents
{
    // ============================================
    // error
    // ============================================

    error InvalidReporter();
    error AlreadyReporter();
    error RelativeThresholdExceedsOne();

    // ============================================
    // 角色定义
    // ============================================

    /// @notice 预言机管理员角色，可更新 OracleQuorumManager 中的属性
    bytes32 public constant QUORUM_MANAGER_ROLE = keccak256("QUORUM_MANAGER_ROLE");

    /// @notice 报告者修改者角色，可更改可产生有效预言机报告的预言机服务集合。
    /// 这是一个相当关键的角色，应具有更高的访问要求
    bytes32 public constant REPORTER_MODIFIER_ROLE = keccak256("REPORTER_MODIFIER_ROLE");

    /// @notice 服务预言机报告者角色，用于标识哪些预言机服务可以产生有效的预言机报告。
    /// 注意，向地址授予此角色可能对合约逻辑产生影响，例如合约可能根据此集合中的成员数量计算法定人数。
    /// 因此，您不应将该角色添加到预言机服务以外的任何对象
    /// @dev 要发现所有预言机服务，可以使用 `getRoleMemberCount` 和 `getRoleMember(role, N)`（在同一区块上）
    bytes32 public constant SERVICE_ORACLE_REPORTER = keccak256("SERVICE_ORACLE_REPORTER");

    /// @dev 基点（通常表示为 bp，1bp = 0.01%）是金融中用于描述金融工具百分比变化的度量单位。
    /// 这是一个设置为 10000 的常量值，表示以基点计算的 100%
    uint16 internal constant _BASIS_POINTS_DENOMINATOR = 10000;

    // ============================================
    // 状态变量
    // ============================================

    /// @notice 要为其最终确定报告的预言机
    IOracle public oracle;

    /// @notice 按报告者按区块存储的报告哈希
    /// @dev 报告者可以使用此映射来验证记录计算并在出错时更新它
    mapping(uint64 block => mapping(address reporter => bytes32 recordHash)) public reporterRecordHashesByBlock;

    /// @notice 某个区块的记录哈希被报告的次数
    mapping(uint64 block => mapping(bytes32 recordHash => uint256)) public recordHashCountByBlock;

    /// @notice 报告窗口的目标区块数
    uint64 public targetReportWindowBlocks;

    /// @notice 必须提交相同报告才能被接受的报告者绝对数量
    uint16 public absoluteThreshold;

    /// @notice 必须提交相同报告才能被接受的报告者相对数量（以基点计）
    /// @dev 这是一个介于 0 和 10000 基点（即 0 到 100%）之间的值。用于确定报告者总数中需要就报告达成一致的比例
    /// @dev 按 `getRoleMemberCount(SERVICE_ORACLE_REPORTER)` 缩放
    uint16 public relativeThresholdBasisPoints;

    // ============================================
    // 初始化配置
    // ============================================

    /// @notice 合约初始化配置
    struct Init {
        address admin;
        address reporterModifier;
        address manager;
        address[] allowedReporters;
        IOracle oracle;
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化合约
    /// @dev 必须在合约升级期间调用以设置代理状态
    function initialize(Init memory init) external initializer {
        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(REPORTER_MODIFIER_ROLE, init.reporterModifier);
        _setRoleAdmin(SERVICE_ORACLE_REPORTER, REPORTER_MODIFIER_ROLE);

        _grantRole(QUORUM_MANAGER_ROLE, init.manager);

        oracle = init.oracle;
        uint256 len = init.allowedReporters.length;
        for (uint256 i = 0; i < len; i++) {
            _grantRole(SERVICE_ORACLE_REPORTER, init.allowedReporters[i]);
        }

        // 假设每 12 秒创建一个区块
        // 实践中可能略长于 8 小时目标，因为槽位可能为空
        targetReportWindowBlocks = 8 hours / 12 seconds;

        absoluteThreshold = 1;
        relativeThresholdBasisPoints = 0;
    }

    // ============================================
    // 内部函数 - 法定人数检查
    // ============================================

    /// @notice 确定给定记录哈希是否已达到给定区块的法定人数
    /// @dev 如果同意记录哈希的报告者数量大于或等于绝对阈值和相对阈值，则返回 true
    /// @param blockNumber 区块号
    /// @param recordHash 记录哈希
    function _hasReachedQuroum(uint64 blockNumber, bytes32 recordHash) internal view returns (bool) {
        uint256 numReports = recordHashCountByBlock[blockNumber][recordHash];
        uint256 numReporters = getRoleMemberCount(SERVICE_ORACLE_REPORTER);

        return (numReports >= absoluteThreshold)
            && (numReports * _BASIS_POINTS_DENOMINATOR >= numReporters * relativeThresholdBasisPoints);
    }

    /// @notice 确定具有给定结束区块号的记录是否已被预言机接收
    /// @dev 包括已添加和待处理的记录
    /// @param updateEndBlock 结束区块号
    function _wasReceivedByOracle(uint256 updateEndBlock) internal view returns (bool) {
        return oracle.latestRecord().updateEndBlock >= updateEndBlock
            || (oracle.hasPendingUpdate() && oracle.pendingUpdate().updateEndBlock >= updateEndBlock);
    }

    /// @notice 跟踪收到的记录以确定共识
    /// @param reporter 提交记录的链下服务地址
    /// @param record 收到的记录
    function _trackReceivedRecord(address reporter, OracleRecord calldata record) internal returns (bytes32) {
        bytes32 newHash = keccak256(abi.encode(record));
        emit ReportReceived(record.updateEndBlock, reporter, newHash, record);

        bytes32 previousHash = reporterRecordHashesByBlock[record.updateEndBlock][reporter];
        if (newHash == previousHash) {
            return newHash;
        }

        if (previousHash != 0) {
            recordHashCountByBlock[record.updateEndBlock][previousHash] -= 1;
        }

        // 记录此报告的数据哈希
        recordHashCountByBlock[record.updateEndBlock][newHash] += 1;
        reporterRecordHashesByBlock[record.updateEndBlock][reporter] = newHash;

        return newHash;
    }

    // ============================================
    // 核心函数 - 接收记录
    // ============================================

    /// @notice 接收预言机报告
    /// @dev 此函数应由预言机服务调用。
    /// 我们明确允许预言机为给定区块"更新"其报告。这允许在出现不一致的情况下进行修复，而无需启动新窗口。
    /// 此函数故意永不回滚，以将所有收到的报告记录为事件，用于链下性能指标，并简化与预言机服务的交互
    /// @param record 新的预言机记录更新
    function receiveRecord(OracleRecord calldata record) external onlyRole(SERVICE_ORACLE_REPORTER) {
        bytes32 recordHash = _trackReceivedRecord(msg.sender, record);

        if (!_hasReachedQuroum(record.updateEndBlock, recordHash)) {
            return;
        }

        if (_wasReceivedByOracle(record.updateEndBlock)) {
            // 如果报告者在达到法定人数后提交报告，则会采用此分支，
            // 例如在 2/3 阈值设置中的第 3 个报告者
            return;
        }

        emit ReportQuorumReached(record.updateEndBlock);

        // 故意不回滚以简化链下预言机服务的集成，但将任何预言机错误包装为事件以便观察
        try oracle.receiveRecord(record) {}
        catch (bytes memory reason) {
            emit OracleRecordReceivedError(reason);
        }
    }

    // ============================================
    // 查询函数
    // ============================================

    /// @notice 返回给定区块和报告者的记录哈希
    /// @param blockNumber 区块号
    /// @param sender 报告者
    function recordHashByBlockAndSender(uint64 blockNumber, address sender) external view returns (bytes32) {
        return reporterRecordHashesByBlock[blockNumber][sender];
    }

    // ============================================
    // 管理函数 - 参数设置
    // ============================================

    /// @notice 设置目标报告窗口大小（区块数）
    /// @param newTargetReportWindowBlocks 新的目标报告窗口大小（区块数）
    /// @dev 注意：将此值设置为低于预言机定义的最小报告大小在技术上是有效的，但会导致合理性检查失败
    function setTargetReportWindowBlocks(uint64 newTargetReportWindowBlocks) external onlyRole(QUORUM_MANAGER_ROLE) {
        targetReportWindowBlocks = newTargetReportWindowBlocks;
        emit ProtocolConfigChanged(
            this.setTargetReportWindowBlocks.selector,
            "setTargetReportWindowBlocks(uint64)",
            abi.encode(newTargetReportWindowBlocks)
        );
    }

    /// @notice 设置报告被接受的绝对和相对阈值（即必须达成一致的报告者数量）
    /// @param absoluteThreshold_ 新的绝对阈值，设置 absoluteThreshold。参见 {absoluteThreshold}
    /// @param relativeThresholdBasisPoints_ 新的相对阈值（基点），设置 relativeThresholdBasisPoints。
    /// 参见 {relativeThresholdBasisPoints}
    function setQuorumThresholds(uint16 absoluteThreshold_, uint16 relativeThresholdBasisPoints_)
        external
        onlyRole(QUORUM_MANAGER_ROLE)
    {
        if (relativeThresholdBasisPoints_ > _BASIS_POINTS_DENOMINATOR) {
            revert RelativeThresholdExceedsOne();
        }

        emit ProtocolConfigChanged(
            this.setQuorumThresholds.selector,
            "setQuorumThresholds(uint16,uint16)",
            abi.encode(absoluteThreshold_, relativeThresholdBasisPoints_)
        );
        absoluteThreshold = absoluteThreshold_;
        relativeThresholdBasisPoints = relativeThresholdBasisPoints_;
    }
}
