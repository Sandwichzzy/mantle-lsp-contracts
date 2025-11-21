// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ProtocolEvents {
    /// @notice 当协议配置已更新时触发。
    /// @param setterSelector 更新配置的函数选择器。
    /// @param setterSignature 更新配置的函数签名。
    /// @param value 传递给更新配置函数的 abi 编码数据。由于此事件只会由 setter 触发，
    /// 此数据对应于协议配置中的更新值。
    event ProtocolConfigChanged(bytes4 indexed setterSelector, string setterSignature, bytes value);
}
