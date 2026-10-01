// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC-20 that refuses to transfer to a blacklisted recipient. Used to force the
///         escrow fallback path in LotteryCore payouts (winner/host/treasury blacklisted).
contract BlacklistERC20 is ERC20 {
    mapping(address => bool) public blacklisted;

    constructor(string memory name, string memory symbol, uint256 supply) ERC20(name, symbol) {
        _mint(msg.sender, supply);
    }

    function setBlacklisted(address who, bool value) external {
        blacklisted[who] = value;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(!blacklisted[to] && !blacklisted[from], "BlacklistERC20: blocked");
        super._update(from, to, amount);
    }
}
