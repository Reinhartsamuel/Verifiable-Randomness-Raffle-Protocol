// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice ERC-721 whose `transferFrom` always reverts on payout, forcing LotteryCore's
///         NFT escrow path. Minting still works so raffles can be created.
contract RevertingERC721 is ERC721 {
    bool public revertOnTransfer = true;

    constructor(string memory name, string memory symbol) ERC721(name, symbol) {}

    function setRevertOnTransfer(bool value) external {
        revertOnTransfer = value;
    }

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function transferFrom(address from, address to, uint256 tokenId) public override {
        require(!revertOnTransfer, "RevertingERC721: blocked");
        super.transferFrom(from, to, tokenId);
    }
}
