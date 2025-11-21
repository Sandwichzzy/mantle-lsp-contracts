// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IStakingInitiationRead {
    /// @notice 发送到信标链存款合约的 ETH 总量。
    function totalDepositedInValidators() external view returns (uint256);
    /// @notice 由质押合约发起的验证者数量。
    function numInitiatedValidators() external view returns (uint256);
    /// @notice 质押合约初始化的区块号。
    function initializationBlockNumber() external view returns (uint256);
}

interface IStakingReturnsWrite {
    /// @notice 接收收益聚合器发送的资金。
    function receiveReturns() external payable;

    /// @notice 接收解除质押请求管理器发送的资金。
    function receiveFromUnstakeRequestsManager() external payable;

    /// @notice 接收流动性缓冲池发送的收益。
    function receiveReturnsFromLiquidityBuffer() external payable;

    /// @notice 为质押合约充值。
    function topUp() external payable;
}

interface IStaking is IStakingInitiationRead, IStakingReturnsWrite {
    /// @notice 当用户质押 ETH 并收到 mETH 时触发。
    /// @param staker 质押 ETH 的用户地址。
    /// @param ethAmount 质押的 ETH 数量。
    /// @param mETHAmount 收到的 mETH 数量。
    event Staked(address indexed staker, uint256 ethAmount, uint256 mETHAmount);

    /// @notice 当用户用 mETH 换取 ETH 时触发。
    /// @param id 解除质押请求的 ID。
    /// @param staker 解除质押的用户地址。
    /// @param ethAmount 质押者将收到的 ETH 数量。
    /// @param mETHLocked 将被销毁的 mETH 数量。
    event UnstakeRequested(uint256 indexed id, address indexed staker, uint256 ethAmount, uint256 mETHLocked);

    /// @notice 当用户索赔其解除质押请求时触发。
    /// @param id 解除质押请求的 ID。
    /// @param staker 索赔其解除质押请求的用户地址。
    event UnstakeRequestClaimed(uint256 indexed id, address indexed staker);

    /// @notice 当验证者已被发起时触发（即协议已存入存款合约）。
    /// @param id 验证者的 ID，即其公钥的哈希值。
    /// @param operatorID 验证者所属的节点运营商的 ID。
    /// @param pubkey 验证者的公钥。
    /// @param amountDeposited 为该验证者存入存款合约的 ETH 数量。
    event ValidatorInitiated(bytes32 indexed id, uint256 indexed operatorID, bytes pubkey, uint256 amountDeposited);

    /// @notice 当协议已将 ETH 分配给解除质押请求管理器时触发。
    /// @param amount 分配给解除质押请求管理器的 ETH 数量。
    event AllocatedETHToUnstakeRequestsManager(uint256 amount);

    /// @notice 当协议已将 ETH 分配用于存款合约的存款时触发。
    /// @param amount 分配给存款的 ETH 数量。
    event AllocatedETHToDeposits(uint256 amount);

    /// @notice 当协议已从收益聚合器收到收益时触发。
    /// @param amount 收到的 ETH 数量。
    event ReturnsReceived(uint256 amount);

    /// @notice 当协议已从流动性缓冲池收到收益时触发。
    /// @param amount 收到的 ETH 数量。
    event ReturnsReceivedFromLiquidityBuffer(uint256 amount);

    /// @notice 当协议已将 ETH 分配给流动性缓冲池时触发。
    /// @param amount 分配给流动性缓冲池的 ETH 数量。
    event AllocatedETHToLiquidityBuffer(uint256 amount);

    //error
    error DoesNotReceiveETH();
    error InvalidConfiguration();
    error MaximumValidatorDepositExceeded();
    error MaximumMETHSupplyExceeded();
    error MinimumStakeBoundNotSatisfied();
    error MinimumUnstakeBoundNotSatisfied();
    error MinimumValidatorDepositNotSatisfied();
    error NotEnoughDepositETH();
    error NotEnoughUnallocatedETH();
    error NotReturnsAggregator();
    error NotLiquidityBuffer();
    error NotUnstakeRequestsManager();
    error Paused();
    error PreviouslyUsedValidator();
    error ZeroAddress();
    error InvalidDepositRoot(bytes32);
    error StakeBelowMinimumMETHAmount(uint256 methAmount, uint256 expectedMinimum);
    error UnstakeBelowMinimumETHAmount(uint256 ethAmount, uint256 expectedMinimum);

    error InvalidWithdrawalCredentialsWrongLength(uint256);
    error InvalidWithdrawalCredentialsNotETH1(bytes12);
    error InvalidWithdrawalCredentialsWrongAddress(address);
}
