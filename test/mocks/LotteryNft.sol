// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract LotteryNft is ERC721 {
    uint256 public nextId;
    string public baseURI;

    constructor(string memory _baseURI) ERC721("Lottery", "LOTTERY") {
        baseURI = _baseURI;
    }

    function mint(address to) external returns (uint256 tokenId) {
        tokenId = ++nextId;
        _mint(to, tokenId);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);

        return string.concat(baseURI, Strings.toString(tokenId), ".json");
    }
}
