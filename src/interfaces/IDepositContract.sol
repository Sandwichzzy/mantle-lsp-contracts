// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// 此接口设计为与 Vyper 版本兼容。
/// @notice 这是 Ethereum 2.0 存款合约接口。
/// 更多信息请参见 Phase 0 规范：https://github.com/ethereum/eth2.0-specs
interface IDepositContract {
    /// @notice 已处理的存款事件。
    event DepositEvent(bytes pubkey, bytes withdrawal_credentials, bytes amount, bytes signature, bytes index);

    /// @notice 提交一个 Phase 0 的 DepositData 对象。
    /// @param pubkey BLS12-381 公钥。
    /// @param withdrawal_credentials 对提款公钥的承诺。
    /// @param signature BLS12-381 签名。
    /// @param deposit_data_root SSZ 编码的 DepositData 对象的 SHA-256 哈希值。
    /// 用作防止格式错误输入的保护。
    function deposit(
        bytes calldata pubkey,
        bytes calldata withdrawal_credentials,
        bytes calldata signature,
        bytes32 deposit_data_root
    ) external payable;

    /// @notice 查询当前存款根哈希。
    /// @return 存款根哈希。
    function get_deposit_root() external view returns (bytes32);

    /// @notice 查询当前存款计数。
    /// @return 以小端序 64 位数字编码的存款计数。
    function get_deposit_count() external view returns (bytes memory);
}

// 基于 https://eips.ethereum.org/EIPS/eip-165 中的官方规范
interface ERC165 {
    /// @notice 查询合约是否实现了某个接口
    /// @param interfaceId 接口标识符，在 ERC-165 中指定
    /// @dev 接口识别在 ERC-165 中指定。此函数使用少于 30,000 gas。
    /// @return 如果合约实现了 `interfaceId` 且 `interfaceId` 不是 0xffffffff，则返回 `true`，否则返回 `false`
    function supportsInterface(bytes4 interfaceId) external pure returns (bool);
}
