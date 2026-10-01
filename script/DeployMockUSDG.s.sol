// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {MockUSDG} from "../test/mocks/MockUSDG.sol";
import {console} from "forge-std/console.sol";

contract DeployMockMockUSDG is Script {
    function run() external returns (MockUSDG usdg) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        usdg = new MockUSDG(1e6 * 1e6);
        vm.stopBroadcast();
        console.log("Deployed MockUSDG at:", address(usdg));
        return usdg;
    }
}
