// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IProtocolEvents} from "../interfaces/IProtocolEvents.sol";
import {IMETH} from "../interfaces/IMETH.sol";
import {IOracleReadRecord} from "../interfaces/IOracle.sol";
import {
    IUnstakeRequestsManager,
    IUnstakeRequestsManagerWrite,
    IUnstakeRequestsManagerRead,
    UnstakeRequest
} from "../interfaces/IUnstakeRequestsManager.sol";
import {IStakingReturnsWrite} from "../interfaces/IStaking.sol";

/// @title 解除质押请求管理器
/// @notice 管理来自质押合约的解除质押请求队列
/// @dev 核心功能：
/// 1. 创建请求（锁定 mETH）
/// 2. 等待完成条件（区块数 + 资金分配）
/// 3. claim请求（销毁 mETH，发送 ETH）
/// 4. 紧急取消未完成的请求
contract UnstakeRequestsManager is
    Initializable,
    AccessControlEnumerableUpgradeable,
    IUnstakeRequestsManager,
    IProtocolEvents
{
    // ============================================
    // roles
    // ============================================

    /// @notice 管理员角色，可设置合约参数
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @notice 请求取消者角色，可在紧急状态下取消未完成的请求
    bytes32 public constant REQUEST_CANCELLER_ROLE = keccak256("REQUEST_CANCELLER_ROLE");

    // ============================================
    // 状态变量
    // ============================================

    /// @notice 质押合约地址，唯一可创建和claim请求的合约
    IStakingReturnsWrite public stakingContract;

    /// @notice 预言机合约，用于判断请求完成条件
    IOracleReadRecord public oracle;

    /// @notice 已分配用于claim的 ETH 总量
    uint256 public allocatedETHForClaims;

    /// @notice 已被用户claim的 ETH 总量
    uint256 public totalClaimed;

    /// @notice 请求完成所需的区块数
    /// @dev 请求区块号 + 此值 ≤ 预言机最新记录区块号 = 请求已完成
    uint256 public numberOfBlocksToFinalize;

    /// @notice mETH 代币合约
    IMETH public mETH;

    /// @notice 缓存最新的累计 ETH 请求量
    /// @dev 避免在数组最后元素被claim后访问无效值
    uint128 public latestCumulativeETHRequested;

    /// @notice 解除质押请求队列
    UnstakeRequest[] internal _unstakeRequests;

    // ============================================
    // initialization
    // ============================================

    struct Init {
        address admin;
        address manager;
        address requestCanceller;
        IMETH mETH;
        IStakingReturnsWrite stakingContract;
        IOracleReadRecord oracle;
        uint256 numberOfBlocksToFinalize;
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化合约
    function initialize(Init memory init) external initializer {
        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(MANAGER_ROLE, init.manager);
        _grantRole(REQUEST_CANCELLER_ROLE, init.requestCanceller);

        numberOfBlocksToFinalize = init.numberOfBlocksToFinalize;
        stakingContract = init.stakingContract;
        oracle = init.oracle;
        mETH = init.mETH;
    }

    // ============================================
    // core functions
    // ============================================

    /// @inheritdoc IUnstakeRequestsManagerWrite
    /// @dev 创建新的解除质押请求，增加累计 ETH 请求量
    function create(address requester, uint128 mETHLocked, uint128 ethRequested)
        external
        onlyStakingContract
        returns (uint256)
    {
        uint128 currentCumulativeETHRequested = latestCumulativeETHRequested + ethRequested;
        uint256 requestID = _unstakeRequests.length;

        UnstakeRequest memory unstakeRequest = UnstakeRequest({
            id: uint128(requestID),
            requester: requester,
            mETHLocked: mETHLocked,
            ethRequested: ethRequested,
            cumulativeETHRequested: currentCumulativeETHRequested,
            blockNumber: uint64(block.number)
        });

        _unstakeRequests.push(unstakeRequest);
        latestCumulativeETHRequested = currentCumulativeETHRequested;

        emit UnstakeRequestCreated(
            requestID, requester, mETHLocked, ethRequested, currentCumulativeETHRequested, block.number
        );

        return requestID;
    }

    /// @inheritdoc IUnstakeRequestsManagerWrite
    /// @dev claim步骤：
    /// 1. 验证请求者身份
    /// 2. 验证请求已完成
    /// 3. 验证资金充足
    /// 4. 删除请求记录
    /// 5. 销毁锁定的 mETH
    /// 6. 发送 ETH 给请求者
    function claim(uint256 requestID, address requester) external onlyStakingContract {
        UnstakeRequest memory request = _unstakeRequests[requestID];

        if (request.requester == address(0)) {
            revert AlreadyClaimed();
        }

        if (requester != request.requester) {
            revert NotRequester();
        }

        if (!_isFinalized(request)) {
            revert NotFinalized();
        }

        if (request.cumulativeETHRequested > allocatedETHForClaims) {
            revert NotEnoughFunds(request.cumulativeETHRequested, allocatedETHForClaims);
        }
        //先删除要提现的交易
        delete _unstakeRequests[requestID];
        totalClaimed += request.ethRequested;

        emit UnstakeRequestClaimed({
            id: requestID,
            requester: requester,
            mETHLocked: request.mETHLocked,
            ethRequested: request.ethRequested,
            cumulativeETHRequested: request.cumulativeETHRequested,
            blockNumber: request.blockNumber
        });

        // 销毁锁定的 mETH（在此处而非解除质押时销毁的原因见文档）
        mETH.burn(request.mETHLocked);
        //将用户要体现的ETH发送给用户
        Address.sendValue(payable(requester), request.ethRequested);
    }

    /// @inheritdoc IUnstakeRequestsManagerWrite
    /// @dev 从队列尾部迭代取消未完成的请求，直到遇到已完成的请求或达到最大取消数量
    function cancelUnfinalizedRequests(uint256 maxCancel) external onlyRole(REQUEST_CANCELLER_ROLE) returns (bool) {
        uint256 length = _unstakeRequests.length;
        if (length == 0) {
            return false;
        }

        if (length < maxCancel) {
            maxCancel = length;
        }

        // 缓存所有被取消的请求，遵循 checks-effects-interactions 模式
        UnstakeRequest[] memory requests = new UnstakeRequest[](maxCancel);

        uint256 numCancelled = 0;
        uint128 amountETHCancelled = 0;

        while (numCancelled < maxCancel) {
            UnstakeRequest memory request = _unstakeRequests[_unstakeRequests.length - 1];

            if (_isFinalized(request)) {
                break;
            }

            _unstakeRequests.pop();
            requests[numCancelled] = request;
            ++numCancelled;
            amountETHCancelled += request.ethRequested;

            emit UnstakeRequestCancelled(
                request.id,
                request.requester,
                request.mETHLocked,
                request.ethRequested,
                request.cumulativeETHRequested,
                request.blockNumber
            );
        }

        // 重置累计 ETH 状态
        if (amountETHCancelled > 0) {
            latestCumulativeETHRequested -= amountETHCancelled;
        }

        // 检查是否还有更多未完成的请求需要取消
        bool hasMore;
        uint256 remainingRequestsLength = _unstakeRequests.length;
        if (remainingRequestsLength == 0) {
            hasMore = false;
        } else {
            UnstakeRequest memory latestRemainingRequest = _unstakeRequests[remainingRequestsLength - 1];
            hasMore = !_isFinalized(latestRemainingRequest);
        }

        // 返还所有被取消请求的锁定 mETH
        for (uint256 i = 0; i < numCancelled; i++) {
            SafeERC20.safeTransfer(mETH, requests[i].requester, requests[i].mETHLocked);
        }

        return hasMore;
    }

    /// @inheritdoc IUnstakeRequestsManagerWrite
    /// @dev 接收来自质押合约的 ETH 分配
    function allocateETH() external payable onlyStakingContract {
        allocatedETHForClaims += msg.value;
    }

    /// @inheritdoc IUnstakeRequestsManagerWrite
    /// @dev 紧急场景：取消请求后将多余的 ETH 返还给质押合约
    function withdrawAllocatedETHSurplus() external onlyStakingContract {
        uint256 toSend = allocatedETHSurplus();
        if (toSend == 0) {
            return;
        }
        allocatedETHForClaims -= toSend;
        stakingContract.receiveFromUnstakeRequestsManager{value: toSend}();
    }

    // ============================================
    // 查询函数
    // ============================================

    /// @notice 返回下一个将要创建的解除质押请求的 ID
    function nextRequestId() external view returns (uint256) {
        return _unstakeRequests.length;
    }

    /// @inheritdoc IUnstakeRequestsManagerRead
    function requestByID(uint256 requestID) external view returns (UnstakeRequest memory) {
        return _unstakeRequests[requestID];
    }

    /// @inheritdoc IUnstakeRequestsManagerRead
    /// @dev 返回请求的完成状态和可claim金额
    function requestInfo(uint256 requestID) external view returns (bool, uint256) {
        UnstakeRequest memory request = _unstakeRequests[requestID];

        bool isFinalized = _isFinalized(request);
        uint256 claimableAmount = 0;

        // 累计 ETH 请求包含当前请求的 ETH，需要减去才能得到部分填充金额
        uint256 allocatedEthRequired = request.cumulativeETHRequested - request.ethRequested;
        if (allocatedEthRequired < allocatedETHForClaims) {
            // allocatedETHForClaims 会随时间增加，而请求的累计 ETH 保持不变
            // 差值会逐渐增加，但只返回不超过请求金额的部分
            claimableAmount = Math.min(allocatedETHForClaims - allocatedEthRequired, request.ethRequested);
        }

        return (isFinalized, claimableAmount);
    }

    /// @inheritdoc IUnstakeRequestsManagerRead
    /// @dev 计算已分配 ETH 相对于累计请求的盈余
    function allocatedETHSurplus() public view returns (uint256) {
        if (allocatedETHForClaims > latestCumulativeETHRequested) {
            return allocatedETHForClaims - latestCumulativeETHRequested;
        }
        return 0;
    }

    /// @inheritdoc IUnstakeRequestsManagerRead
    /// @dev 计算已分配 ETH 相对于累计请求的不足
    function allocatedETHDeficit() external view returns (uint256) {
        if (latestCumulativeETHRequested > allocatedETHForClaims) {
            return latestCumulativeETHRequested - allocatedETHForClaims;
        }
        return 0;
    }

    /// @inheritdoc IUnstakeRequestsManagerRead
    /// @dev 返回等待被claim的 ETH 余额
    function balance() external view returns (uint256) {
        if (allocatedETHForClaims > totalClaimed) {
            return allocatedETHForClaims - totalClaimed;
        }
        return 0;
    }

    // ============================================
    // 管理函数
    // ============================================

    /// @notice 更新请求完成所需的区块数
    function setNumberOfBlocksToFinalize(uint256 numberOfBlocksToFinalize_) external onlyRole(MANAGER_ROLE) {
        numberOfBlocksToFinalize = numberOfBlocksToFinalize_;
        emit ProtocolConfigChanged(
            this.setNumberOfBlocksToFinalize.selector,
            "setNumberOfBlocksToFinalize(uint256)",
            abi.encode(numberOfBlocksToFinalize_)
        );
    }

    // ============================================
    // 内部函数
    // ============================================

    /// @notice 检查请求是否已完成
    /// @dev 完成条件：
    /// 1. 请求区块号 + 完成所需区块数 ≤ 预言机最新记录的结束区块号
    /// 2. 这确保只有在协议有有效预言机记录时才能claim
    function _isFinalized(UnstakeRequest memory request) internal view returns (bool) {
        return (request.blockNumber + numberOfBlocksToFinalize) <= oracle.latestRecord().updateEndBlock;
    }

    /// @notice 验证调用者是质押合约
    modifier onlyStakingContract() {
        if (msg.sender != address(stakingContract)) {
            revert NotStakingContract();
        }
        _;
    }

    // ============================================
    // Fallback 函数
    // ============================================

    receive() external payable {
        revert DoesNotReceiveETH();
    }

    fallback() external payable {
        revert DoesNotReceiveETH();
    }
}
