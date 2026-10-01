// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RaffleCore} from "../src/chainlink/RaffleCore.sol";

/// @notice Deployment script for RaffleCore.
///
/// PREREQUISITES (must be set in .env):
///   DEPLOYER_PRIVATE_KEY  – deployer wallet private key
///   VRF_COORDINATOR       – Chainlink VRF v2.5 Coordinator address
///   KEY_HASH              – Chainlink key hash for gas lane
///   SUB_ID                – Chainlink VRF subscription ID
///   PAYMENT_TOKEN         – ERC-20 token address for ticket payments.
///                            Optional on Base mainnet — defaults to native
///                            Circle USDC (0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).
///                            REQUIRED on Base Sepolia (set to your mock USDC).
///   TREASURY              – Treasury address that receives platform fees
///   TRUSTED_SIGNER        – Backend signer address for free entry EIP-712 signatures
///   INITIAL_FEE_BPS       – (optional) Initial platform fee in basis points, default 0
///
/// BASE SEPOLIA (dry-run first):
///   forge script script/Deploy7.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL -vvv
///   forge script script/Deploy7.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast --verify -vvv
///
/// BASE MAINNET (only when the first paying pilot signs):
///   forge script script/Deploy7.s.sol \
///     --rpc-url $BASE_MAINNET_RPC_URL \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     --broadcast \
///     --verify \
///     --etherscan-api-key $BASESCAN_API_KEY
///
/// LOCAL TESTING (Anvil, no env vars needed):
///   forge script script/Deploy7.s.sol
///

contract Deploy7 is Script {
    function run() external returns (RaffleCore raffle) {
        // ── Load configuration ──────────────────────────────────────────────
        uint256 deployerKey = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));

        address vrfCoordinator = vm.envAddress(
            "VRF_COORDINATOR"
            // address(0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE) // Base Sepolia default
        );
        bytes32 keyHash = vm.envBytes32(
            "KEY_HASH"
            // bytes32(0x9e1344a1247c8a1785d0a4681a27152bffdb43666ae5bf7d14d24a5efd44bf71) // Base Sepolia default
        );
        uint256 subId = vm.envUint(
            "SUB_ID"
            // uint256(1)
        );

        address paymentToken = vm.envOr(
            "PAYMENT_TOKEN",
            address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913) // native Circle USDC on Base mainnet
        );
        address treasury = vm.envAddress("TREASURY");
        address trustedSigner = vm.envOr("TRUSTED_SIGNER", deployerKey != 0 ? vm.addr(deployerKey) : address(0));

        uint256 initialFeeBps = vm.envOr("INITIAL_FEE_BPS", uint256(500));

        // ── Validate critical params ────────────────────────────────────────
        require(vrfCoordinator != address(0), "VRF_COORDINATOR required");
        require(paymentToken != address(0), "PAYMENT_TOKEN required");
        require(treasury != address(0), "TREASURY required");
        require(trustedSigner != address(0), "TRUSTED_SIGNER required");

        // ── Deploy ──────────────────────────────────────────────────────────
        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        }

        raffle = new RaffleCore(vrfCoordinator, keyHash, subId, paymentToken, treasury, trustedSigner);

        if (initialFeeBps > 0) {
            raffle.proposeFeeChange(initialFeeBps);
            // Warp forward past timelock only in local/fork simulations
            // On live chains this requires a second tx after 2 days
        }

        raffle.setMinDuration(2 hours); // Set min duration to 2 hours; can be updated later by owner

        if (deployerKey != 0) {
            vm.stopBroadcast();
        }

        // ── Output ──────────────────────────────────────────────────────────
        console.log("===========================================");
        console.log("RaffleCore deployed to:");
        console.logAddress(address(raffle));
        console.log("");
        console.log("Configuration:");
        console.log("  Payment Token :");
        console.logAddress(paymentToken);
        console.log("  Treasury      :");
        console.logAddress(treasury);
        console.log("  Trusted Signer:");
        console.logAddress(trustedSigner);
        console.log("  VRF Coordinator:");
        console.logAddress(vrfCoordinator);
        console.log("  Min Duration  : 2 hours");
        console.log("");
        console.log("Next steps:");
        console.log("1. Add RaffleCore as VRF consumer on vrf.chain.link");
        console.log("2. Fund VRF subscription with LINK");
        console.log("3. If INITIAL_FEE_BPS > 0, call applyFeeChange() after 2 days");
        console.log("4. Verify: forge verify-contract <address> src/chainlink/RaffleCore.sol:RaffleCore --chain <8453|84532>");
        console.log("===========================================");

        return raffle;
    }
}
