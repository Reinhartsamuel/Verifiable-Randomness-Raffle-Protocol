// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {QuiverBaseTest} from "./QuiverBase.t.sol";
import {LotteryCore} from "../src/quiver/LotteryCore.sol";
import {BlacklistERC20} from "./mocks/BlacklistERC20.sol";
import {MaliciousPrizeToken} from "./mocks/MaliciousPrizeToken.sol";
import {RevertingERC721} from "./mocks/RevertingERC721.sol";
import {StandardERC20} from "./mocks/StandardERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice Settlement robustness for LotteryCore: escrow fallbacks, hostile tokens,
///         reentrancy, disposal-once, double-settle and claim paths.
contract LotteryCoreSettlementTest is QuiverBaseTest {
    bytes32 constant SALT_2 = keccak256("salt_2");
    bytes32 constant SALT_3 = keccak256("salt_3");
    // ═════════════════════════════════════════════════════════════════════════
    //  ERC-20 escrow fallback (blacklisted recipients)
    // ═════════════════════════════════════════════════════════════════════════

    function test_Escrow_FullFillBlacklistedWinner() external {
        BlacklistERC20 prize = new BlacklistERC20("BlackPrize", "BLP", 100_000e18);
        prize.transfer(HOST, 50_000e18);

        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 raffleId = mgr.createRaffleERC20(address(prize), PRIZE_AMT, TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();

        _resolve(raffleId, SALT_1);
        _reveal(raffleId, SALT_1);

        prize.setBlacklisted(ALICE, true);
        _settle(raffleId);

        // Prize (minus fee) escrowed for ALICE; fee still paid to treasury in the token.
        uint256 prizeFee = (PRIZE_AMT * FEE_BPS) / 10_000;
        assertEq(uint256(mgr.getRaffle(raffleId).status), 2); // COMPLETED
        assertEq(mgr.claimable(address(prize), ALICE), PRIZE_AMT - prizeFee);
        assertEq(IERC20(address(prize)).balanceOf(ALICE), 0);
        assertEq(IERC20(address(prize)).balanceOf(TREASURY), prizeFee);
        // The escrowed winner share stays on the contract until claimed.
        assertEq(IERC20(address(prize)).balanceOf(address(mgr)), PRIZE_AMT - prizeFee);

        // Unblock and claim.
        prize.setBlacklisted(ALICE, false);
        vm.prank(ALICE);
        mgr.claim(address(prize));
        assertEq(IERC20(address(prize)).balanceOf(ALICE), PRIZE_AMT - prizeFee);
        assertEq(IERC20(address(prize)).balanceOf(address(mgr)), 0);
        assertEq(mgr.claimable(address(prize), ALICE), 0);
    }

    function test_Escrow_ReturnFalseToken() external {
        MaliciousPrizeToken prize = new MaliciousPrizeToken("BadPrize", "BAD", 100_000e18);
        prize.transfer(HOST, 50_000e18);

        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 raffleId = mgr.createRaffleERC20(address(prize), PRIZE_AMT, TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolve(raffleId, SALT_1);
        _reveal(raffleId, SALT_1);

        prize.setMode(MaliciousPrizeToken.Mode.ReturnFalse);
        _settle(raffleId);

        uint256 prizeFee = (PRIZE_AMT * FEE_BPS) / 10_000;
        assertEq(mgr.claimable(address(prize), ALICE), PRIZE_AMT - prizeFee);

        prize.setMode(MaliciousPrizeToken.Mode.Normal);
        vm.prank(ALICE);
        mgr.claim(address(prize));
        assertEq(IERC20(address(prize)).balanceOf(ALICE), PRIZE_AMT - prizeFee);
    }

    function test_Escrow_RevertingToken() external {
        MaliciousPrizeToken prize = new MaliciousPrizeToken("RevertPrize", "REV", 100_000e18);
        prize.transfer(HOST, 50_000e18);

        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 raffleId = mgr.createRaffleERC20(address(prize), PRIZE_AMT, TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolve(raffleId, SALT_1);
        _reveal(raffleId, SALT_1);

        prize.setMode(MaliciousPrizeToken.Mode.Revert);
        _settle(raffleId); // must not brick

        assertEq(mgr.claimable(address(prize), ALICE), PRIZE_AMT - (PRIZE_AMT * FEE_BPS) / 10_000);

        prize.setMode(MaliciousPrizeToken.Mode.Normal);
        vm.prank(ALICE);
        mgr.claim(address(prize));
    }

    function test_Escrow_ReturndataBombToken() external {
        MaliciousPrizeToken prize = new MaliciousPrizeToken("BombPrize", "BMB", 100_000e18);
        prize.transfer(HOST, 50_000e18);

        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 raffleId = mgr.createRaffleERC20(address(prize), PRIZE_AMT, TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolve(raffleId, SALT_1);
        _reveal(raffleId, SALT_1);

        // 64 KiB returndata on every transfer must not brick settlement.
        prize.setMode(MaliciousPrizeToken.Mode.ReturndataBomb);
        _settle(raffleId);

        assertEq(mgr.claimable(address(prize), ALICE), PRIZE_AMT - (PRIZE_AMT * FEE_BPS) / 10_000);

        prize.setMode(MaliciousPrizeToken.Mode.Normal);
        vm.prank(ALICE);
        mgr.claim(address(prize));
        assertEq(IERC20(address(prize)).balanceOf(ALICE), PRIZE_AMT - (PRIZE_AMT * FEE_BPS) / 10_000);
    }

    function test_Claim_RevertsWhenNothingClaimable() external {
        vm.prank(ALICE);
        vm.expectRevert(LotteryCore.NoClaimable.selector);
        mgr.claim(address(usdc));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  NFT escrow fallback
    // ═════════════════════════════════════════════════════════════════════════

    function test_NftEscrow_FullFill() external {
        RevertingERC721 badNft = new RevertingERC721("BadNFT", "BNFT");
        badNft.setRevertOnTransfer(false); // custody must succeed at create time
        badNft.mint(HOST, 111);

        vm.prank(HOST);
        IERC721(address(badNft)).approve(address(mgr), 111);
        vm.prank(HOST);
        uint256 raffleId = mgr.createRaffleERC721(address(badNft), 111, TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();

        badNft.setRevertOnTransfer(true); // payouts now fail → escrow path
        _resolve(raffleId, SALT_1);
        _reveal(raffleId, SALT_1);
        _settle(raffleId);

        // transferFrom reverts → NFT escrowed for the winner; host still paid in USDC.
        assertEq(IERC721(address(badNft)).ownerOf(111), address(mgr));
        assertEq(mgr.nftClaimant(address(badNft), 111), ALICE);
        assertEq(IERC20(address(usdc)).balanceOf(HOST), (TICKET_PRICE * 5) * (10_000 - FEE_BPS) / 10_000);

        // Unblock and claim.
        badNft.setRevertOnTransfer(false);
        vm.prank(ALICE);
        mgr.claimNft(address(badNft), 111);
        assertEq(IERC721(address(badNft)).ownerOf(111), ALICE);
        assertEq(mgr.nftClaimant(address(badNft), 111), address(0));
    }

    function test_NftEscrow_Underfilled_ReturnedToHost() external {
        RevertingERC721 badNft = new RevertingERC721("BadNFT2", "BNFT2");
        badNft.setRevertOnTransfer(false); // custody must succeed at create time
        badNft.mint(HOST, 222);

        vm.prank(HOST);
        IERC721(address(badNft)).approve(address(mgr), 222);
        vm.prank(HOST);
        uint256 raffleId = mgr.createRaffleERC721(address(badNft), 222, TICKET_PRICE, 100, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();

        badNft.setRevertOnTransfer(true); // payouts now fail → escrow path
        _resolve(raffleId, SALT_1);
        _reveal(raffleId, SALT_1);
        _settle(raffleId);

        // Underfilled: the NFT return to the host escrowed; winner took the pool.
        assertEq(mgr.nftClaimant(address(badNft), 222), HOST);
        assertEq(IERC721(address(badNft)).ownerOf(222), address(mgr));

        badNft.setRevertOnTransfer(false);
        vm.prank(HOST);
        mgr.claimNft(address(badNft), 222);
        assertEq(IERC721(address(badNft)).ownerOf(222), HOST);
    }

    function test_ClaimNft_RevertsForNonClaimant() external {
        uint256 raffleId = _createERC721RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolveRevealSettle(raffleId);

        // MockERC721 always transfers fine, so nothing is escrowed.
        vm.prank(BOB);
        vm.expectRevert(LotteryCore.NoNftClaim.selector);
        mgr.claimNft(address(nft), NFT_TOKEN_ID_2);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Reentrancy attacks
    // ═════════════════════════════════════════════════════════════════════════

    function test_Reentrancy_SettleReenter_Safe() external {
        MaliciousPrizeToken prize = new MaliciousPrizeToken("RePrize", "RPR", 100_000e18);
        prize.transfer(HOST, 50_000e18);

        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 raffleId = mgr.createRaffleERC20(address(prize), PRIZE_AMT, TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolve(raffleId, SALT_1);
        _reveal(raffleId, SALT_1);

        // Prize token re-enters settle() during the payout transfer.
        prize.setReenter(address(mgr), abi.encodeWithSelector(LotteryCore.settle.selector, raffleId));
        prize.setMode(MaliciousPrizeToken.Mode.Reenter);
        _settle(raffleId);

        uint256 prizeFee = (PRIZE_AMT * FEE_BPS) / 10_000;
        assertEq(uint256(mgr.getRaffle(raffleId).status), 2); // COMPLETED
        assertEq(IERC20(address(prize)).balanceOf(ALICE), PRIZE_AMT - prizeFee);
        assertEq(mgr.claimable(address(prize), ALICE), 0);
        assertTrue(mgr.prizeDisposed(raffleId));

        // The inner reentrant settle() reverted; a follow-up settle also reverts.
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.RaffleNotResolved.selector, raffleId));
        mgr.settle(raffleId);
    }

    function test_Reentrancy_ClaimReenter_Safe() external {
        // Build an escrowed balance, then re-enter claim() from the token's transfer hook.
        MaliciousPrizeToken prize = new MaliciousPrizeToken("ReClaim", "RCL", 100_000e18);
        prize.transfer(HOST, 50_000e18);

        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 raffleId = mgr.createRaffleERC20(address(prize), PRIZE_AMT, TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolve(raffleId, SALT_1);
        _reveal(raffleId, SALT_1);

        prize.setMode(MaliciousPrizeToken.Mode.Revert);
        _settle(raffleId); // escrowed
        assertEq(mgr.claimable(address(prize), ALICE), PRIZE_AMT - (PRIZE_AMT * FEE_BPS) / 10_000);

        prize.setReenter(address(mgr), abi.encodeWithSelector(LotteryCore.claim.selector, address(prize)));
        prize.setMode(MaliciousPrizeToken.Mode.Reenter);

        vm.prank(ALICE);
        mgr.claim(address(prize));

        assertEq(mgr.claimable(address(prize), ALICE), 0);
        assertEq(IERC20(address(prize)).balanceOf(ALICE), PRIZE_AMT - (PRIZE_AMT * FEE_BPS) / 10_000);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Payment-token escrow (dedicated manager with blacklist-capable payment token)
    // ═════════════════════════════════════════════════════════════════════════

    function test_PaymentTokenEscrow_WhenWinnerBlacklisted() external {
        BlacklistERC20 pay = new BlacklistERC20("PayBlack", "PYB", 1_000_000e18);
        pay.transfer(ALICE, 100_000e18);

        LotteryCore local = new LotteryCore(address(coord), providerA, providerB, address(pay), TREASURY, SIGNER, OWNER);
        local.setResolver(RESOLVER, true);

        // Host = this test; platform fee defaults to 0 on the fresh instance.
        IERC20(address(prizeToken)).approve(address(local), PRIZE_AMT);
        uint256 raffleId = local.createRaffleERC20(address(prizeToken), PRIZE_AMT, TICKET_PRICE, 100, DURATION);

        vm.startPrank(ALICE);
        IERC20(address(pay)).approve(address(local), TICKET_PRICE * 5);
        local.enterRaffle(raffleId, 5);
        vm.stopPrank();

        pay.setBlacklisted(ALICE, true);

        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(RESOLVER);
        local.resolveRaffle(raffleId, SALT_1);

        bytes32 userRandom = keccak256(abi.encode(SALT_1, raffleId, uint8(1), address(local), block.chainid));
        coord.revealAuto(providerA, local.activeSeq(raffleId), userRandom);
        local.settle(raffleId);

        // Underfilled: prize back to host; the payment pool for the winner is escrowed.
        uint256 pool = TICKET_PRICE * 5;
        assertEq(local.claimable(address(pay), ALICE), pool);
        assertEq(IERC20(address(pay)).balanceOf(ALICE), 100_000e18 - pool);
        assertEq(IERC20(address(prizeToken)).balanceOf(OWNER), 50_000e18);

        pay.setBlacklisted(ALICE, false);
        vm.prank(ALICE);
        local.claim(address(pay));
        assertEq(IERC20(address(pay)).balanceOf(ALICE), 100_000e18);
        assertEq(local.claimable(address(pay), ALICE), 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Disposal-once & terminal-state guards
    // ═════════════════════════════════════════════════════════════════════════

    function test_PrizeDisposedOnce_Underfilled() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 100, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolve(raffleId, SALT_1);
        _reveal(raffleId, SALT_1);
        _settle(raffleId);

        assertTrue(mgr.prizeDisposed(raffleId));
        assertEq(IERC20(address(prizeToken)).balanceOf(address(mgr)), 0);
        assertEq(IERC20(address(prizeToken)).balanceOf(HOST), 50_000e18);
    }

    function test_NoSettlementAfterCancel() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolve(raffleId, SALT_1);

        vm.warp(block.timestamp + DURATION + mgr.HARD_DEADLINE() + 1);
        mgr.cancelStalledRaffle(raffleId);

        vm.expectRevert(abi.encodeWithSelector(LotteryCore.RaffleNotResolved.selector, raffleId));
        mgr.settle(raffleId);
    }

    function test_ResolveTwiceAcrossLifecycle_NoResolveAfterComplete() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolveRevealSettle(raffleId);

        vm.prank(RESOLVER);
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.RaffleNotOpen.selector, raffleId));
        mgr.resolveRaffle(raffleId, SALT_2);
    }

    function test_RefundAndPrizeConsistency_AfterExhaustedStall() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolve(raffleId, SALT_1);
        vm.warp(block.timestamp + mgr.STALL_TIMEOUT());
        _retryResolve(raffleId, SALT_2);
        vm.warp(block.timestamp + mgr.STALL_TIMEOUT());
        _retryResolve(raffleId, SALT_3);
        vm.warp(block.timestamp + mgr.STALL_TIMEOUT());

        mgr.cancelStalledRaffle(raffleId);

        // Prize exactly once to host.
        assertEq(IERC20(address(prizeToken)).balanceOf(HOST), 50_000e18);
        assertEq(IERC20(address(prizeToken)).balanceOf(address(mgr)), 0);

        // Full refund to the entrant.
        vm.prank(ALICE);
        mgr.claimRefund(raffleId);
        assertEq(IERC20(address(usdc)).balanceOf(ALICE), 100_000e18);
        assertEq(IERC20(address(usdc)).balanceOf(address(mgr)), 0);
    }
}
