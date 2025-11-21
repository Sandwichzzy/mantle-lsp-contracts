// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IProtocolEvents} from "../interfaces/IProtocolEvents.sol";
import {IPauserRead} from "../interfaces/IPauser.sol";
import {IOracleReadRecord, OracleRecord} from "../interfaces/IOracle.sol";
import {IStakingReturnsWrite} from "../interfaces/IStaking.sol";
import {IReturnsAggregatorWrite} from "../interfaces/IReturnsAggregator.sol";

import {ReturnsReceiver} from "./ReturnsReceiver.sol";

/// @title ReturnsAggregator 收益聚合器
/// @notice 聚合器合约，聚合协议控制的钱包中的收益，在适用情况下收取费用，并将净收益转发到质押合约。
contract ReturnsAggregator is
    Initializable,
    AccessControlEnumerableUpgradeable,
    IProtocolEvents,
    IReturnsAggregatorWrite
{
    error InvalidConfiguration();
    error NotOracle();
    error Paused();
    error ZeroAddress();

    /// @notice 管理员角色，可以设置费用接收钱包和费用基点。
    bytes32 public constant AGGREGATOR_MANAGER_ROLE = keccak256("AGGREGATOR_MANAGER_ROLE");

    /// @dev 基点（通常表示为 bp，1bp = 0.01%）是金融中用于描述金融工具百分比变化的度量单位。
    /// 此常量值设置为 10000，表示基点术语中的 100%。
    uint16 internal constant _BASIS_POINTS_DENOMINATOR = 10_000;

    /// @notice 质押合约，扣除协议费用后的聚合收益将转发到此合约。
    IStakingReturnsWrite public staking;

    /// @notice 预言机合约，从中读取收益信息。
    IOracleReadRecord public oracle;

    /// @notice 接收共识层收益的合约，即包括奖励和本金的部分提取和完全提取。
    ReturnsReceiver public consensusLayerReceiver;

    /// @notice 接收执行层奖励的合约，即小费和 MEV 奖励。
    ReturnsReceiver public executionLayerReceiver;

    /// @notice 暂停器合约。
    /// @dev 维护整个协议的暂停状态。
    IPauserRead public pauser;

    /// @notice 接收协议费用的地址。
    address payable public feesReceiver;

    /// @notice 协议费用基点（1/10000）。
    uint16 public feesBasisPoints;

    /// @notice 合约初始化配置。
    struct Init {
        address admin;
        address manager;
        IOracleReadRecord oracle;
        IPauserRead pauser;
        ReturnsReceiver consensusLayerReceiver;
        ReturnsReceiver executionLayerReceiver;
        IStakingReturnsWrite staking;
        address payable feesReceiver;
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化合约。
    /// @dev 必须在合约升级期间调用以设置代理状态。
    function initialize(Init memory init) external initializer {
        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(AGGREGATOR_MANAGER_ROLE, init.manager);

        oracle = init.oracle;
        pauser = init.pauser;
        consensusLayerReceiver = init.consensusLayerReceiver;
        executionLayerReceiver = init.executionLayerReceiver;
        staking = init.staking;
        feesReceiver = init.feesReceiver;
        // 默认费用为 10%
        feesBasisPoints = 1_000;
    }

    /// @inheritdoc IReturnsAggregatorWrite
    /// @dev 计算要转发到质押合约的资金数量，收取费用并转发。
    /// 注意，我们还会验证资金已转发到质押合约，并且没有发送到此合约。
    function processReturns(uint256 rewardAmount, uint256 principalAmount, bool shouldIncludeELRewards)
        external
        assertBalanceUnchanged
    {
        if (msg.sender != address(oracle)) {
            revert NotOracle();
        }

        // 计算将聚合的收益总额。
        uint256 clTotal = rewardAmount + principalAmount;
        uint256 totalRewards = rewardAmount;

        uint256 elRewards = 0;
        if (shouldIncludeELRewards) {
            elRewards = address(executionLayerReceiver).balance;
            totalRewards += elRewards;
        }

        // 计算协议费用。
        uint256 fees = Math.mulDiv(feesBasisPoints, totalRewards, _BASIS_POINTS_DENOMINATOR);

        // 在此合约中聚合收益
        address payable self = payable(address(this));
        if (elRewards > 0) {
            executionLayerReceiver.transfer(self, elRewards);
        }
        if (clTotal > 0) {
            consensusLayerReceiver.transfer(self, clTotal);
        }

        // 将净收益（如果存在）转发到质押合约。
        uint256 netReturns = clTotal + elRewards - fees;
        if (netReturns > 0) {
            staking.receiveReturns{value: netReturns}();
        }

        // 将协议费用（如果存在）发送到费用接收钱包。
        if (fees > 0) {
            emit FeesCollected(fees);
            Address.sendValue(feesReceiver, fees);
        }
    }

    /// @notice 设置协议的费用接收钱包。
    /// @param newReceiver 新的费用接收钱包。
    function setFeesReceiver(address payable newReceiver)
        external
        onlyRole(AGGREGATOR_MANAGER_ROLE)
        notZeroAddress(newReceiver)
    {
        feesReceiver = newReceiver;
        emit ProtocolConfigChanged(this.setFeesReceiver.selector, "setFeesReceiver(address)", abi.encode(newReceiver));
    }

    /// @notice 设置费用基点。
    /// @param newBasisPoints 新的费用基点。
    function setFeeBasisPoints(uint16 newBasisPoints) external onlyRole(AGGREGATOR_MANAGER_ROLE) {
        if (newBasisPoints > _BASIS_POINTS_DENOMINATOR) {
            revert InvalidConfiguration();
        }

        feesBasisPoints = newBasisPoints;
        emit ProtocolConfigChanged(
            this.setFeeBasisPoints.selector, "setFeeBasisPoints(uint16)", abi.encode(newBasisPoints)
        );
    }

    receive() external payable {}

    /// @notice 确保给定地址不是零地址。
    /// @param addr 要检查的地址。
    modifier notZeroAddress(address addr) {
        if (addr == address(0)) {
            revert ZeroAddress();
        }
        _;
    }

    /// @notice 确保函数返回后合约余额保持不变。
    modifier assertBalanceUnchanged() {
        uint256 before = address(this).balance;
        _;
        assert(address(this).balance == before);
    }
}
