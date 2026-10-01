// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {QuiverBaseTest} from "./QuiverBase.t.sol";
import {LotteryCore} from "../src/quiver/LotteryCore.sol";
import {MockQuiverCoordinator} from "./mocks/MockQuiverCoordinator.sol";
import {TooManyHashes, ProviderNotRegistered, ProviderChainExhausted} from "quiver/libraries/QuiverErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Quiver randomness-failure and retry-liveness coverage for LotteryCore.
contract LotteryCoreRandomnessTest is QuiverBaseTest {
    bytes32 constant SALT_2 = keccak256("salt_2");
    bytes32 constant SALT_3 = keccak256("salt_3");

    function _warpStallTimeout() internal {
        vm.warp(block.timestamp + mgr.STALL_TIMEOUT());
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Request failure handling (try/catch — provider can never strand funds)
    // ═════════════════════════════════════════════════════════════════════════

    function test_RequestFailure_PausedCoordinator_LeavesOpen() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();

        coord.pause();

        vm.prank(RESOLVER);
        vm.expectEmit(true, true, false, true);
        emit LotteryCore.RandomnessRequestFailed(
            raffleId, providerA, abi.encodeWithSelector(MockQuiverCoordinator.Paused.selector)
        );
        mgr.resolveRaffle(raffleId, SALT_1);

        // Still OPEN — a paused provider does not strand escrowed funds.
        assertEq(uint256(mgr.getRaffle(raffleId).status), 0);
        assertEq(mgr.resolveAttempts(raffleId), 0);
        assertEq(mgr.activeSeq(raffleId), 0);
    }

    function test_RequestFailure_RecoversWithFreshSalt() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();

        coord.pause();
        vm.prank(RESOLVER);
        mgr.resolveRaffle(raffleId, SALT_1); // fails (emits RandomnessRequestFailed)

        coord.unpause();

        // Same salt rejected (already consumed even by the failed attempt).
        vm.prank(RESOLVER);
        vm.expectRevert(LotteryCore.SaltAlreadyUsed.selector);
        mgr.resolveRaffle(raffleId, SALT_1);

        // Fresh salt succeeds.
        _resolve(raffleId, SALT_2);
        assertEq(uint256(mgr.getRaffle(raffleId).status), 1); // PENDING_VRF
    }

    function test_RequestFailure_UnregisteredProvider() external {
        address unregistered = makeAddr("unregistered");

        mgr.proposeProviderChange(unregistered, address(0));
        vm.warp(block.timestamp + 2 days + 1);
        mgr.applyProviderChange();

        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();

        vm.prank(RESOLVER);
        vm.expectEmit(true, true, false, true);
        emit LotteryCore.RandomnessRequestFailed(
            raffleId, unregistered, abi.encodeWithSelector(ProviderNotRegistered.selector, unregistered)
        );
        mgr.resolveRaffle(raffleId, SALT_1);

        assertEq(uint256(mgr.getRaffle(raffleId).status), 0); // still OPEN
    }

    function test_RequestFailure_ProviderChainExhausted() external {
        // Fresh provider with a 1-link chain: first request works, second exhausts.
        address shortChain = makeAddr("shortChain");
        coord.registerProviderWithSeed(shortChain, 0, keccak256("seed_short"), 1, 32);

        mgr.proposeProviderChange(shortChain, address(0));
        vm.warp(block.timestamp + 2 days + 1);
        mgr.applyProviderChange();

        uint256 raffle1 = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffle1, 5);
        _warpPastExpiry();
        _resolve(raffle1, SALT_1); // consumes link 1
        assertEq(uint256(mgr.getRaffle(raffle1).status), 1);

        uint256 raffle2 = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(BOB, raffle2, 5);
        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(RESOLVER);
        vm.expectEmit(true, true, false, true);
        emit LotteryCore.RandomnessRequestFailed(
            raffle2, shortChain, abi.encodeWithSelector(ProviderChainExhausted.selector, shortChain, 1)
        );
        mgr.resolveRaffle(raffle2, SALT_1);

        assertEq(uint256(mgr.getRaffle(raffle2).status), 0); // still OPEN
    }

    function test_RequestFailure_ForcedCoordinatorError_ThenCleared() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();

        coord.setForcedRequestError(TooManyHashes.selector);

        vm.prank(RESOLVER);
        vm.expectEmit(true, true, false, true);
        emit LotteryCore.RandomnessRequestFailed(raffleId, providerA, abi.encodeWithSelector(TooManyHashes.selector));
        mgr.resolveRaffle(raffleId, SALT_1);
        assertEq(uint256(mgr.getRaffle(raffleId).status), 0);

        coord.setForcedRequestError(bytes4(0));
        _resolve(raffleId, SALT_2);
        assertEq(uint256(mgr.getRaffle(raffleId).status), 1);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Retry ladder & fallback provider
    // ═════════════════════════════════════════════════════════════════════════

    function test_Retry_RevertBeforeTimeout() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolve(raffleId, SALT_1);

        vm.prank(RESOLVER);
        vm.expectRevert(LotteryCore.StallTimeoutNotReached.selector);
        mgr.retryResolve(raffleId, SALT_2);
    }

    function test_Retry_ACL() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolve(raffleId, SALT_1);
        _warpStallTimeout();

        vm.expectRevert(abi.encodeWithSelector(LotteryCore.NotResolver.selector, address(this)));
        mgr.retryResolve(raffleId, SALT_2);
    }

    function test_Retry_EmitsStalledAndFallsBack() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolve(raffleId, SALT_1);

        assertEq(mgr.activeProviderOf(raffleId), providerA);
        assertEq(mgr.activeSeq(raffleId), 1);

        _warpStallTimeout();
        vm.prank(RESOLVER);
        vm.expectEmit(true, true, false, true);
        emit LotteryCore.RaffleStalled(raffleId, 2);
        mgr.retryResolve(raffleId, SALT_2);

        // Fallback provider B now services the raffle (fresh seq space starting at 1).
        assertEq(mgr.activeProviderOf(raffleId), providerB);
        assertEq(mgr.activeSeq(raffleId), 1);
        assertEq(mgr.resolveAttempts(raffleId), 2);
    }

    function test_Retry_ThenSettleOnFallback() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolve(raffleId, SALT_1);

        // Deliver a stale callback for the original (A, 1) request — must be ignored.
        _warpStallTimeout();
        vm.prank(RESOLVER);
        mgr.retryResolve(raffleId, SALT_2);

        coord.revealAuto(providerA, 1, _userRandomForAttempt(raffleId, SALT_1, 1));
        assertEq(uint256(mgr.getRaffle(raffleId).status), 1); // still PENDING

        // Deliver the live (B, 1) request → resolves.
        _reveal(raffleId, SALT_2);
        assertEq(uint256(mgr.getRaffle(raffleId).status), 4); // RESOLVED

        _settle(raffleId);
        assertEq(uint256(mgr.getRaffle(raffleId).status), 2); // COMPLETED
    }

    function test_Retry_RevertMaxAttemptsReached() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();

        _resolve(raffleId, SALT_1); // attempt 1
        _warpStallTimeout();
        _retryResolve(raffleId, SALT_2); // attempt 2
        _warpStallTimeout();
        _retryResolve(raffleId, SALT_3); // attempt 3

        assertEq(mgr.resolveAttempts(raffleId), 3);

        _warpStallTimeout();
        vm.prank(RESOLVER);
        vm.expectRevert(LotteryCore.MaxAttemptsReached.selector);
        mgr.retryResolve(raffleId, keccak256("salt_4"));
    }

    function test_Retry_RevertWhenResolved() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolveRevealSettle(raffleId);

        vm.prank(RESOLVER);
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.RaffleNotPendingVrf.selector, raffleId));
        mgr.retryResolve(raffleId, SALT_2);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Failed-callback buffer + poke
    // ═════════════════════════════════════════════════════════════════════════

    function test_FailedCallback_BlocksRetry_ThenPokeRecovers() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolve(raffleId, SALT_1);

        // Simulate a keeper callback that ran out of gas: the coordinator buffers it.
        coord.setCallbackGas(3_000);
        coord.revealAuto(providerA, mgr.activeSeq(raffleId), _userRandom(raffleId, SALT_1));
        (bool exists,) = coord.getFailedCallback(providerA, mgr.activeSeq(raffleId));
        assertTrue(exists);
        assertEq(uint256(mgr.getRaffle(raffleId).status), 1); // still PENDING

        // Retry is refused while a failed callback sits in the buffer.
        _warpStallTimeout();
        vm.prank(RESOLVER);
        vm.expectRevert(LotteryCore.FailedCallbackPending.selector);
        mgr.retryResolve(raffleId, SALT_2);

        // Poke re-delivers with full gas.
        coord.setCallbackGas(0);
        mgr.pokeFailedCallback(raffleId);
        assertEq(uint256(mgr.getRaffle(raffleId).status), 4); // RESOLVED
    }

    function test_Poke_RevertWhenNotPending() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);

        vm.expectRevert(abi.encodeWithSelector(LotteryCore.RaffleNotPendingVrf.selector, raffleId));
        mgr.pokeFailedCallback(raffleId);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Stalled-raffle cancellation
    // ═════════════════════════════════════════════════════════════════════════

    function test_CancelStalled_RevertWhenConditionsNotMet() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolve(raffleId, SALT_1);

        // PENDING, but not stalled past the timeout and attempts < max.
        vm.expectRevert(LotteryCore.StalledConditionNotMet.selector);
        mgr.cancelStalledRaffle(raffleId);
    }

    function test_CancelStalled_AfterAttemptsExhausted() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();

        _resolve(raffleId, SALT_1);
        _warpStallTimeout();
        _retryResolve(raffleId, SALT_2);
        _warpStallTimeout();
        _retryResolve(raffleId, SALT_3);
        _warpStallTimeout();

        mgr.cancelStalledRaffle(raffleId);

        assertEq(uint256(mgr.getRaffle(raffleId).status), 3); // CANCELLED
        assertEq(IERC20(address(prizeToken)).balanceOf(HOST), 50_000e18); // prize returned

        // Refunds enabled.
        vm.prank(ALICE);
        mgr.claimRefund(raffleId);
        assertEq(IERC20(address(usdc)).balanceOf(ALICE), 100_000e18);
    }

    function test_CancelStalled_AfterHardDeadline() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolve(raffleId, SALT_1); // only 1 attempt, but past the hard deadline

        vm.warp(block.timestamp + DURATION + mgr.HARD_DEADLINE() + 1);
        mgr.cancelStalledRaffle(raffleId);

        assertEq(uint256(mgr.getRaffle(raffleId).status), 3); // CANCELLED
    }

    function test_CancelStalled_RevertWhenNotPending() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);

        vm.expectRevert(abi.encodeWithSelector(LotteryCore.RaffleNotPendingVrf.selector, raffleId));
        mgr.cancelStalledRaffle(raffleId);
    }

    function test_LateReveal_AfterCancel_IsNoOp() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolve(raffleId, SALT_1);
        uint64 seq = mgr.activeSeq(raffleId);

        vm.warp(block.timestamp + DURATION + mgr.HARD_DEADLINE() + 1);
        mgr.cancelStalledRaffle(raffleId);

        // Provider finally reveals after the cancel — no state mutation.
        coord.revealAuto(providerA, seq, _userRandom(raffleId, SALT_1));
        assertEq(uint256(mgr.getRaffle(raffleId).status), 3); // CANCELLED
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Cross-provider sequence safety
    // ═════════════════════════════════════════════════════════════════════════

    function test_SameSeqFromTwoProviders_RoutesIndependently() external {
        // Raffle 1 is in flight on provider A at seq 1 and never revealed.
        uint256 raffle1 = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffle1, 5);
        _warpPastExpiry();
        _resolve(raffle1, SALT_1);
        assertEq(mgr.activeProviderOf(raffle1), providerA);
        assertEq(mgr.activeSeq(raffle1), 1);

        // Admin rotates the active provider onto B (both providers number from 1).
        mgr.proposeProviderChange(providerB, address(0));
        vm.warp(block.timestamp + 2 days + 1);
        mgr.applyProviderChange();

        // Raffle 2 now requests on provider B at seq 1 as well.
        uint256 raffle2 = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(BOB, raffle2, 5);
        vm.warp(block.timestamp + DURATION + 1);
        _resolve(raffle2, SALT_1);
        assertEq(mgr.activeProviderOf(raffle2), providerB);
        assertEq(mgr.activeSeq(raffle2), 1);

        // Delivering (A, 1) resolves raffle1, not raffle2.
        coord.revealAuto(providerA, 1, _userRandomForAttempt(raffle1, SALT_1, 1));
        assertEq(uint256(mgr.getRaffle(raffle1).status), 4); // RESOLVED
        assertEq(uint256(mgr.getRaffle(raffle2).status), 1); // untouched PENDING_VRF

        // Delivering (B, 1) resolves raffle2.
        coord.revealAuto(providerB, 1, _userRandomForAttempt(raffle2, SALT_1, 1));
        assertEq(uint256(mgr.getRaffle(raffle2).status), 4); // RESOLVED

        // Both settle to exactly the right winners.
        _settle(raffle1);
        _settle(raffle2);
        assertEq(uint256(mgr.getRaffle(raffle1).status), 2);
        assertEq(uint256(mgr.getRaffle(raffle2).status), 2);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Stale / unexpected callback handling
    // ═════════════════════════════════════════════════════════════════════════

    function test_StaleCallback_UnknownRaffle() external {
        // A callback for a sequence nobody mapped — no-op.
        vm.prank(address(coord));
        mgr.quiverCallback(1, providerA, bytes32(uint256(0xdead)));
        vm.prank(address(coord));
        mgr.quiverCallback(7, providerB, bytes32(uint256(0xdead)));
    }

    function test_Callback_StaleAfterResolution_NoReplay() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolveRevealSettle(raffleId);

        // Re-delivering the same (provider, seq) after settle: mapping cleared on resolve, so
        // the second delivery is an unexpected callback, and state must be untouched.
        vm.prank(address(coord));
        mgr.quiverCallback(1, providerA, bytes32(uint256(1)));
        assertEq(uint256(mgr.getRaffle(raffleId).status), 2); // COMPLETED
    }

    /// @notice The callback must be O(1) in the number of ticket ranges: it only stores the
    ///         randomness and flips status, so a gas-capped keeper reveal succeeds even with
    ///         thousands of ranges (the O(log n) winner scan lives in the permissionless
    ///         settle()).
    function test_Callback_SettlesUnderKeeperGasCap_WithManyRanges() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 10_000, DURATION);

        uint256 buyers = 2_000;
        for (uint256 i = 0; i < buyers; ++i) {
            address buyer = address(uint160(uint256(keccak256(abi.encodePacked("buyer", i)))));
            usdc.transfer(buyer, TICKET_PRICE);
            _enterAsWithPrice(buyer, raffleId, 1, TICKET_PRICE);
        }

        _warpPastExpiry();
        _resolve(raffleId, SALT_1);

        coord.setCallbackGas(100_000); // keeper-style gas cap
        _reveal(raffleId, SALT_1);

        assertEq(uint256(mgr.getRaffle(raffleId).status), 4); // RESOLVED within the cap
    }
}
