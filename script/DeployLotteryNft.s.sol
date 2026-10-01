// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {LotteryNft} from "../test/mocks/LotteryNft.sol";
import {console} from "forge-std/console.sol";

contract DeployLotteryNft is Script {
    function run() external returns (LotteryNft nft) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        string memory baseUri = "https://pub-fedd92d489cc481596abe63636ea383f.r2.dev/metadata/";

        vm.startBroadcast(deployerKey);
        nft = new LotteryNft(baseUri);
        nft.mint(vm.addr(deployerKey));
        nft.mint(vm.addr(deployerKey));
        vm.stopBroadcast();

        console.log("Deployed Lottery NFT at:", address(nft));
        console.log("tokenId 1 URI:", nft.tokenURI(1));
        console.log("tokenId 2 URI:", nft.tokenURI(2));

        return nft;
    }
}
