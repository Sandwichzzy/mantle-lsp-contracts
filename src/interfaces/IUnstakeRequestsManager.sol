// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Staking} from "../Core/Staking.sol";

/// @notice 解除质押请求存储在 UnstakeRequestsManager 中，记录完成解除质押请求索赔所需的信息。
/// @param id 解除质押请求的唯一 ID。
/// @param requester 请求解除质押的用户地址。
/// @param mETHLocked 创建解除质押请求时锁定的 mETH 数量。一旦请求被索赔，mETH 将被销毁。
/// @param ethRequested 创建解除质押请求时请求的 ETH 数量。
/// @param cumulativeETHRequested 此请求及其之前所有解除质押请求中请求的 ETH 累计数量。
/// @param blockNumber 创建解除质押请求的区块号。
struct UnstakeRequest {
    uint64 blockNumber;
    address requester;
    uint128 id;
    uint128 mETHLocked;
    uint128 ethRequested;
    uint128 cumulativeETHRequested;
}

interface IUnstakeRequestsManagerWrite {
    /// @notice 创建新的解除质押请求并将其添加到解除质押请求数组。
    /// @param requester 发起解除质押请求的实体地址。
    /// @param mETHLocked 当前在合约中锁定的 mETH 代币数量。
    /// @param ethRequested 请求解除质押的 ETH 数量。
    /// @return 新解除质押请求的 ID。
    function create(address requester, uint128 mETHLocked, uint128 ethRequested) external returns (uint256);

    /// @notice 允许请求者在请求完成后索赔其解除质押请求。
    /// @param requestID 要索赔的解除质押请求的 ID。
    /// @param requester 索赔解除质押请求的实体地址。
    function claim(uint256 requestID, address requester) external;

    /// @notice 取消一批最新的未完成解除质押请求。
    /// @param maxCancel 要取消的最大请求数。
    /// @return 指示是否有更多解除质押请求需要取消的布尔值。
    function cancelUnfinalizedRequests(uint256 maxCancel) external returns (bool);

    /// @notice 向合约分配以太币。
    function allocateETH() external payable;

    /// @notice 从 allocatedETHForClaims 中提取多余的 ETH。
    function withdrawAllocatedETHSurplus() external;
}

interface IUnstakeRequestsManagerRead {
    /// @notice 根据 ID 检索特定的解除质押请求。
    /// @param requestID 要获取的解除质押请求的 ID。
    /// @return 给定 ID 对应的 UnstakeRequest 结构体。
    function requestByID(uint256 requestID) external view returns (UnstakeRequest memory);

    /// @notice 返回请求的状态，包括是否已完成以及已填充了多少 ETH。
    /// @param requestID 解除质押请求的 ID。
    /// @return 指示请求是否已完成的布尔值，以及已填充的 ETH 数量。
    function requestInfo(uint256 requestID) external view returns (bool, uint256);

    /// @notice 计算合约中分配的超过支付未claim所需总额的以太币数量。
    /// @return 多余的 allocatedETH 数量。
    function allocatedETHSurplus() external view returns (uint256);

    /// @notice 计算完成解除质押请求所需的以太币数量。
    /// @return allocatedETH 不足的数量。
    function allocatedETHDeficit() external view returns (uint256);

    /// @notice 计算已分配但尚未被索赔的以太币数量。
    /// @return 等待被索赔的以太币总量。
    function balance() external view returns (uint256);
}

interface IUnstakeRequestsManager is IUnstakeRequestsManagerRead, IUnstakeRequestsManagerWrite {
    /// @notice Created emitted when an unstake request has been created.
    /// @param id The id of the unstake request.
    /// @param requester The address of the user who requested to unstake.
    /// @param mETHLocked The amount of mETH that will be burned when the request is claimed.
    /// @param ethRequested The amount of ETH that will be returned to the requester.
    /// @param cumulativeETHRequested The cumulative amount of ETH requested at the time of the unstake request.
    /// @param blockNumber The block number at the point at which the request was created.
    event UnstakeRequestCreated(
        uint256 indexed id,
        address indexed requester,
        uint256 mETHLocked,
        uint256 ethRequested,
        uint256 cumulativeETHRequested,
        uint256 blockNumber
    );

    /// @notice Claimed emitted when an unstake request has been claimed.
    /// @param id The id of the unstake request.
    /// @param requester The address of the user who requested to unstake.
    /// @param mETHLocked The amount of mETH that will be burned when the request is claimed.
    /// @param ethRequested The amount of ETH that will be returned to the requester.
    /// @param cumulativeETHRequested The cumulative amount of ETH requested at the time of the unstake request.
    /// @param blockNumber The block number at the point at which the request was created.
    event UnstakeRequestClaimed(
        uint256 indexed id,
        address indexed requester,
        uint256 mETHLocked,
        uint256 ethRequested,
        uint256 cumulativeETHRequested,
        uint256 blockNumber
    );

    /// @notice Cancelled emitted when an unstake request has been cancelled by an admin.
    /// @param id The id of the unstake request.
    /// @param requester The address of the user who requested to unstake.
    /// @param mETHLocked The amount of mETH that will be burned when the request is claimed.
    /// @param ethRequested The amount of ETH that will be returned to the requester.
    /// @param cumulativeETHRequested The cumulative amount of ETH requested at the time of the unstake request.
    /// @param blockNumber The block number at the point at which the request was created.
    event UnstakeRequestCancelled(
        uint256 indexed id,
        address indexed requester,
        uint256 mETHLocked,
        uint256 ethRequested,
        uint256 cumulativeETHRequested,
        uint256 blockNumber
    );

    // ============================================
    // errors
    // ============================================
    error AlreadyClaimed();
    error DoesNotReceiveETH();
    error NotEnoughFunds(uint256 cumulativeETHOnRequest, uint256 allocatedETHForClaims);
    error NotFinalized();
    error NotRequester();
    error NotStakingContract();
}
