// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ReturnsReceiver 收益接收器
/// @notice 接收协议级别的收益并管理谁可以提取收益。在协议中部署为共识层提取钱包和执行层奖励钱包。
contract ReturnsReceiver is Initializable, AccessControlEnumerableUpgradeable {
    /// @notice 管理员角色，负责管理 WITHDRAWER_ROLE。
    bytes32 public constant RECEIVER_MANAGER_ROLE = keccak256("RECEIVER_MANAGER_ROLE");

    /// @notice 提取者角色，可以从此合约中提取 ETH 和 ERC20 代币。
    bytes32 public constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");

    /// @notice 合约初始化配置。
    struct Init {
        address admin;
        address manager;
        address withdrawer;
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化合约。
    /// @dev 必须在合约升级期间调用以设置代理状态。
    function initialize(Init memory init) external initializer {
        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(RECEIVER_MANAGER_ROLE, init.manager);
        _setRoleAdmin(WITHDRAWER_ROLE, RECEIVER_MANAGER_ROLE);
        _grantRole(WITHDRAWER_ROLE, init.withdrawer);
    }

    /// @notice 将指定数量的 ETH 转账到指定地址。
    /// @dev 仅由提取者调用。
    function transfer(address payable to, uint256 amount) external onlyRole(WITHDRAWER_ROLE) {
        Address.sendValue(to, amount);
    }

    /// @notice 将指定数量的 ERC20 代币转账到指定地址。
    /// @dev 仅由提取者调用。
    function transferERC20(IERC20 token, address to, uint256 amount) external onlyRole(WITHDRAWER_ROLE) {
        SafeERC20.safeTransfer(token, to, amount);
    }

    receive() external payable {}
}
