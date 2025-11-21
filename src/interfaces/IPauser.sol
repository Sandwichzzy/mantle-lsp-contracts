// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPauserRead {
    /// @notice 标识质押是否已暂停的标志。
    function isStakingPaused() external view returns (bool);

    /// @notice 标识解除质押请求和索赔是否已暂停的标志。
    function isUnstakeRequestsAndClaimsPaused() external view returns (bool);

    /// @notice 标识初始化验证者是否已暂停的标志。
    function isInitiateValidatorsPaused() external view returns (bool);

    /// @notice 标识提交预言机记录是否已暂停的标志。
    function isSubmitOracleRecordsPaused() external view returns (bool);

    /// @notice 标识分配 ETH 是否已暂停的标志。
    function isAllocateETHPaused() external view returns (bool);

    /// @notice 标识流动性缓冲池是否已暂停的标志。
    function isLiquidityBufferPaused() external view returns (bool);
}

interface IPauserWrite {
    /// @notice 暂停所有操作。
    function pauseAll() external;
}

interface IPauser is IPauserRead, IPauserWrite {
    /// @notice 当标志被更新时触发。
    /// @param selector 被更新标志的选择器。
    /// @param isPaused 标志的新值。
    /// @param flagName 被更新标志的名称。
    event FlagUpdated(bytes4 indexed selector, bool indexed isPaused, string flagName);

    // 错误定义。
    error PauserRoleOrOracleRequired(address sender);
}
