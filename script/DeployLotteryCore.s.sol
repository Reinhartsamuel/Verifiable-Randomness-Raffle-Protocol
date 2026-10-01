// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {LotteryCore} from "../src/quiver/LotteryCore.sol";

/// @title  DeployLotteryCore
/// @notice Deploys LotteryCore for a target chain. Reads configuration from env:
///
///         PRIVATE_KEY                deployer key
///         QUIVER_COORDINATOR         Quiver coordinator address (testnet 0x1da3...2fb40)
///         QUIVER_PROVIDER            default provider (testnet 0xc84C...90541)
///         QUIVER_FALLBACK_PROVIDER   optional fallback provider (0 = disabled)
///         RAFFLE_PAYMENT_TOKEN       payment token (USDC)
///         RAFFLE_TREASURY            fee treasury
///         RAFFLE_SIGNER              free-entry EIP-712 signer
///         RAFFLE_OWNER               initial owner (multisig recommended)
///
///         forge script script/DeployLotteryCore.s.sol \
///           --rpc-url robinhood_testnet --broadcast -vvvv
///
/// @dev    After deploy: set the resolver keeper, propose/apply the platform fee, and top the
///         manager up with native ETH if the provider quotes a non-zero fee.
contract DeployLotteryCore is Script {
    function run() external returns (LotteryCore mgr) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address coordinator = vm.envAddress("QUIVER_COORDINATOR");
        address provider = vm.envAddress("QUIVER_PROVIDER");
        address fallbackProvider = vm.envOr("QUIVER_FALLBACK_PROVIDER", address(0));
        address paymentToken = vm.envAddress("PAYMENT_TOKEN");
        address treasury = vm.envAddress("TREASURY");
        address signer = vm.envOr("RAFFLE_SIGNER", address(0x753dFC03b4d37B3a316D0Fe5aB9F677C0D3C20f8));
        address owner = vm.envOr("RAFFLE_OWNER", address(msg.sender));

        vm.startBroadcast(deployerKey);
        mgr = new LotteryCore(coordinator, provider, fallbackProvider, paymentToken, treasury, signer, owner);
        vm.stopBroadcast();
    }
}
