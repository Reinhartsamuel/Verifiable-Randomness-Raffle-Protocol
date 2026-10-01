// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC-20 whose behaviour on outbound `transfer` is configurable, to prove
///         LotteryCore's settlement cannot be bricked by a hostile prize token:
///         - `Revert`: transfer() reverts
///         - `ReturnFalse`: transfer() returns false
///         - `ReturndataBomb`: transfer() returns 64 KiB of garbage (returndata-bomb probe)
///         - `Reenter`: transfer() fires a hook before/after moving funds
///         All payout-side attacks apply to `transfer` only; `transferFrom` (prize intake)
///         behaves normally so raffles can still be created with this token.
contract MaliciousPrizeToken is ERC20 {
    enum Mode {
        Normal,
        Revert,
        ReturnFalse,
        ReturndataBomb,
        Reenter
    }

    Mode public mode;
    address public reenterTarget;
    bytes public reenterCalldata;

    constructor(string memory name, string memory symbol, uint256 supply) ERC20(name, symbol) {
        _mint(msg.sender, supply);
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setReenter(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterCalldata = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        Mode m = mode;
        if (m == Mode.Revert) {
            revert("MaliciousPrizeToken: revert");
        }
        if (m == Mode.ReturnFalse) {
            return false;
        }
        if (m == Mode.ReturndataBomb) {
            // Emit a huge returndata buffer so the caller must cap its returndata copy.
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)
                let n := 65536
                let data := add(ptr, 0x20)
                for { let i := 0 } lt(i, n) { i := add(i, 0x20) } { mstore(add(data, i), 0xff) }
                revert(add(ptr, 0x20), n)
            }
        }
        if (m == Mode.Reenter && reenterTarget != address(0)) {
            reenterTarget.call(reenterCalldata);
        }
        super.transfer(to, amount);
        return true;
    }
}
