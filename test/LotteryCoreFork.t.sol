// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LotteryCore} from "../src/quiver/LotteryCore.sol";
import {StandardERC20} from "./mocks/StandardERC20.sol";

/// @notice OPT-IN fork smoke test against the live Quiver coordinator on Robinhood testnet.
///         Not run in CI by default - set `ROBINHOOD_TESTNET_RPC` to enable. Every test
///         verifies the real coordinator ABI (fee quote, provider record, sequence counter,
///         commitment helper) that LotteryCore's resolver path relies on. It never submits
///         a real randomness request (that would consume a provider hash-chain link).
contract LotteryCoreForkTest is Test {
    address internal constant TESTNET_COORDINATOR = 0x1da30d6465f657F11B4D7F6Db0B16aD79152fb40;
    address internal constant TESTNET_PROVIDER = 0xc84CC91131b63d9BECFDe7b2DB3D0C653B690541;

    bool forkReady;

    modifier forkOrSkip() {
        if (!vm.envExists("ROBINHOOD_TESTNET_RPC")) {
            vm.skip(true);
        } else {
            if (!forkReady) {
                vm.createSelectFork(vm.envString("ROBINHOOD_TESTNET_RPC"));
                forkReady = true;
            }
            _;
        }
    }

    function test_Fork_FeeQuoteAndProviderRegistered() external forkOrSkip {
        (bool ok, bytes memory data) =
            TESTNET_COORDINATOR.staticcall(abi.encodeWithSignature("getFee(address)", TESTNET_PROVIDER));
        assertTrue(ok, "getFee reverted - coordinator/provider mismatch?");

        (bool ok2, bytes memory info) =
            TESTNET_COORDINATOR.staticcall(abi.encodeWithSignature("getProviderInfo(address)", TESTNET_PROVIDER));
        assertTrue(ok2, "getProviderInfo reverted - provider not registered?");
        // ProviderInfo contains maxNumHashes at a known slot; just assert the struct decoded
        // (non-empty returndata > 4 words means feeInWei..anchor fields exist).
        assertTrue(info.length >= 32 * 5, "unexpected ProviderInfo shape");
    }

    function test_Fork_ProviderSequenceAdvances() external forkOrSkip {
        (, bytes memory data) = TESTNET_COORDINATOR.staticcall(
            abi.encodeWithSignature("getProviderSequenceNumber(address)", TESTNET_PROVIDER)
        );
        assertTrue(data.length == 32, "getProviderSequenceNumber returned no value");
        uint64 seq = abi.decode(data, (uint64));
        assertGt(seq, 0, "provider sequence should be >= 1 (registered)");
    }

    function test_Fork_CommitmentHelperMatchesKeccak() external forkOrSkip {
        bytes32 userRandom = keccak256("fork-smoke");
        (, bytes memory data) =
            TESTNET_COORDINATOR.staticcall(abi.encodeWithSignature("constructUserCommitment(bytes32)", userRandom));
        bytes32 onChain = abi.decode(data, (bytes32));
        assertEq(onChain, keccak256(abi.encodePacked(userRandom)));
    }

    function test_Fork_DeployLotteryCoreWithLiveConstants() external forkOrSkip {
        // Smoke-deploy a manager bound to the live coordinator/provider to prove the
        // constructor + view stack decodes against the real ABI (no state changing calls).
        StandardERC20 usdcLike = new StandardERC20("USDC", "USDC", 1e18);
        LotteryCore mgr = new LotteryCore({
            _quiver: TESTNET_COORDINATOR,
            _provider: TESTNET_PROVIDER,
            _fallbackProvider: address(0),
            _paymentToken: address(usdcLike),
            _treasury: address(0xBEEF),
            _trustedSigner: address(0xB0B),
            _initialOwner: address(this)
        });

        assertEq(mgr.getCoordinator(), TESTNET_COORDINATOR);
        assertEq(mgr.getProvider(), TESTNET_PROVIDER);
        assertEq(mgr.activeProvider(), TESTNET_PROVIDER);
        mgr.randomnessFee(); // must not revert against the live coordinator
    }
}
