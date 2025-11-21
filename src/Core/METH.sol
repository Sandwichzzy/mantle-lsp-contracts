// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IMETH} from "../interfaces/IMETH.sol";
import {IStaking} from "../interfaces/IStaking.sol";
import {IUnstakeRequestsManager} from "../interfaces/IUnstakeRequestsManager.sol";
import {IBlockList} from "../interfaces/IBlockList.sol";

/// @notice mETH 是 Mantle Liquid Staking Protocol 的流动性质押代币
/// @dev 继承 ERC20PermitUpgradeable 以支持离线签名，继承 AccessControlEnumerableUpgradeable 以进行权限管理
contract METH is Initializable, AccessControlEnumerableUpgradeable, ERC20PermitUpgradeable, IMETH {
    bytes32 public constant ADD_BLOCK_LIST_CONTRACT_ROLE = keccak256("ADD_BLOCK_LIST_CONTRACT_ROLE");
    bytes32 public constant REMOVE_BLOCK_LIST_CONTRACT_ROLE = keccak256("REMOVE_BLOCK_LIST_CONTRACT_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    //events
    event BlockListContractAdded(address indexed blockList);
    event BlockListContractRemoved(address indexed blockList);

    // Errors.
    error NotStakingContract();
    error NotUnstakeRequestsManagerContract();

    /// @notice The staking contract which has permissions to mint tokens.
    IStaking public stakingContract;

    /// @notice The unstake requests manager contract which has permissions to burn tokens.
    IUnstakeRequestsManager public unstakeRequestsManagerContract;

    using EnumerableSet for EnumerableSet.AddressSet;
    EnumerableSet.AddressSet private _blockListContracts;

    /// @notice Configuration for contract initialization.
    struct Init {
        address admin;
        IStaking staking;
        IUnstakeRequestsManager unstakeRequestsManager;
    }

    modifier notBlocked(address from, address to) {
        require(!isBlocked(msg.sender), "mETH: 'sender' address blocked");
        require(!isBlocked(from), "mETH: 'from' address blocked");
        require(!isBlocked(to), "mETH: 'to' address blocked");
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice Inititalizes the contract.
    /// @dev MUST be called during the contract upgrade to set up the proxies state.
    function initialize(Init memory init) external initializer {
        __ERC20_init("mETH", "mETH");
        __ERC20Permit_init("mETH");
        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(MINTER_ROLE, address(init.staking));
        _grantRole(BURNER_ROLE, address(init.unstakeRequestsManager));
        stakingContract = init.staking;
        unstakeRequestsManagerContract = init.unstakeRequestsManager;
    }

    /// @inheritdoc IMETH
    /// @dev Expected to be called during the stake operation.
    function mint(address staker, uint256 amount) external {
        if (msg.sender != address(stakingContract)) {
            revert NotStakingContract();
        }
        _mint(staker, amount);
    }

    /// @inheritdoc IMETH
    /// @dev Expected to be called when a user has claimed their unstake request.
    function burn(uint256 amount) external {
        if (msg.sender != address(unstakeRequestsManagerContract)) {
            revert NotUnstakeRequestsManagerContract();
        }
        _burn(msg.sender, amount);
    }

    function forceMint(address account, uint256 amount, bool excludeBlockList) external onlyRole(MINTER_ROLE) {
        if (excludeBlockList) {
            require(
                !isBlocked(account),
                string(abi.encodePacked(Strings.toHexString(uint160(account), 20), " is in block list"))
            );
        }
        _mint(account, amount);
    }

    function forceBurn(address account, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(account, amount);
    }

    /// @dev See {IERC20Permit-nonces}.
    function nonces(address owner)
        public
        view
        virtual
        override(IERC20Permit, ERC20PermitUpgradeable)
        returns (uint256)
    {
        return ERC20PermitUpgradeable.nonces(owner);
    }

    function isBlocked(address account) public view returns (bool) {
        uint256 length = EnumerableSet.length(_blockListContracts);
        for (uint256 i = 0; i < length; i++) {
            if (IBlockList(EnumerableSet.at(_blockListContracts, i)).isBlocked(account)) {
                return true;
            }
        }
        return false;
    }

    function _update(address from, address to, uint256 amount) internal override notBlocked(from, to) {
        return super._update(from, to, amount);
    }

    function addBlockListContract(address blockListAddress) external onlyRole(ADD_BLOCK_LIST_CONTRACT_ROLE) {
        //验证合约是否实现了 isBlocked(address) 函数
        //正确实现 IBlockList 接口的合约才能被添加到封禁列表中
        (bool success,) = blockListAddress.call(abi.encodeWithSignature("isBlocked(address)", address(0)));
        require(success, "Invalid block list contract");
        require(EnumerableSet.add(_blockListContracts, blockListAddress), "Already added");
        emit BlockListContractAdded(blockListAddress);
    }

    function removeBlockListContract(address blockListAddress) external onlyRole(REMOVE_BLOCK_LIST_CONTRACT_ROLE) {
        require(EnumerableSet.remove(_blockListContracts, blockListAddress), "Not added");
        emit BlockListContractRemoved(blockListAddress);
    }

    function getBlockLists() external view returns (address[] memory) {
        return _blockListContracts.values();
    }
}
