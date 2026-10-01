// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {QuiverBaseTest} from "./QuiverBase.t.sol";
import {LotteryCore} from "../src/quiver/LotteryCore.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Fuzz coverage for LotteryCore winner selection and terminal-state solvency.
contract LotteryCoreFuzzTest is QuiverBaseTest {
    bytes32 constant SALT_2 = keccak256("salt_2");
    bytes32 constant SALT_3 = keccak256("salt_3");

    struct RefRange {
        address owner;
        uint96 endTicket;
    }

    address internal constant DAVE = address(0xD4A7E);

    function _refWinner(RefRange[] storage refs, uint256 winningTicket) internal view returns (address) {
        for (uint256 i = 0; i < refs.length; ++i) {
            if (winningTicket <= refs[i].endTicket) return refs[i].owner;
        }
        revert("ref winner not found");
    }

    /// @notice Winner selection must equal a linear scan over the exact range structure
    ///         (including consecutive-purchase aggregation) for any entry pattern.
    function testFuzz_WinnerMatchesLinearReference(uint8 events, uint8 buyerSeed, uint8 ticketSeed) external {
        events = uint8(bound(events, 1, 12));
        address[4] memory users = [ALICE, BOB, CHARLIE, DAVE];
        for (uint256 i = 0; i < users.length; ++i) {
            if (usdc.balanceOf(users[i]) < 200_000e18) {
                usdc.transfer(users[i], 200_000e18 - usdc.balanceOf(users[i]));
            }
        }

        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 500, DURATION);

        RefRange[] storage refs = _refRanges();
        uint96 totalRef;

        for (uint256 e = 0; e < events; ++e) {
            address buyer = users[buyerSeed % 4];
            buyerSeed = uint8((uint256(buyerSeed) * 31 + 7) % 251);
            uint256 tickets = 1 + (ticketSeed % 12);
            ticketSeed = uint8((uint256(ticketSeed) * 13 + 5) % 251);

            if (totalRef + tickets > 500) continue;

            uint256 cost = tickets * TICKET_PRICE;
            vm.startPrank(buyer);
            IERC20(address(usdc)).approve(address(mgr), cost);
            mgr.enterRaffle(raffleId, tickets);
            vm.stopPrank();

            totalRef += uint96(tickets);
            if (refs.length > 0 && refs[refs.length - 1].owner == buyer) {
                refs[refs.length - 1].endTicket = totalRef;
            } else {
                refs.push(RefRange({owner: buyer, endTicket: totalRef}));
            }
        }

        vm.assume(totalRef > 0);

        vm.warp(block.timestamp + DURATION + 1);
        _resolve(raffleId, SALT_1);
        _reveal(raffleId, SALT_1);
        _settle(raffleId);

        assertEq(uint256(mgr.getRaffle(raffleId).status), 2); // COMPLETED

        bytes32 rnd = mgr.raffleRandomness(raffleId);
        uint256 winningTicket = (uint256(rnd) % totalRef) + 1;
        address expected = _refWinner(refs, winningTicket);

        uint256 paymentPool = uint256(totalRef) * TICKET_PRICE;
        uint256 fee = (paymentPool * FEE_BPS) / 10_000;

        // Underfilled (total < 500): the winner takes the payment pool minus the fee.
        for (uint256 i = 0; i < users.length; ++i) {
            address u = users[i];
            uint256 paid = _paidBy(refs, u);
            uint256 payout = (u == expected) ? (paymentPool - fee) : 0;
            assertEq(usdc.balanceOf(u), 200_000e18 - paid + payout);
        }
        // Prize went back to the host, not to any entrant.
        assertEq(IERC20(address(prizeToken)).balanceOf(HOST), 50_000e18);
    }

    /// @notice After any terminal state reached through a random lifecycle, no funds are
    ///         stuck on the manager and totals reconcile (no double spends, no trapped prize).
    function testFuzz_RandomLifecycle_TerminalSolvency(uint8 scenario) external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 100, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _enterAs(BOB, raffleId, 3);

        uint8 s = scenario % 3;

        if (s == 0) {
            // Full happy path.
            _warpPastExpiry();
            _resolve(raffleId, SALT_1);
            _reveal(raffleId, SALT_1);
            _settle(raffleId);
            assertEq(uint256(mgr.getRaffle(raffleId).status), 2);
        } else if (s == 1) {
            // Expiry → grace → permissionless cancel → everyone refunded.
            vm.warp(block.timestamp + DURATION + mgr.RESOLVE_GRACE() + 1);
            mgr.cancelExpiredRaffle(raffleId);
            assertEq(uint256(mgr.getRaffle(raffleId).status), 3);
            vm.prank(ALICE);
            mgr.claimRefund(raffleId);
            vm.prank(BOB);
            mgr.claimRefund(raffleId);
        } else {
            // Requests stall → attempts exhausted → stalled cancel → refunds.
            _warpPastExpiry();
            _resolve(raffleId, SALT_1);
            vm.warp(block.timestamp + mgr.STALL_TIMEOUT());
            _retryResolve(raffleId, SALT_2);
            vm.warp(block.timestamp + mgr.STALL_TIMEOUT());
            _retryResolve(raffleId, SALT_3);
            vm.warp(block.timestamp + mgr.STALL_TIMEOUT());
            mgr.cancelStalledRaffle(raffleId);
            assertEq(uint256(mgr.getRaffle(raffleId).status), 3);
            vm.prank(ALICE);
            mgr.claimRefund(raffleId);
            vm.prank(BOB);
            mgr.claimRefund(raffleId);
        }

        // Solvency: the manager holds neither the prize nor any participant payment.
        assertEq(IERC20(address(prizeToken)).balanceOf(address(mgr)), 0);
        assertEq(IERC20(address(usdc)).balanceOf(address(mgr)), 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Internal state for fuzz reference bookkeeping
    // ═════════════════════════════════════════════════════════════════════════

    RefRange[] internal _refRangesCache;

    function _refRanges() internal returns (RefRange[] storage) {
        delete _refRangesCache;
        return _refRangesCache;
    }

    function _paidBy(RefRange[] storage refs, address who) internal view returns (uint256) {
        uint256 total;
        uint256 prevEnd;
        for (uint256 i = 0; i < refs.length; ++i) {
            if (refs[i].owner == who) {
                total += refs[i].endTicket - prevEnd; // tickets in this range
            }
            prevEnd = refs[i].endTicket;
        }
        return total * TICKET_PRICE;
    }
}
