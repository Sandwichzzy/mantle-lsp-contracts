// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice 预言机合约存储的记录，通知协议有关共识层活动的信息。它由链下预言机服务计算和报告。
/// @dev "current" 数量是指 `updateEndBlock` 区块号时的状态。
/// @dev "cumulative" 数量是指截至 `updateEndBlock` 区块号的累计值。
/// @dev "window" 数量是指在 `updateStartBlock` 和 `updateEndBlock` 之间的区块窗口内的累计值。
/// @param updateStartBlock 预言机记录区块窗口的起始块。这应该比前一个预言机记录的 updateEndBlock 高 1。
/// @param updateEndBlock 计算此预言机记录所基于的区块号（包含该区块）。
/// @param currentNumValidatorsNotWithdrawable 没有可提款状态的验证者数量。
/// @param cumulativeNumValidatorsWithdrawable 具有可提款状态的验证者总数。
/// 这些验证者的状态为 `withdrawal_possible` 或 `withdrawal_done`。注意：由于充值，验证者可能在这两种状态之间波动。
/// @param windowWithdrawnPrincipalAmount 在分析的区块窗口内从共识层提取的本金数量。
/// @param windowWithdrawnRewardAmount 在分析的区块窗口内从共识层提取的奖励数量。
/// @param currentTotalValidatorBalance 共识层中的 ETH 总量（即所有验证者余额之和）。这是计算协议控制的总价值的主要数量之一。
/// @param cumulativeProcessedDepositAmount 已存入共识层并被处理的 ETH 总量。这用于防止重复计算存入共识层的 ETH。
struct OracleRecord {
    uint64 updateStartBlock;
    uint64 updateEndBlock;
    uint64 currentNumValidatorsNotWithdrawable;
    uint64 cumulativeNumValidatorsWithdrawable;
    uint128 windowWithdrawnPrincipalAmount;
    uint128 windowWithdrawnRewardAmount;
    uint128 currentTotalValidatorBalance;
    uint128 cumulativeProcessedDepositAmount;
}

interface IOracleWrite {
    /// @notice 向预言机推送新记录。
    function receiveRecord(OracleRecord calldata record) external;
}

interface IOracleReadRecord {
    /// @notice 返回最新的已验证记录。
    /// @return `OracleRecord` 最新的已验证记录。
    function latestRecord() external view returns (OracleRecord calldata);

    /// @notice 返回给定索引处的记录。
    /// @param idx 要检索的记录索引。
    /// @return `OracleRecord` 给定索引处的记录。
    function recordAt(uint256 idx) external view returns (OracleRecord calldata);

    /// @notice 返回预言机中的记录数量。
    /// @return `uint256` 预言机中的记录数量。
    function numRecords() external view returns (uint256);
}

interface IOracleReadPending {
    /// @notice 返回待处理的更新。
    /// @return `OracleRecord` 待处理的更新。
    function pendingUpdate() external view returns (OracleRecord calldata);

    /// @notice 指示是否有预言机更新待处理，即它是否被 `_sanityCheckUpdate` 拒绝。
    function hasPendingUpdate() external view returns (bool);
}

interface IOracleRead is IOracleReadRecord, IOracleReadPending {}

interface IOracleManager {
    /// @notice 为合约设置新的预言机更新者。
    /// @param newUpdater 新的预言机更新者地址。
    function setOracleUpdater(address newUpdater) external;
}

interface IOracle is IOracleWrite, IOracleRead, IOracleManager {
    /// @notice Emitted when a new oracle record was added to the list of oracle records. A pending record will only
    /// emit this event if it was accepted by the admin.
    /// @param index The index of the new record.
    /// @param record The new record that was added to the list.
    event OracleRecordAdded(uint256 indexed index, OracleRecord record);

    /// @notice Emitted when a record has been modified.
    /// @param index The index of the record that was modified.
    /// @param record The newly modified record.
    event OracleRecordModified(uint256 indexed index, OracleRecord record);

    /// @notice Emitted when a pending update has been rejected.
    /// @param pendingUpdate The rejected pending update.
    event OraclePendingUpdateRejected(OracleRecord pendingUpdate);

    /// @notice Emitted when the oracle's record did not pass a sanity check.
    /// @param reasonHash The hash of the reason for the record rejection.
    /// @param reason The reason for the record rejection.
    /// @param record The record that was rejected.
    /// @param value The value that violated a bound.
    /// @param bound The bound of the rejected update.
    event OracleRecordFailedSanityCheck(
        bytes32 indexed reasonHash, string reason, OracleRecord record, uint256 value, uint256 bound
    );

    // Errors.
    error CannotUpdateWhileUpdatePending();
    error CannotModifyInitialRecord();
    error InvalidConfiguration();
    error InvalidRecordModification();
    error InvalidUpdateStartBlock(uint256 wantUpdateStartBlock, uint256 gotUpdateStartBlock);
    error InvalidUpdateEndBeforeStartBlock(uint256 end, uint256 start);
    error InvalidUpdateMoreDepositsProcessedThanSent(uint256 processed, uint256 sent);
    error InvalidUpdateMoreValidatorsThanInitiated(uint256 numValidatorsOnRecord, uint256 numInitiatedValidators);
    error NoUpdatePending();
    error Paused();
    error RecordDoesNotExist(uint256 idx);
    error UnauthorizedOracleUpdater(address sender, address oracleUpdater);
    error UpdateEndBlockNumberNotFinal(uint256 updateFinalizingBlock);
    error ZeroAddress();
}
