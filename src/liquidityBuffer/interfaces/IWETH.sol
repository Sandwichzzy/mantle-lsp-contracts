// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

/**
 * @title IWETH - Wrapped ETH 接口
 * @notice WETH (Wrapped ETH) 代币合约的接口
 * @dev WETH 是 ETH 的 ERC20 包装版本，允许 ETH 在 DeFi 协议中作为标准代币使用
 */
interface IWETH {
    /// @notice 存入 ETH 并铸造等量的 WETH
    /// @dev 需要发送 ETH 到此函数
    function deposit() external payable;

    /// @notice 销毁 WETH 并提取等量的 ETH
    /// @param amount 要提取的 WETH 数量
    function withdraw(uint256 amount) external;

    /// @notice 批准某个地址使用 WETH
    /// @param guy 被授权的地址
    /// @param wad 授权数量
    /// @return 是否批准成功
    function approve(address guy, uint256 wad) external returns (bool);

    /// @notice 从一个地址转移 WETH 到另一个地址
    /// @param src 源地址
    /// @param dst 目标地址
    /// @param wad 转移数量
    /// @return 是否转移成功
    function transferFrom(address src, address dst, uint256 wad) external returns (bool);
}
