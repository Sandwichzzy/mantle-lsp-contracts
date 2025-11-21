// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IProtocolEvents} from "../interfaces/IProtocolEvents.sol";
import {
    IOracle,
    IOracleReadRecord,
    IOracleReadPending,
    IOracleWrite,
    IOracleManager,
    OracleRecord
} from "../interfaces/IOracle.sol";
import {IStakingInitiationRead} from "../interfaces/IStaking.sol";
import {IReturnsAggregatorWrite} from "../interfaces/IReturnsAggregator.sol";
import {IPauser} from "../interfaces/IPauser.sol";

/// @title Oracle
/// @notice 预言机合约存储共识层状态的离散时间快照记录。这些记录为协议的链上合约提供共识层数据用于会计逻辑。
contract Oracle is Initializable, AccessControlEnumerableUpgradeable, IOracle, IProtocolEvents {
    // ============================================
    // 角色定义
    // ============================================

    /// @notice 预言机管理员角色，可修改合约的可设置属性
    bytes32 public constant ORACLE_MANAGER_ROLE = keccak256("ORACLE_MANAGER_ROLE");

    /// @notice 预言机修改者角色，可修改现有的预言机记录
    bytes32 public constant ORACLE_MODIFIER_ROLE = keccak256("ORACLE_MODIFIER_ROLE");

    /// @notice 待处理更新解决者角色，可批准或替换未通过合理性检查的待处理预言机更新
    bytes32 public constant ORACLE_PENDING_UPDATE_RESOLVER_ROLE = keccak256("ORACLE_PENDING_UPDATE_RESOLVER_ROLE");

    // ============================================
    // 常量
    // ============================================

    /// @notice 完成区块数增量的上限
    uint256 internal constant _FINALIZATION_BLOCK_NUMBER_DELTA_UPPER_BOUND = 2048;

    /// @notice 百万分率 (PPM) 分母
    uint24 internal constant _PPM_DENOMINATOR = 1e6;

    /// @notice 万亿分率 (PPT) 分母
    uint40 internal constant _PPT_DENOMINATOR = 1e12;

    // ============================================
    // 状态变量 - 记录存储
    // ============================================

    /// @notice 存储预言机记录
    /// @dev 不得直接推送，必须使用 `_pushRecord`
    OracleRecord[] internal _records;

    /// @inheritdoc IOracleReadPending
    bool public hasPendingUpdate;

    /// @notice 被 `_sanityCheckUpdate` 拒绝的待处理预言机更新
    /// @dev 如果 `hasPendingUpdate` 为 false，则此值未定义
    OracleRecord internal _pendingUpdate;

    // ============================================
    // 状态变量 - 合约引用
    // ============================================

    /// @notice 允许推送预言机更新的地址
    address public oracleUpdater;

    /// @notice 暂停器合约，在整个协议中保持暂停状态
    IPauser public pauser;

    /// @notice 质押合约，其跟踪的验证者启动数量用于预言机更新的合理性检查
    IStakingInitiationRead public staking;

    /// @notice 聚合器合约，在推送预言机记录时调用以处理返回
    IReturnsAggregatorWrite public aggregator;

    // ============================================
    // 状态变量 - 配置参数
    // ============================================

    /// @notice 在接受预言机更新之前必须经过的区块数，以确保分析期已最终确定
    /// @dev 无法保证共识层的状态，但预期最终确定需要 2 个 epoch
    uint256 public finalizationBlockNumberDelta;

    /// @notice 每个新验证者的最小存款（平均值）
    /// @dev 用于约束报告的已处理存款。尽管预计为 32 ETH，但保留为可配置参数以适应未来变化
    uint256 public minDepositPerValidator;

    /// @notice 每个新验证者的最大存款（平均值）
    /// @dev 用于约束报告的已处理存款。尽管预计为 32 ETH，但保留为可配置参数以适应未来变化
    uint256 public maxDepositPerValidator;

    /// @notice 每个区块的共识层最小收益率（万亿分率 PPT，单位为 1e-12）
    /// @dev 用于约束报告的共识层总余额变化
    uint40 public minConsensusLayerGainPerBlockPPT;

    /// @notice 每个区块的共识层最大收益率（万亿分率 PPT，单位为 1e-12）
    /// @dev 用于约束报告的共识层总余额变化
    uint40 public maxConsensusLayerGainPerBlockPPT;

    /// @notice 共识层最大损失率（百万分率 PPM，单位为 1e-6）
    /// @dev 此值不随时间缩放，表示给定期间的总损失，独立于区块数。涵盖重大罚没事件或链下预言机服务停机期间验证者产生证明惩罚等场景
    uint24 public maxConsensusLayerLossPPM;

    /// @notice 任何报告允许的最小报告大小（区块数）
    /// @dev 此值有助于防御恶意预言机的极端边界检查
    uint16 public minReportSizeBlocks;

    // ============================================
    // 初始化配置
    // ============================================

    /// @notice 合约初始化配置
    struct Init {
        address admin;
        address manager;
        address oracleUpdater;
        address pendingResolver;
        IReturnsAggregatorWrite aggregator;
        IPauser pauser;
        IStakingInitiationRead staking;
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化合约
    /// @dev 必须在合约升级期间调用以设置代理状态
    function initialize(Init memory init) external initializer {
        __AccessControlEnumerable_init();

        // 故意不为 ORACLE_MODIFIER_ROLE 分配地址，以防止在异常情况之外的意外预言机修改
        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(ORACLE_MANAGER_ROLE, init.manager);
        _grantRole(ORACLE_PENDING_UPDATE_RESOLVER_ROLE, init.pendingResolver);

        aggregator = init.aggregator;
        oracleUpdater = init.oracleUpdater;
        pauser = init.pauser;
        staking = init.staking;

        // 假设 2 个 epoch（以区块为单位）
        finalizationBlockNumberDelta = 64;

        minReportSizeBlocks = 100;
        minDepositPerValidator = 32 ether;
        maxDepositPerValidator = 32 ether;

        // 每天 7200 个槽位 * 每年 365 天 = 每年 2628000 个槽位
        // 假设每年 5% 收益
        // 5% / 2628000 = 1.9025e-8
        // 1.9025e-8 每槽位 = 19025 PPT
        maxConsensusLayerGainPerBlockPPT = 190250; // 约10倍估计速率
        minConsensusLayerGainPerBlockPPT = 1903; // 约0.1倍估计速率

        // 基于以下因素选择 0.1% 损失作为协议的下限：
        //
        // - 合理性检查不应在正常运营中失败，我们将正常运营定义为由于验证者离线而产生的证明惩罚。
        //   假设我们所有的验证者都离线，协议预计所有验证者余额在一天内会有 0.03% 的错失证明惩罚。
        // - 对于重大罚没事件（即我们一半的验证者被罚没 1 ETH），我们预计整个协议会下降 1.56%。
        //   这必须触发共识层损失下限。
        maxConsensusLayerLossPPM = 1000;

        // 使用零记录初始化预言机，使所有合约函数（例如 `latestRecord`）按预期工作。
        // 将 updateEndBlock 设置为质押合约初始化时的区块，以便预言机首次计算报告时，
        // 不会检查协议部署之前的区块。那样做会浪费资源，因为我们的系统那时还未运行。
        _pushRecord(OracleRecord(0, uint64(staking.initializationBlockNumber()), 0, 0, 0, 0, 0, 0));
    }

    // ============================================
    // 核心函数 - 接收和处理记录
    // ============================================

    /// @inheritdoc IOracleWrite
    /// @dev 如果更新无效则回滚。如果更新有效但未通过 `_sanityCheckUpdate`，则更新被标记为待处理，
    /// 必须由 `ORACLE_PENDING_UPDATE_RESOLVER_ROLE` 批准或替换。如果更新未通过合理性检查，还会暂停协议。
    /// @param newRecord 要更新到的预言机记录
    function receiveRecord(OracleRecord calldata newRecord) external {
        if (pauser.isSubmitOracleRecordsPaused()) {
            revert Paused();
        }

        if (msg.sender != oracleUpdater) {
            revert UnauthorizedOracleUpdater(msg.sender, oracleUpdater);
        }

        if (hasPendingUpdate) {
            revert CannotUpdateWhileUpdatePending();
        }

        validateUpdate(_records.length - 1, newRecord);

        uint256 updateFinalizingBlock = newRecord.updateEndBlock + finalizationBlockNumberDelta;
        if (block.number < updateFinalizingBlock) {
            revert UpdateEndBlockNumberNotFinal(updateFinalizingBlock);
        }

        (string memory rejectionReason, uint256 value, uint256 bound) = sanityCheckUpdate(latestRecord(), newRecord);
        if (bytes(rejectionReason).length > 0) {
            _pendingUpdate = newRecord;
            hasPendingUpdate = true;
            emit OracleRecordFailedSanityCheck({
                reasonHash: keccak256(bytes(rejectionReason)),
                reason: rejectionReason,
                record: newRecord,
                value: value,
                bound: bound
            });
            // Failing the sanity check will pause the protocol providing the admins time to accept or reject the
            // pending update.
            pauser.pauseAll();
            return;
        }

        _pushRecord(newRecord);
    }

    /// @notice 由于错误或恶意行为修改现有记录的余额。修改最新的预言机记录会影响总控制供应量，从而改变兑换率。
    /// 注意，已经请求解除质押并在队列中的用户不会受到新兑换率的影响。
    /// @dev 此函数只应在预言机发布无效记录的紧急情况下调用，无论是由于计算问题还是（不太可能的）遭到入侵。
    /// 如果新记录报告的窗口收益更高，则需要重新处理差额。如果新记录报告的窗口收益更低，则需要在
    /// consensusLayerReceiver 钱包中补充差额。如果不在 consensusLayerReceiver 钱包中添加缺失的资金，
    /// 此函数将来会回滚。
    /// @param idx 要修改的预言机记录的索引
    /// @param record 将修改现有记录的新预言机记录
    function modifyExistingRecord(uint256 idx, OracleRecord calldata record) external onlyRole(ORACLE_MODIFIER_ROLE) {
        if (idx == 0) {
            revert CannotModifyInitialRecord();
        }

        if (idx >= _records.length) {
            revert RecordDoesNotExist(idx);
        }

        OracleRecord storage existingRecord = _records[idx];
        // Cannot modify the bounds of the record to prevent gaps in the
        // records.
        if (
            existingRecord.updateStartBlock != record.updateStartBlock
                || existingRecord.updateEndBlock != record.updateEndBlock
        ) {
            revert InvalidRecordModification();
        }

        validateUpdate(idx - 1, record);

        // If the new record has a higher windowWithdrawnRewardAmount or windowWithdrawnPrincipalAmount, we need to
        // process the difference. If this is the case, then when we processed the event, we didn't take enough from
        // the consensus layer returns wallet.
        uint256 missingRewards = 0;
        uint256 missingPrincipals = 0;

        if (record.windowWithdrawnRewardAmount > existingRecord.windowWithdrawnRewardAmount) {
            missingRewards = record.windowWithdrawnRewardAmount - existingRecord.windowWithdrawnRewardAmount;
        }
        if (record.windowWithdrawnPrincipalAmount > existingRecord.windowWithdrawnPrincipalAmount) {
            missingPrincipals = record.windowWithdrawnPrincipalAmount - existingRecord.windowWithdrawnPrincipalAmount;
        }

        _records[idx] = record;
        emit OracleRecordModified(idx, record);

        // 将外部调用移到最后以避免任何重入问题
        if (missingRewards > 0 || missingPrincipals > 0) {
            aggregator.processReturns({
                rewardAmount: missingRewards, principalAmount: missingPrincipals, shouldIncludeELRewards: false
            });
        }
    }

    // ============================================
    // 验证函数
    // ============================================

    /// @notice 通过将新预言机记录与前一条记录进行比较，检查新预言机记录在技术上是否有效
    /// @dev 如果预言机记录未通过验证则回滚。这比合理性检查更严格，因为验证逻辑确保我们的预言机不变量保持完整
    /// @param prevRecordIndex 前一条记录的索引
    /// @param newRecord 要验证的预言机记录
    function validateUpdate(uint256 prevRecordIndex, OracleRecord calldata newRecord) public view {
        OracleRecord storage prevRecord = _records[prevRecordIndex];
        if (newRecord.updateEndBlock <= newRecord.updateStartBlock) {
            revert InvalidUpdateEndBeforeStartBlock(newRecord.updateEndBlock, newRecord.updateStartBlock);
        }

        // 确保预言机记录对齐，即确保新记录窗口从前一条记录结束的地方继续
        if (newRecord.updateStartBlock != prevRecord.updateEndBlock + 1) {
            revert InvalidUpdateStartBlock(prevRecord.updateEndBlock + 1, newRecord.updateStartBlock);
        }

        // 确保链下预言机只跟踪来自协议的存款。共识层上已处理的存款最多为协议已存入存款合约的以太币数量
        if (newRecord.cumulativeProcessedDepositAmount > staking.totalDepositedInValidators()) {
            revert InvalidUpdateMoreDepositsProcessedThanSent(
                newRecord.cumulativeProcessedDepositAmount, staking.totalDepositedInValidators()
            );
        }

        if (
            uint256(newRecord.currentNumValidatorsNotWithdrawable)
                    + uint256(newRecord.cumulativeNumValidatorsWithdrawable) > staking.numInitiatedValidators()
        ) {
            revert InvalidUpdateMoreValidatorsThanInitiated(
                newRecord.currentNumValidatorsNotWithdrawable + newRecord.cumulativeNumValidatorsWithdrawable,
                staking.numInitiatedValidators()
            );
        }
    }

    /// @notice 对传入的预言机更新进行合理性检查。如果失败，更新被拒绝并标记为待处理，等待
    /// `ORACLE_PENDING_UPDATE_RESOLVER_ROLE` 批准或替换
    /// @dev 如果记录未通过合理性检查，函数不回滚，因为我们希望将有问题的预言机记录存储在待处理状态
    /// @param newRecord 要检查的传入记录
    /// @return 包含拒绝原因、未通过检查的值和违反的边界的元组。如果更新有效，原因为空字符串
    function sanityCheckUpdate(OracleRecord memory prevRecord, OracleRecord calldata newRecord)
        public
        view
        returns (string memory, uint256, uint256)
    {
        uint64 reportSize = newRecord.updateEndBlock - newRecord.updateStartBlock + 1;
        {
            // 报告大小检查：
            // 实现为合理性检查而非验证，因为报告在技术上有效，可能在某些时候有接受小报告的合理理由
            if (reportSize < minReportSizeBlocks) {
                return ("Report blocks below minimum bound", reportSize, minReportSizeBlocks);
            }
        }
        {
            // 验证者数量检查：
            // 检查验证者总数和处于可提款状态的验证者数量在新预言机期间没有减少
            if (newRecord.cumulativeNumValidatorsWithdrawable < prevRecord.cumulativeNumValidatorsWithdrawable) {
                return (
                    "Cumulative number of withdrawable validators decreased",
                    newRecord.cumulativeNumValidatorsWithdrawable,
                    prevRecord.cumulativeNumValidatorsWithdrawable
                );
            }
            {
                uint256 prevNumValidators =
                    prevRecord.currentNumValidatorsNotWithdrawable + prevRecord.cumulativeNumValidatorsWithdrawable;
                uint256 newNumValidators =
                    newRecord.currentNumValidatorsNotWithdrawable + newRecord.cumulativeNumValidatorsWithdrawable;

                if (newNumValidators < prevNumValidators) {
                    return ("Total number of validators decreased", newNumValidators, prevNumValidators);
                }
            }
        }

        {
            // 存款检查：
            // 检查预言机处理的存款总额在新预言机期间没有减少。
            // 还检查新存入的 ETH 数量是否与我们在新期间包含的验证者数量一致
            if (newRecord.cumulativeProcessedDepositAmount < prevRecord.cumulativeProcessedDepositAmount) {
                return (
                    "Processed deposit amount decreased",
                    newRecord.cumulativeProcessedDepositAmount,
                    prevRecord.cumulativeProcessedDepositAmount
                );
            }

            uint256 newDeposits =
                (newRecord.cumulativeProcessedDepositAmount - prevRecord.cumulativeProcessedDepositAmount);
            uint256 newValidators = (newRecord.currentNumValidatorsNotWithdrawable
                    + newRecord.cumulativeNumValidatorsWithdrawable - prevRecord.currentNumValidatorsNotWithdrawable
                    - prevRecord.cumulativeNumValidatorsWithdrawable);

            if (newDeposits < newValidators * minDepositPerValidator) {
                return
                    (
                        "New deposits below min deposit per validator",
                        newDeposits,
                        newValidators * minDepositPerValidator
                    );
            }

            if (newDeposits > newValidators * maxDepositPerValidator) {
                return
                    (
                        "New deposits above max deposit per validator",
                        newDeposits,
                        newValidators * maxDepositPerValidator
                    );
            }
        }

        {
            // 共识层余额变化检查：
            // 检查共识层余额的变化是否在最大损失和最小收益参数给定的范围内。
            // 例如，重大罚没事件会导致共识层出现超出边界的损失

            // baselineGrossCLBalance 表示在新期间内，假设没有罚没、没有奖励等情况下，
            // 验证者余额的预期增长。它用作上限（增长）和下限（损失）计算的基准
            uint256 baselineGrossCLBalance = prevRecord.currentTotalValidatorBalance
                + (newRecord.cumulativeProcessedDepositAmount - prevRecord.cumulativeProcessedDepositAmount);

            // newGrossCLBalance 是我们在新记录期间在共识层中记录的 ETH 实际数量
            uint256 newGrossCLBalance = newRecord.currentTotalValidatorBalance
                + newRecord.windowWithdrawnPrincipalAmount + newRecord.windowWithdrawnRewardAmount;

            {
                // 共识层上 ETH 净减少的相对下限
                // 根据参数，损失项可能完全主导 minGain 项
                //
                // 使用大于 0 的 minConsensusLayerGainPerBlockPPT，下限成为向上的斜率
                // 设置 minConsensusLayerGainPerBlockPPT，下限成为常量
                uint256 lowerBound = baselineGrossCLBalance
                    - Math.mulDiv(maxConsensusLayerLossPPM, baselineGrossCLBalance, _PPM_DENOMINATOR)
                    + Math.mulDiv(
                        minConsensusLayerGainPerBlockPPT * reportSize, baselineGrossCLBalance, _PPT_DENOMINATOR
                    );

                if (newGrossCLBalance < lowerBound) {
                    return ("Consensus layer change below min gain or max loss", newGrossCLBalance, lowerBound);
                }
            }
            {
                // 验证者产生的奖励上限，随时间和活跃验证者数量线性缩放
                uint256 upperBound = baselineGrossCLBalance
                    + Math.mulDiv(
                        maxConsensusLayerGainPerBlockPPT * reportSize, baselineGrossCLBalance, _PPT_DENOMINATOR
                    );

                if (newGrossCLBalance > upperBound) {
                    return ("Consensus layer change above max gain", newGrossCLBalance, upperBound);
                }
            }
        }

        return ("", 0, 0);
    }

    // ============================================
    // 内部函数
    // ============================================

    /// @dev 将记录推送到记录列表，发出预言机添加事件，并在聚合器中处理预言机记录
    /// @param record 要推送的记录
    function _pushRecord(OracleRecord memory record) internal {
        emit OracleRecordAdded(_records.length, record);
        _records.push(record);

        aggregator.processReturns({
            rewardAmount: record.windowWithdrawnRewardAmount,
            principalAmount: record.windowWithdrawnPrincipalAmount,
            shouldIncludeELRewards: true
        });
    }

    /// @dev 通过从存储中删除更新并重置 hasPendingUpdate 标志来重置待处理更新
    function _resetPending() internal {
        delete _pendingUpdate;
        hasPendingUpdate = false;
    }

    // ============================================
    // 待处理更新管理
    // ============================================

    /// @notice 接受当前待处理的更新并将其添加到预言机记录列表
    /// @dev 接受当前待处理的更新会重置更新待处理状态
    function acceptPendingUpdate() external onlyRole(ORACLE_PENDING_UPDATE_RESOLVER_ROLE) {
        if (!hasPendingUpdate) {
            revert NoUpdatePending();
        }

        _pushRecord(_pendingUpdate);
        _resetPending();
    }

    /// @notice 拒绝当前待处理的更新
    /// @dev 拒绝当前待处理的更新会重置待处理状态
    function rejectPendingUpdate() external onlyRole(ORACLE_PENDING_UPDATE_RESOLVER_ROLE) {
        if (!hasPendingUpdate) {
            revert NoUpdatePending();
        }

        emit OraclePendingUpdateRejected(_pendingUpdate);
        _resetPending();
    }

    // ============================================
    // 查询函数
    // ============================================

    /// @inheritdoc IOracleReadRecord
    function latestRecord() public view returns (OracleRecord memory) {
        return _records[_records.length - 1];
    }

    /// @inheritdoc IOracleReadPending
    function pendingUpdate() external view returns (OracleRecord memory) {
        if (!hasPendingUpdate) {
            revert NoUpdatePending();
        }
        return _pendingUpdate;
    }

    /// @inheritdoc IOracleReadRecord
    function recordAt(uint256 idx) external view returns (OracleRecord memory) {
        return _records[idx];
    }

    /// @inheritdoc IOracleReadRecord
    function numRecords() external view returns (uint256) {
        return _records.length;
    }

    // ============================================
    // 管理函数 - 参数设置
    // ============================================

    /// @notice 设置合约中的完成区块数增量
    /// @dev 参见 {finalizationBlockNumberDelta}
    /// @param finalizationBlockNumberDelta_ 新的完成区块数增量
    function setFinalizationBlockNumberDelta(uint256 finalizationBlockNumberDelta_)
        external
        onlyRole(ORACLE_MANAGER_ROLE)
    {
        if (
            finalizationBlockNumberDelta_ == 0
                || finalizationBlockNumberDelta_ > _FINALIZATION_BLOCK_NUMBER_DELTA_UPPER_BOUND
        ) {
            revert InvalidConfiguration();
        }

        finalizationBlockNumberDelta = finalizationBlockNumberDelta_;
        emit ProtocolConfigChanged(
            this.setFinalizationBlockNumberDelta.selector,
            "setFinalizationBlockNumberDelta(uint256)",
            abi.encode(finalizationBlockNumberDelta_)
        );
    }

    /// @inheritdoc IOracleManager
    /// @dev 参见 {oracleUpdater}
    function setOracleUpdater(address newUpdater) external onlyRole(ORACLE_MANAGER_ROLE) notZeroAddress(newUpdater) {
        oracleUpdater = newUpdater;
        emit ProtocolConfigChanged(this.setOracleUpdater.selector, "setOracleUpdater(address)", abi.encode(newUpdater));
    }

    /// @notice 设置合约中的每个验证者最小存款
    /// @dev 参见 {minDepositPerValidator}
    /// @param minDepositPerValidator_ 新的每个验证者最小存款
    function setMinDepositPerValidator(uint256 minDepositPerValidator_) external onlyRole(ORACLE_MANAGER_ROLE) {
        minDepositPerValidator = minDepositPerValidator_;
        emit ProtocolConfigChanged(
            this.setMinDepositPerValidator.selector,
            "setMinDepositPerValidator(uint256)",
            abi.encode(minDepositPerValidator_)
        );
    }

    /// @notice 设置合约中的每个验证者最大存款
    /// @dev 参见 {maxDepositPerValidator}
    /// @param maxDepositPerValidator_ 新的每个验证者最大存款
    function setMaxDepositPerValidator(uint256 maxDepositPerValidator_) external onlyRole(ORACLE_MANAGER_ROLE) {
        maxDepositPerValidator = maxDepositPerValidator_;
        emit ProtocolConfigChanged(
            this.setMaxDepositPerValidator.selector,
            "setMaxDepositPerValidator(uint256)",
            abi.encode(maxDepositPerValidator)
        );
    }

    /// @notice 设置合约中的每个区块共识层最小收益
    /// @dev 参见 {minConsensusLayerGainPerBlockPPT}
    /// @param minConsensusLayerGainPerBlockPPT_ 新的每个区块共识层最小收益（万亿分率）
    function setMinConsensusLayerGainPerBlockPPT(uint40 minConsensusLayerGainPerBlockPPT_)
        external
        onlyRole(ORACLE_MANAGER_ROLE)
        onlyFractionLeqOne(minConsensusLayerGainPerBlockPPT_, _PPT_DENOMINATOR)
    {
        minConsensusLayerGainPerBlockPPT = minConsensusLayerGainPerBlockPPT_;
        emit ProtocolConfigChanged(
            this.setMinConsensusLayerGainPerBlockPPT.selector,
            "setMinConsensusLayerGainPerBlockPPT(uint40)",
            abi.encode(minConsensusLayerGainPerBlockPPT_)
        );
    }

    /// @notice 设置合约中的每个区块共识层最大收益
    /// @dev 参见 {maxConsensusLayerGainPerBlockPPT}
    /// @param maxConsensusLayerGainPerBlockPPT_ 新的每个区块共识层最大收益（万亿分率）
    function setMaxConsensusLayerGainPerBlockPPT(uint40 maxConsensusLayerGainPerBlockPPT_)
        external
        onlyRole(ORACLE_MANAGER_ROLE)
        onlyFractionLeqOne(maxConsensusLayerGainPerBlockPPT_, _PPT_DENOMINATOR)
    {
        maxConsensusLayerGainPerBlockPPT = maxConsensusLayerGainPerBlockPPT_;
        emit ProtocolConfigChanged(
            this.setMaxConsensusLayerGainPerBlockPPT.selector,
            "setMaxConsensusLayerGainPerBlockPPT(uint40)",
            abi.encode(maxConsensusLayerGainPerBlockPPT_)
        );
    }

    /// @notice 设置合约中的每个区块共识层最大损失
    /// @dev 参见 {maxConsensusLayerLossPPM}
    /// @param maxConsensusLayerLossPPM_ 新的每个区块共识层最大损失（百万分率）
    function setMaxConsensusLayerLossPPM(uint24 maxConsensusLayerLossPPM_)
        external
        onlyRole(ORACLE_MANAGER_ROLE)
        onlyFractionLeqOne(maxConsensusLayerLossPPM_, _PPM_DENOMINATOR)
    {
        maxConsensusLayerLossPPM = maxConsensusLayerLossPPM_;
        emit ProtocolConfigChanged(
            this.setMaxConsensusLayerLossPPM.selector,
            "setMaxConsensusLayerLossPPM(uint24)",
            abi.encode(maxConsensusLayerLossPPM_)
        );
    }

    /// @notice 设置最小报告大小
    /// @dev 参见 {minReportSizeBlocks}
    /// @param minReportSizeBlocks_ 新的最小报告大小（区块数）
    function setMinReportSizeBlocks(uint16 minReportSizeBlocks_) external onlyRole(ORACLE_MANAGER_ROLE) {
        minReportSizeBlocks = minReportSizeBlocks_;
        emit ProtocolConfigChanged(
            this.setMinReportSizeBlocks.selector, "setMinReportSizeBlocks(uint16)", abi.encode(minReportSizeBlocks_)
        );
    }

    // ============================================
    // 修饰符
    // ============================================

    /// @notice 确保给定的分数小于或等于一
    /// @param numerator 分数的分子
    /// @param denominator 分数的分母
    modifier onlyFractionLeqOne(uint256 numerator, uint256 denominator) {
        if (numerator > denominator) {
            revert InvalidConfiguration();
        }
        _;
    }

    /// @notice 确保给定的地址不是零地址
    /// @param addr 要检查的地址
    modifier notZeroAddress(address addr) {
        if (addr == address(0)) {
            revert ZeroAddress();
        }
        _;
    }
}
