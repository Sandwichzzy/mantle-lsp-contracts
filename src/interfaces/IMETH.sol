// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

interface IMETH is IERC20, IERC20Permit {
    /// @notice 向质押者铸造 mETH。
    /// @param staker 质押者的地址。
    /// @param amount 要铸造的代币数量。
    function mint(address staker, uint256 amount) external;

    /// @notice 从 msg.sender 销毁 mETH。
    /// @param amount 要销毁的代币数量。
    function burn(uint256 amount) external;
}
