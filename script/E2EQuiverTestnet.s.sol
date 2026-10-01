// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {LotteryCore} from "../src/quiver/LotteryCore.sol";
import {StandardERC20} from "../test/mocks/StandardERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  E2EQuiverTestnet
/// @notice Step-by-step end-to-end walkthrough of LotteryCore against the LIVE Quiver
///         coordinator on Robinhood testnet. Run with `--rpc-url robinhood_testnet`.
///
///         Env (all except the buyer/owner/salt defaults are required):
///         - PRIVATE_KEY           operator EOA (deployer + resolver + host)
///         - E2E_BUYER_KEY         second EOA that buys tickets (defaults to PRIVATE_KEY)
///         - QUIVER_COORDINATOR    default = testnet coordinator
///         - QUIVER_PROVIDER       default = testnet provider
///         - RAFFLE_TREASURY       fee treasury
///         - RAFFLE_SIGNER         free-entry signer (may be any EOA for the demo)
///         - RAFFLE_OWNER          initial owner
///         - RAFFLE_MANAGER        (steps 2+) deployed manager address
///         - RAFFLE_ID             (steps 2+) raffle id
///         - RAFFLE_SALT           (step 3) hex salt used for resolution
///
///         Steps:
///           1. `run()`      deploys a test ERC-20 + LotteryCore, creates a raffle, buys
///                           tickets, prints the manager + raffle id.
///           2. wait for `expiry` to pass, then `stepResolve()` requests randomness from the
///              live coordinator (keep the salt secret until the tx lands).
///           3. wait for the Quiver keeper to reveal (status -> RESOLVED), then `stepSettle()`.
contract E2EQuiverTestnet is Script {
    address internal constant TESTNET_COORDINATOR = 0x1da30d6465f657F11B4D7F6Db0B16aD79152fb40;
    address internal constant TESTNET_PROVIDER = 0xc84CC91131b63d9BECFDe7b2DB3D0C653B690541;

    function run() external returns (address mgrAddr) {
        uint256 operatorKey = vm.envUint("PRIVATE_KEY");
        uint256 buyerKey = vm.envOr("E2E_BUYER_KEY", operatorKey);
        address operator = vm.addr(operatorKey);
        address buyer = vm.addr(buyerKey);
        address coordinator = vm.envOr("QUIVER_COORDINATOR", TESTNET_COORDINATOR);
        address provider = vm.envOr("QUIVER_PROVIDER", TESTNET_PROVIDER);
        address treasury = vm.envAddress("RAFFLE_TREASURY");
        address signer = vm.envAddress("RAFFLE_SIGNER");
        address owner = vm.envAddress("RAFFLE_OWNER");

        vm.startBroadcast(operatorKey);
        StandardERC20 demoToken = new StandardERC20("E2E Token", "E2E", 1_000_000e18);
        LotteryCore mgr = new LotteryCore(coordinator, provider, address(0), address(demoToken), treasury, signer, owner);
        mgr.setResolver(operator, true);

        // Host (operator) creates an ERC-20 raffle with the demo token.
        demoToken.transfer(operator, 50_000e18);
        demoToken.approve(address(mgr), 10_000e18);
        uint256 raffleId = mgr.createRaffleERC20(address(demoToken), 10_000e18, 1e18, 100, 2 hours);

        // Buyer enters with 5 tickets.
        demoToken.transfer(buyer, 10_000e18);
        vm.stopBroadcast();

        vm.startBroadcast(buyerKey);
        demoToken.approve(address(mgr), 5e18);
        mgr.enterRaffle(raffleId, 5);
        vm.stopBroadcast();

        console2.log("LotteryCore testnet E2E - step 1 complete");
        console2.log("Manager:  %s", address(mgr));
        console2.log("Raffle:   %s", raffleId);
        console2.log("Expiry:   %s", uint256(mgr.getRaffle(raffleId).expiry));
        console2.log("Buyer:    %s", buyer);
        console2.log("Coordinator: %s", coordinator);
        console2.log("Provider: %s", provider);
        console2.log("Randomness fee (wei): %s", uint256(mgr.randomnessFee()));

        mgrAddr = address(mgr);
    }

    function stepResolve() external {
        uint256 operatorKey = vm.envUint("PRIVATE_KEY");
        LotteryCore mgr = LotteryCore(payable(vm.envAddress("RAFFLE_MANAGER")));
        uint256 raffleId = vm.envUint("RAFFLE_ID");
        bytes32 salt = vm.envBytes32("RAFFLE_SALT");

        vm.startBroadcast(operatorKey);
        mgr.resolveRaffle(raffleId, salt);
        vm.stopBroadcast();

        console2.log(
            "Randomness requested on provider %s seq %s - keeper must now reveal.",
            mgr.activeProviderOf(raffleId),
            uint256(mgr.activeSeq(raffleId))
        );
    }

    function stepSettle() external {
        LotteryCore mgr = LotteryCore(payable(vm.envAddress("RAFFLE_MANAGER")));
        uint256 raffleId = vm.envUint("RAFFLE_ID");
        uint256 status = uint256(mgr.getRaffle(raffleId).status);
        require(status == 4, "raffle not RESOLVED yet (keeper has not revealed)");

        mgr.settle(raffleId);
        console2.log("Settled raffle %s - COMPLETED", raffleId);
    }
}
