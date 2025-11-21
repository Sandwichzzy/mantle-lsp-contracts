// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {IMETH} from "../interfaces/IMETH.sol";
import {IStaking} from "../interfaces/IStaking.sol";
import {IUnstakeRequestsManager} from "../interfaces/IUnstakeRequestsManager.sol";
import {IBlockList} from "../interfaces/IBlockList.sol";

// import {ILiquidityBuffer} from "./liquidityBuffer/interfaces/ILiquidityBuffer.sol";

contract METH is ERC20PermitUpgradeable, AccessControlEnumerableUpgradeable, IMETH {}
