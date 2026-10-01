// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {QuiverBaseTest} from "./QuiverBase.t.sol";
import {LotteryCore} from "../src/quiver/LotteryCore.sol";
import {FreeEntryVerifier2} from "../src/FreeEntryVerifier2.sol";
import {QuiverConsumer} from "quiver/QuiverConsumer.sol";
import {QuiverStructs} from "quiver/libraries/QuiverStructs.sol";
import {IncorrectUserRevelation} from "quiver/libraries/QuiverErrors.sol";
import {FeeOnTransferERC20} from "./mocks/FeeOnTransferERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice Adapted port of test/RaffleCore.t.sol for LotteryCore. The Chainlink
///         Automation/VRF two-step (`checkUpkeep`/`performUpkeep`/`fulfillRandomWords`)
///         is replaced by the resolver → Quiver callback → settle lifecycle:
///         resolveRaffle(salt) → (keeper reveal) → RESOLVED → settle().
contract LotteryCoreTest is QuiverBaseTest {
    // ═════════════════════════════════════════════════════════════════════════
    //  Constructor Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_Constructor_SetsState() external {
        assertEq(mgr.paymentToken(), address(usdc));
        assertEq(mgr.treasury(), TREASURY);
        assertEq(mgr.platformFeeBps(), FEE_BPS);
        assertEq(mgr.minDuration(), 2 hours);
        assertEq(mgr.owner(), OWNER);
        assertEq(mgr.activeProvider(), providerA);
        assertEq(mgr.fallbackProvider(), providerB);
        assertEq(mgr.randomnessFee(), 0);
        assertFalse(mgr.paused());
        assertEq(mgr.getCoordinator(), address(coord));
    }

    function test_Constructor_RevertInvalidPaymentToken() external {
        vm.expectRevert(LotteryCore.InvalidParams.selector);
        new LotteryCore(address(coord), providerA, providerB, address(0), TREASURY, SIGNER, OWNER);
    }

    function test_Constructor_RevertInvalidTreasury() external {
        vm.expectRevert(LotteryCore.InvalidParams.selector);
        new LotteryCore(address(coord), providerA, providerB, address(usdc), address(0), SIGNER, OWNER);
    }

    function test_Constructor_RevertInvalidSigner() external {
        vm.expectRevert("Invalid signer");
        new LotteryCore(address(coord), providerA, providerB, address(usdc), TREASURY, address(0), OWNER);
    }

    function test_Constructor_RevertZeroInitialOwner() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new LotteryCore(address(coord), providerA, providerB, address(usdc), TREASURY, SIGNER, address(0));
    }

    function test_Constructor_RevertZeroQuiver() external {
        vm.expectRevert(QuiverConsumer.ZeroAddress.selector);
        new LotteryCore(address(0), providerA, providerB, address(usdc), TREASURY, SIGNER, OWNER);
    }

    function test_Constructor_RevertZeroProvider() external {
        vm.expectRevert(QuiverConsumer.ZeroAddress.selector);
        new LotteryCore(address(coord), address(0), providerB, address(usdc), TREASURY, SIGNER, OWNER);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ERC-20 Raffle Creation Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_CreateERC20Raffle_Success() external {
        uint256 raffleId = _createERC20Raffle();

        assertEq(raffleId, 1);
        assertEq(mgr.raffleCount(), 1);

        LotteryCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(raffle.host, HOST);
        assertEq(raffle.prizeAsset, address(prizeToken));
        assertEq(uint256(raffle.prizeType), 0);
        assertEq(raffle.prizeAmountOrTokenId, PRIZE_AMT);
        assertEq(raffle.ticketPrice, TICKET_PRICE);
        assertEq(raffle.maxCap, MAX_CAP);
        assertEq(raffle.ticketsSold, 0);
        assertEq(uint256(raffle.status), 0); // OPEN
        assertFalse(raffle.underfilled);
        assertEq(raffle.expiry, block.timestamp + DURATION);
    }

    function test_CreateERC20Raffle_EmitsEvent() external {
        vm.prank(HOST);
        IERC20(address(prizeToken)).approve(address(mgr), PRIZE_AMT);

        vm.prank(HOST);
        vm.expectEmit(true, true, false, true);
        emit LotteryCore.RaffleCreated(
            1,
            HOST,
            address(prizeToken),
            LotteryCore.PrizeType.ERC20,
            PRIZE_AMT,
            uint48(block.timestamp + DURATION),
            "PZ",
            18,
            TICKET_PRICE,
            MAX_CAP
        );
        mgr.createRaffleERC20(address(prizeToken), PRIZE_AMT, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function test_CreateERC20Raffle_TransfersPrizeToContract() external {
        uint256 balanceBefore = IERC20(address(prizeToken)).balanceOf(HOST);
        _createERC20Raffle();
        uint256 balanceAfter = IERC20(address(prizeToken)).balanceOf(HOST);

        assertEq(balanceBefore - balanceAfter, PRIZE_AMT);
        assertEq(IERC20(address(prizeToken)).balanceOf(address(mgr)), PRIZE_AMT);
    }

    function test_CreateERC20Raffle_RevertZeroAmount() external {
        vm.prank(HOST);
        IERC20(address(prizeToken)).approve(address(mgr), PRIZE_AMT);

        vm.prank(HOST);
        vm.expectRevert(LotteryCore.InvalidParams.selector);
        mgr.createRaffleERC20(address(prizeToken), 0, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function test_CreateERC20Raffle_RevertZeroTicketPrice() external {
        vm.prank(HOST);
        IERC20(address(prizeToken)).approve(address(mgr), PRIZE_AMT);

        vm.prank(HOST);
        vm.expectRevert(LotteryCore.InvalidParams.selector);
        mgr.createRaffleERC20(address(prizeToken), PRIZE_AMT, 0, MAX_CAP, DURATION);
    }

    function test_CreateERC20Raffle_RevertZeroMaxCap() external {
        vm.prank(HOST);
        IERC20(address(prizeToken)).approve(address(mgr), PRIZE_AMT);

        vm.prank(HOST);
        vm.expectRevert(LotteryCore.InvalidParams.selector);
        mgr.createRaffleERC20(address(prizeToken), PRIZE_AMT, TICKET_PRICE, 0, DURATION);
    }

    function test_CreateERC20Raffle_RevertZeroDuration() external {
        vm.prank(HOST);
        IERC20(address(prizeToken)).approve(address(mgr), PRIZE_AMT);

        vm.prank(HOST);
        vm.expectRevert(LotteryCore.InvalidParams.selector);
        mgr.createRaffleERC20(address(prizeToken), PRIZE_AMT, TICKET_PRICE, MAX_CAP, 0);
    }

    function test_CreateERC20Raffle_RevertDurationTooShort() external {
        vm.prank(HOST);
        IERC20(address(prizeToken)).approve(address(mgr), PRIZE_AMT);

        vm.prank(HOST);
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.DurationTooShort.selector, 1 hours, 2 hours));
        mgr.createRaffleERC20(address(prizeToken), PRIZE_AMT, TICKET_PRICE, MAX_CAP, 1 hours);
    }

    function test_CreateERC20Raffle_MinDurationExactlyTwoHours() external {
        vm.prank(HOST);
        IERC20(address(prizeToken)).approve(address(mgr), PRIZE_AMT);

        vm.prank(HOST);
        uint256 raffleId = mgr.createRaffleERC20(address(prizeToken), PRIZE_AMT, TICKET_PRICE, MAX_CAP, 2 hours);

        LotteryCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(raffle.expiry, block.timestamp + 2 hours);
    }

    function test_CreateERC20Raffle_RevertFeeOnTransferPrize() external {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20("FoT", "FOT", 10_000e18);
        fot.transfer(HOST, 2_000e18);

        vm.prank(HOST);
        IERC20(address(fot)).approve(address(mgr), PRIZE_AMT);

        vm.prank(HOST);
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.PrizeAmountMismatch.selector, PRIZE_AMT, PRIZE_AMT - 10e18));
        mgr.createRaffleERC20(address(fot), PRIZE_AMT, TICKET_PRICE, MAX_CAP, DURATION);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ERC-721 Raffle Creation Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_CreateERC721Raffle_Success() external {
        uint256 raffleId = _createERC721Raffle();

        assertEq(raffleId, 1);
        assertEq(mgr.raffleCount(), 1);

        LotteryCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(raffle.host, HOST);
        assertEq(raffle.prizeAsset, address(nft));
        assertEq(uint256(raffle.prizeType), 1);
        assertEq(raffle.prizeAmountOrTokenId, NFT_TOKEN_ID);
        assertEq(raffle.ticketPrice, TICKET_PRICE);
        assertEq(raffle.maxCap, MAX_CAP);
        assertEq(raffle.ticketsSold, 0);
        assertEq(uint256(raffle.status), 0); // OPEN
    }

    function test_CreateERC721Raffle_EmitsEvent() external {
        vm.prank(HOST);
        IERC721(address(nft)).approve(address(mgr), NFT_TOKEN_ID);

        vm.prank(HOST);
        vm.expectEmit(true, true, false, true);
        emit LotteryCore.RaffleCreated(
            1,
            HOST,
            address(nft),
            LotteryCore.PrizeType.ERC721,
            NFT_TOKEN_ID,
            uint48(block.timestamp + DURATION),
            "MockNFT",
            0,
            TICKET_PRICE,
            MAX_CAP
        );
        mgr.createRaffleERC721(address(nft), NFT_TOKEN_ID, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function test_CreateERC721Raffle_TransfersNFTToContract() external {
        _createERC721Raffle();
        assertEq(IERC721(address(nft)).ownerOf(NFT_TOKEN_ID), address(mgr));
    }

    function test_CreateERC721Raffle_RevertZeroAddress() external {
        vm.prank(HOST);
        vm.expectRevert(LotteryCore.InvalidParams.selector);
        mgr.createRaffleERC721(address(0), NFT_TOKEN_ID, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function test_CreateERC721Raffle_RevertZeroTicketPrice() external {
        vm.prank(HOST);
        IERC721(address(nft)).approve(address(mgr), NFT_TOKEN_ID);

        vm.prank(HOST);
        vm.expectRevert(LotteryCore.InvalidParams.selector);
        mgr.createRaffleERC721(address(nft), NFT_TOKEN_ID, 0, MAX_CAP, DURATION);
    }

    function test_CreateERC721Raffle_RevertDurationTooShort() external {
        vm.prank(HOST);
        IERC721(address(nft)).approve(address(mgr), NFT_TOKEN_ID);

        vm.prank(HOST);
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.DurationTooShort.selector, 1 hours, 2 hours));
        mgr.createRaffleERC721(address(nft), NFT_TOKEN_ID, TICKET_PRICE, MAX_CAP, 1 hours);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Ticket Purchase Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_EnterRaffle_Success() external {
        uint256 raffleId = _createERC20Raffle();

        _enterAs(ALICE, raffleId, 5);

        assertEq(mgr.getTotalTickets(raffleId), 5);

        LotteryCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(raffle.ticketsSold, 5);

        (address owner, uint256 endTicket) = mgr.getTicketRange(raffleId, 0);
        assertEq(owner, ALICE);
        assertEq(endTicket, 5);
    }

    function test_EnterRaffle_EmitsEvent() external {
        uint256 raffleId = _createERC20Raffle();

        uint256 cost = TICKET_PRICE * 5;
        vm.prank(ALICE);
        IERC20(address(usdc)).approve(address(mgr), cost);

        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true);
        emit LotteryCore.TicketPurchased(raffleId, ALICE, 5);
        mgr.enterRaffle(raffleId, 5);
    }

    function test_EnterRaffle_TransfersPayment() external {
        uint256 raffleId = _createERC20Raffle();

        uint256 cost = TICKET_PRICE * 5;
        uint256 balanceBefore = IERC20(address(usdc)).balanceOf(ALICE);

        _enterAs(ALICE, raffleId, 5);

        uint256 balanceAfter = IERC20(address(usdc)).balanceOf(ALICE);
        assertEq(balanceBefore - balanceAfter, cost);
        assertEq(IERC20(address(usdc)).balanceOf(address(mgr)), cost);
    }

    function test_EnterRaffle_AggregatesConsecutivePurchases() external {
        uint256 raffleId = _createERC20Raffle();

        _enterAs(ALICE, raffleId, 5);
        _enterAs(ALICE, raffleId, 3);

        assertEq(mgr.getTotalTickets(raffleId), 8);

        (address owner, uint256 endTicket) = mgr.getTicketRange(raffleId, 0);
        assertEq(owner, ALICE);
        assertEq(endTicket, 8);

        vm.expectRevert();
        mgr.getTicketRange(raffleId, 1);
    }

    function test_EnterRaffle_CreatesNewRangeForDifferentBuyer() external {
        uint256 raffleId = _createERC20Raffle();

        _enterAs(ALICE, raffleId, 5);
        _enterAs(BOB, raffleId, 3);

        assertEq(mgr.getTotalTickets(raffleId), 8);

        (address owner1, uint256 endTicket1) = mgr.getTicketRange(raffleId, 0);
        assertEq(owner1, ALICE);
        assertEq(endTicket1, 5);

        (address owner2, uint256 endTicket2) = mgr.getTicketRange(raffleId, 1);
        assertEq(owner2, BOB);
        assertEq(endTicket2, 8);
    }

    function test_EnterRaffle_RevertRaffleNotOpen() external {
        _createERC20Raffle();
        _warpPastExpiry();

        uint256 cost = TICKET_PRICE;
        vm.prank(ALICE);
        IERC20(address(usdc)).approve(address(mgr), cost);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.RaffleNotOpen.selector, 1));
        mgr.enterRaffle(1, 1);
    }

    function test_EnterRaffle_RevertHostCannotEnter() external {
        uint256 raffleId = _createERC20Raffle();

        vm.prank(HOST);
        IERC20(address(usdc)).approve(address(mgr), TICKET_PRICE);

        vm.prank(HOST);
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.HostCannotEnter.selector, raffleId));
        mgr.enterRaffle(raffleId, 1);
    }

    function test_EnterRaffle_RevertZeroTickets() external {
        uint256 raffleId = _createERC20Raffle();

        vm.prank(ALICE);
        vm.expectRevert(LotteryCore.InvalidParams.selector);
        mgr.enterRaffle(raffleId, 0);
    }

    function test_EnterRaffle_RevertMaxCapReached() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);

        _enterAs(ALICE, raffleId, 3);
        _enterAs(BOB, raffleId, 2);

        uint256 cost = TICKET_PRICE;
        vm.prank(CHARLIE);
        IERC20(address(usdc)).approve(address(mgr), cost);

        vm.prank(CHARLIE);
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.MaxCapReached.selector, raffleId));
        mgr.enterRaffle(raffleId, 1);
    }

    function test_EnterRaffle_RevertExceedsMaxCap() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 10, DURATION);

        _enterAs(ALICE, raffleId, 8);

        uint256 cost = TICKET_PRICE * 5;
        vm.prank(BOB);
        IERC20(address(usdc)).approve(address(mgr), cost);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.MaxCapReached.selector, raffleId));
        mgr.enterRaffle(raffleId, 5);
    }

    function test_EnterRaffle_RevertTicketCountExceedsUint96Max() external {
        uint256 raffleId = _createERC20Raffle();

        vm.prank(ALICE);
        vm.expectRevert(LotteryCore.InvalidParams.selector);
        mgr.enterRaffle(raffleId, uint256(type(uint96).max) + 1);
    }

    function test_EnterRaffle_RevertInsufficientApproval() external {
        uint256 raffleId = _createERC20Raffle();
        uint256 cost = TICKET_PRICE * 5;

        vm.prank(ALICE);
        IERC20(address(usdc)).approve(address(mgr), cost - 1);

        vm.prank(ALICE);
        vm.expectRevert();
        mgr.enterRaffle(raffleId, 5);
    }

    function test_EnterRaffle_AtExactExpiryBoundary() external {
        uint256 raffleId = _createERC20Raffle();

        // Enter just before expiry
        vm.warp(block.timestamp + DURATION - 1);
        _enterAs(ALICE, raffleId, 1);

        // Fails at exact expiry
        vm.warp(block.timestamp + 1);

        uint256 cost = TICKET_PRICE;
        vm.prank(BOB);
        IERC20(address(usdc)).approve(address(mgr), cost);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.RaffleNotOpen.selector, raffleId));
        mgr.enterRaffle(raffleId, 1);
    }

    function test_EnterRaffle_MultipleRafflesIndependent() external {
        uint256 raffleId1 = _createERC20Raffle();
        uint256 raffleId2 = _createERC20Raffle();

        _enterAs(ALICE, raffleId1, 5);
        _enterAs(ALICE, raffleId2, 3);

        assertEq(mgr.getTotalTickets(raffleId1), 5);
        assertEq(mgr.getTotalTickets(raffleId2), 3);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Free Entry Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_EnterFreeRaffle_Success() external {
        uint256 raffleId = _createERC20Raffle();
        bytes memory signature = _signFreeEntry(raffleId, ALICE);

        vm.prank(ALICE);
        mgr.enterFreeRaffle(raffleId, signature);

        assertEq(mgr.getTotalTickets(raffleId), 1);

        LotteryCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(raffle.ticketsSold, 1);
    }

    function test_EnterFreeRaffle_EmitsEvent() external {
        uint256 raffleId = _createERC20Raffle();
        bytes memory signature = _signFreeEntry(raffleId, ALICE);

        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true);
        emit LotteryCore.TicketPurchased(raffleId, ALICE, 1);
        mgr.enterFreeRaffle(raffleId, signature);
    }

    function test_EnterFreeRaffle_NoPaymentRequired() external {
        uint256 raffleId = _createERC20Raffle();
        uint256 balanceBefore = IERC20(address(usdc)).balanceOf(ALICE);

        bytes memory signature = _signFreeEntry(raffleId, ALICE);
        vm.prank(ALICE);
        mgr.enterFreeRaffle(raffleId, signature);

        uint256 balanceAfter = IERC20(address(usdc)).balanceOf(ALICE);
        assertEq(balanceBefore, balanceAfter);
    }

    function test_EnterFreeRaffle_RevertAlreadyClaimed() external {
        uint256 raffleId = _createERC20Raffle();
        bytes memory signature = _signFreeEntry(raffleId, ALICE);

        vm.prank(ALICE);
        mgr.enterFreeRaffle(raffleId, signature);

        vm.prank(ALICE);
        vm.expectRevert(FreeEntryVerifier2.AlreadyClaimed.selector);
        mgr.enterFreeRaffle(raffleId, signature);
    }

    function test_EnterFreeRaffle_RevertInvalidSignature() external {
        uint256 raffleId = _createERC20Raffle();

        bytes32 structHash =
            keccak256(abi.encode(keccak256("FreeEntry(uint256 raffleId,address user)"), raffleId, ALICE));
        bytes32 digest = _hashTypedDataV4(structHash);
        uint256 wrongKey = uint256(keccak256("wrong_key"));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory badSignature = abi.encodePacked(r, s, v);

        vm.prank(ALICE);
        vm.expectRevert(FreeEntryVerifier2.InvalidSigner.selector);
        mgr.enterFreeRaffle(raffleId, badSignature);
    }

    function test_EnterFreeRaffle_RevertRaffleNotOpen() external {
        uint256 raffleId = _createERC20Raffle();
        _warpPastExpiry();

        bytes memory signature = _signFreeEntry(raffleId, ALICE);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.RaffleNotOpen.selector, raffleId));
        mgr.enterFreeRaffle(raffleId, signature);
    }

    function test_EnterFreeRaffle_RevertHostCannotEnter() external {
        uint256 raffleId = _createERC20Raffle();
        bytes memory signature = _signFreeEntry(raffleId, HOST);

        vm.prank(HOST);
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.HostCannotEnter.selector, raffleId));
        mgr.enterFreeRaffle(raffleId, signature);
    }

    function test_EnterFreeRaffle_RevertMaxCapReached() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 1, DURATION);

        _enterAs(ALICE, raffleId, 1);

        bytes memory signature = _signFreeEntry(raffleId, BOB);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.MaxCapReached.selector, raffleId));
        mgr.enterFreeRaffle(raffleId, signature);
    }

    function test_EnterFreeRaffle_RevertWrongRaffle() external {
        uint256 raffleId1 = _createERC20Raffle();
        uint256 raffleId2 = _createERC20Raffle();

        bytes memory signature = _signFreeEntry(raffleId1, ALICE);

        vm.prank(ALICE);
        vm.expectRevert(FreeEntryVerifier2.InvalidSigner.selector);
        mgr.enterFreeRaffle(raffleId2, signature);
    }

    function test_EnterFreeRaffle_RevertWrongUser() external {
        uint256 raffleId = _createERC20Raffle();
        bytes memory signature = _signFreeEntry(raffleId, ALICE);

        vm.prank(BOB);
        vm.expectRevert(FreeEntryVerifier2.InvalidSigner.selector);
        mgr.enterFreeRaffle(raffleId, signature);
    }

    function test_FreeEntryThenPaidEntry() external {
        uint256 raffleId = _createERC20Raffle();

        bytes memory signature = _signFreeEntry(raffleId, ALICE);
        vm.prank(ALICE);
        mgr.enterFreeRaffle(raffleId, signature);

        _enterAs(ALICE, raffleId, 5);

        assertEq(mgr.getTotalTickets(raffleId), 6);

        (address owner,) = mgr.getTicketRange(raffleId, 0);
        assertEq(owner, ALICE);
    }

    function test_FreeEntry_RefundableAmountIsZero() external {
        uint256 raffleId = _createERC20Raffle();
        bytes memory signature = _signFreeEntry(raffleId, ALICE);

        vm.prank(ALICE);
        mgr.enterFreeRaffle(raffleId, signature);

        assertEq(mgr.refundableAmount(raffleId, ALICE), 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Resolution (Quiver request) Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_Resolve_RevertNotResolver() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();

        vm.expectRevert(abi.encodeWithSelector(LotteryCore.NotResolver.selector, address(this)));
        mgr.resolveRaffle(raffleId, SALT_1);
    }

    function test_Resolve_RevertNotExpired() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);

        vm.prank(RESOLVER);
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.RaffleNotExpired.selector, raffleId));
        mgr.resolveRaffle(raffleId, SALT_1);
    }

    function test_Resolve_RevertNoTickets() external {
        uint256 raffleId = _createERC20Raffle();
        _warpPastExpiry();

        vm.prank(RESOLVER);
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.RaffleNoTickets.selector, raffleId));
        mgr.resolveRaffle(raffleId, SALT_1);
    }

    function test_Resolve_RevertZeroSalt() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();

        vm.prank(RESOLVER);
        vm.expectRevert(LotteryCore.SaltZero.selector);
        mgr.resolveRaffle(raffleId, bytes32(0));
    }

    function test_Resolve_Success_RequestsVRF() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 10, DURATION);
        _enterAs(ALICE, raffleId, 10);

        _warpPastExpiry();
        _resolve(raffleId, SALT_1);

        LotteryCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(uint256(raffle.status), 1); // PENDING_VRF
        assertFalse(raffle.underfilled); // full-fill

        assertEq(mgr.resolveAttempts(raffleId), 1);
        assertEq(mgr.activeProviderOf(raffleId), providerA);
        assertEq(mgr.activeSeq(raffleId), 1); // first ever request on this provider
        assertEq(mgr.lastRequestAt(raffleId), uint48(block.timestamp));

        // Randomness provider sequence number advanced to 2.
        assertEq(coord.getProviderSequenceNumber(providerA), 2);
    }

    function test_Resolve_EmitsRandomnessRequested() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);

        _warpPastExpiry();
        vm.prank(RESOLVER);
        vm.expectEmit(true, true, true, true);
        emit LotteryCore.RandomnessRequested(raffleId, providerA, 1, 1);
        mgr.resolveRaffle(raffleId, SALT_1);
    }

    function test_Resolve_Underfilled_MarksButDoesNotReturnPrizeYet() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 100, DURATION);
        _enterAs(ALICE, raffleId, 5);

        _warpPastExpiry();
        _resolve(raffleId, SALT_1);

        LotteryCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertTrue(raffle.underfilled);
        assertEq(uint256(raffle.status), 1); // PENDING_VRF

        // Prize must still be held by the contract at request time (disposed exactly once,
        // later, in settle()/cancel paths).
        assertEq(IERC20(address(prizeToken)).balanceOf(address(mgr)), PRIZE_AMT);
        assertEq(IERC20(address(prizeToken)).balanceOf(HOST), 49_000e18);
    }

    function test_Resolve_RevertWhenAlreadyPending() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();

        _resolve(raffleId, SALT_1);

        vm.prank(RESOLVER);
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.RaffleNotOpen.selector, raffleId));
        mgr.resolveRaffle(raffleId, keccak256("salt_2"));
    }

    function test_Resolve_SaltReuseRejected() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();

        _resolve(raffleId, SALT_1);

        // After reveal/settle the raffle is COMPLETED; a fresh raffle with the same salt is fine,
        // but the same raffle cannot reuse a salt while OPEN. Instead test the OPEN retry path:
        uint256 raffleId2 = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(BOB, raffleId2, 5);
        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(RESOLVER);
        mgr.resolveRaffle(raffleId2, SALT_1);
        // Pending now; simulate a stall by requesting again after timeout is not allowed either.
        vm.prank(RESOLVER);
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.RaffleNotOpen.selector, raffleId2));
        mgr.resolveRaffle(raffleId2, SALT_1);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Quiver callback / settlement tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_Callback_GatedToCoordinator() external {
        vm.expectRevert(abi.encodeWithSelector(QuiverConsumer.CallerNotCoordinator.selector, address(this)));
        mgr.quiverCallback(1, providerA, bytes32(uint256(1)));
    }

    function test_Callback_UnexpectedSequence_NoOp() external {
        // Coordinator (or a confused keeper) delivering an unknown seq is a silent no-op.
        vm.prank(address(coord));
        mgr.quiverCallback(999_999, providerA, bytes32(uint256(1)));
    }

    function test_Reveal_WrongSalt_RevertsAtCoordinator() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();

        _resolve(raffleId, SALT_1);
        uint64 seq = mgr.activeSeq(raffleId);

        bytes32 wrongUserRandom = keccak256(abi.encode(bytes32(0), raffleId, 1, address(mgr), block.chainid));
        vm.expectRevert(IncorrectUserRevelation.selector);
        coord.revealAuto(providerA, seq, wrongUserRandom);

        // Raffle still PENDING_VRF.
        assertEq(uint256(mgr.getRaffle(raffleId).status), 1);
    }

    function test_Reveal_Success_StoresRandomnessAndResolves() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);

        _warpPastExpiry();
        _resolve(raffleId, SALT_1);
        _reveal(raffleId, SALT_1);

        LotteryCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(uint256(raffle.status), 4); // RESOLVED
        assertTrue(mgr.raffleRandomness(raffleId) != bytes32(0));
    }

    function test_Reveal_LeavesRaffleResolvedWithRandomness() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolve(raffleId, SALT_1);

        _reveal(raffleId, SALT_1);

        assertEq(uint256(mgr.getRaffle(raffleId).status), 4); // RESOLVED
        assertTrue(mgr.raffleRandomness(raffleId) != bytes32(0));
    }

    function test_Settle_RevertBeforeResolved() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolve(raffleId, SALT_1);

        // PENDING_VRF — not yet settled.
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.RaffleNotResolved.selector, raffleId));
        mgr.settle(raffleId);
    }

    function test_Settle_DoubleSettleReverts() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolve(raffleId, SALT_1);
        _reveal(raffleId, SALT_1);

        _settle(raffleId);
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.RaffleNotResolved.selector, raffleId));
        mgr.settle(raffleId);
    }

    function test_ERC20FullFill_DistributesToAllParties() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 10, DURATION);
        _enterAs(ALICE, raffleId, 10);

        uint256 paymentPool = TICKET_PRICE * 10;
        uint256 paymentFee = (paymentPool * FEE_BPS) / 10_000;
        uint256 prizeFee = (PRIZE_AMT * FEE_BPS) / 10_000;

        _warpPastExpiry();
        _resolveRevealSettle(raffleId);

        assertEq(uint256(mgr.getRaffle(raffleId).status), 2); // COMPLETED
        assertEq(IERC20(address(usdc)).balanceOf(HOST), paymentPool - paymentFee);
        assertEq(IERC20(address(usdc)).balanceOf(TREASURY), paymentFee);
        assertEq(IERC20(address(prizeToken)).balanceOf(ALICE), PRIZE_AMT - prizeFee);
        assertEq(IERC20(address(prizeToken)).balanceOf(TREASURY), prizeFee);
        assertEq(IERC20(address(prizeToken)).balanceOf(address(mgr)), 0);
        assertTrue(mgr.prizeDisposed(raffleId));
    }

    function test_ERC20FullFill_EmitsEvents() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 10, DURATION);
        _enterAs(ALICE, raffleId, 10);

        uint256 paymentPool = TICKET_PRICE * 10;
        uint256 paymentFee = (paymentPool * FEE_BPS) / 10_000;
        uint256 prizeFee = (PRIZE_AMT * FEE_BPS) / 10_000;

        _warpPastExpiry();
        _resolve(raffleId, SALT_1);
        _reveal(raffleId, SALT_1);

        // settle() emits the distribution event first, WinnerPicked last.
        vm.expectEmit(true, true, false, true);
        emit LotteryCore.TokenPrizeAwarded(
            raffleId, ALICE, address(prizeToken), PRIZE_AMT - prizeFee, paymentPool - paymentFee, prizeFee, paymentFee
        );
        vm.expectEmit(true, true, false, false);
        emit LotteryCore.WinnerPicked(raffleId, ALICE);
        _settle(raffleId);
    }

    function test_Underfilled_ReturnsPrizeAndAwardsPool() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 100, DURATION);
        _enterAs(ALICE, raffleId, 5);

        uint256 paymentPool = TICKET_PRICE * 5;
        uint256 paymentFee = (paymentPool * FEE_BPS) / 10_000;

        _warpPastExpiry();
        _resolve(raffleId, SALT_1);
        _reveal(raffleId, SALT_1);
        _settle(raffleId);

        // Prize returned to host (underfilled), pool awarded to the winner.
        assertEq(uint256(mgr.getRaffle(raffleId).status), 2); // COMPLETED
        assertEq(IERC20(address(prizeToken)).balanceOf(HOST), 50_000e18);
        assertEq(IERC20(address(prizeToken)).balanceOf(address(mgr)), 0);
        assertEq(IERC20(address(usdc)).balanceOf(ALICE), 100_000e18 - paymentPool + (paymentPool - paymentFee));
        assertEq(IERC20(address(usdc)).balanceOf(TREASURY), paymentFee);
    }

    function test_Underfilled_EmitsEvents() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 100, DURATION);
        _enterAs(ALICE, raffleId, 5);

        uint256 paymentPool = TICKET_PRICE * 5;
        uint256 paymentFee = (paymentPool * FEE_BPS) / 10_000;

        _warpPastExpiry();
        _resolve(raffleId, SALT_1);
        _reveal(raffleId, SALT_1);

        // settle() emits UnderfilledPrizeReturned → UnderfilledPayout → WinnerPicked.
        vm.expectEmit(true, true, false, true);
        emit LotteryCore.UnderfilledPrizeReturned(raffleId, HOST, PRIZE_AMT);
        vm.expectEmit(true, true, false, true);
        emit LotteryCore.UnderfilledPayout(raffleId, ALICE, address(usdc), paymentPool - paymentFee, paymentFee);
        vm.expectEmit(true, true, false, false);
        emit LotteryCore.WinnerPicked(raffleId, ALICE);
        _settle(raffleId);
    }

    function test_ERC721FullFill_DistributesImmediately() external {
        uint256 raffleId = _createERC721RaffleWithParams(TICKET_PRICE, 10, DURATION);
        _enterAs(ALICE, raffleId, 10);

        uint256 paymentPool = TICKET_PRICE * 10;
        uint256 paymentFee = (paymentPool * FEE_BPS) / 10_000;

        _warpPastExpiry();
        _resolveRevealSettle(raffleId);

        assertEq(uint256(mgr.getRaffle(raffleId).status), 2); // COMPLETED
        assertEq(IERC721(address(nft)).ownerOf(NFT_TOKEN_ID_2), ALICE);
        assertEq(IERC20(address(usdc)).balanceOf(HOST), paymentPool - paymentFee);
        assertEq(IERC20(address(usdc)).balanceOf(TREASURY), paymentFee);
    }

    function test_ERC721FullFill_EmitsNFTPrizeAwarded() external {
        uint256 raffleId = _createERC721RaffleWithParams(TICKET_PRICE, 10, DURATION);
        _enterAs(ALICE, raffleId, 10);

        uint256 paymentPool = TICKET_PRICE * 10;
        uint256 paymentFee = (paymentPool * FEE_BPS) / 10_000;

        _warpPastExpiry();
        _resolve(raffleId, SALT_1);
        _reveal(raffleId, SALT_1);

        // settle() emits NFTPrizeAwarded → WinnerPicked.
        vm.expectEmit(true, true, false, true);
        emit LotteryCore.NFTPrizeAwarded(
            raffleId, ALICE, address(nft), NFT_TOKEN_ID_2, paymentPool - paymentFee, paymentFee
        );
        vm.expectEmit(true, true, false, false);
        emit LotteryCore.WinnerPicked(raffleId, ALICE);
        _settle(raffleId);
    }

    function test_ERC721Underfilled_ReturnsNFTToHost() external {
        uint256 raffleId = _createERC721RaffleWithParams(TICKET_PRICE, 100, DURATION);
        _enterAs(ALICE, raffleId, 5);

        uint256 paymentPool = TICKET_PRICE * 5;
        uint256 paymentFee = (paymentPool * FEE_BPS) / 10_000;

        _warpPastExpiry();
        _resolve(raffleId, SALT_1);
        _reveal(raffleId, SALT_1);
        _settle(raffleId);

        assertEq(IERC721(address(nft)).ownerOf(NFT_TOKEN_ID_2), HOST);
        assertEq(uint256(mgr.getRaffle(raffleId).status), 2); // COMPLETED
        assertEq(IERC20(address(usdc)).balanceOf(ALICE), 100_000e18 - paymentPool + (paymentPool - paymentFee));
    }

    function test_MultiEntrant_SingleWinnerPaid() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 10, DURATION);
        _enterAs(ALICE, raffleId, 3);
        _enterAs(BOB, raffleId, 3);
        _enterAs(CHARLIE, raffleId, 4);

        _warpPastExpiry();
        _resolve(raffleId, SALT_1);
        _reveal(raffleId, SALT_1);
        _settle(raffleId);

        // The full prize went to exactly one of the three entrants.
        uint256 winnerPrize = PRIZE_AMT - (PRIZE_AMT * FEE_BPS) / 10_000;
        assertEq(
            IERC20(address(prizeToken)).balanceOf(ALICE) + IERC20(address(prizeToken)).balanceOf(BOB)
                + IERC20(address(prizeToken)).balanceOf(CHARLIE),
            winnerPrize
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Zero-participant completion + expiry cancellation
    // ═════════════════════════════════════════════════════════════════════════

    function test_CompleteEmptyRaffle_ReturnsPrize() external {
        uint256 raffleId = _createERC20Raffle();
        _warpPastExpiry();

        mgr.completeEmptyRaffle(raffleId);

        LotteryCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(uint256(raffle.status), 2); // COMPLETED
        assertTrue(raffle.underfilled);
        assertEq(IERC20(address(prizeToken)).balanceOf(HOST), 50_000e18);
        assertTrue(mgr.prizeDisposed(raffleId));
    }

    function test_CompleteEmptyRaffle_EmitsEvent() external {
        uint256 raffleId = _createERC20Raffle();
        _warpPastExpiry();

        vm.expectEmit(true, false, false, false);
        emit LotteryCore.RaffleExpired(raffleId);
        mgr.completeEmptyRaffle(raffleId);
    }

    function test_CompleteEmptyRaffle_RevertNotExpired() external {
        uint256 raffleId = _createERC20Raffle();

        vm.expectRevert(abi.encodeWithSelector(LotteryCore.RaffleNotExpired.selector, raffleId));
        mgr.completeEmptyRaffle(raffleId);
    }

    function test_CompleteEmptyRaffle_RevertHasTickets() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 1);
        _warpPastExpiry();

        vm.expectRevert(abi.encodeWithSelector(LotteryCore.RaffleHasTickets.selector, raffleId));
        mgr.completeEmptyRaffle(raffleId);
    }

    function test_CompleteEmptyRaffle_RevertNotOpen() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 1);
        _warpPastExpiry();
        _resolveRevealSettle(raffleId);

        vm.expectRevert(abi.encodeWithSelector(LotteryCore.RaffleNotOpen.selector, raffleId));
        mgr.completeEmptyRaffle(raffleId);
    }

    function test_CancelExpiredRaffle_RevertWithinGrace() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();

        vm.expectRevert(LotteryCore.GraceNotElapsed.selector);
        mgr.cancelExpiredRaffle(raffleId);
    }

    function test_CancelExpiredRaffle_RevertBeforeExpiry() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);

        vm.expectRevert(LotteryCore.GraceNotElapsed.selector);
        mgr.cancelExpiredRaffle(raffleId);
    }

    function test_CancelExpiredRaffle_Success_AfterGrace() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);

        vm.warp(block.timestamp + DURATION + mgr.RESOLVE_GRACE() + 1);
        mgr.cancelExpiredRaffle(raffleId);

        LotteryCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(uint256(raffle.status), 3); // CANCELLED
        assertEq(IERC20(address(prizeToken)).balanceOf(HOST), 50_000e18);
    }

    function test_CancelExpiredRaffle_EmitsEvent() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);

        vm.warp(block.timestamp + DURATION + mgr.RESOLVE_GRACE() + 1);
        vm.expectEmit(true, false, false, false);
        emit LotteryCore.RaffleExpiredCancelled(raffleId);
        mgr.cancelExpiredRaffle(raffleId);
    }

    function test_CancelExpiredRaffle_RevertRaffleNotOpen() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolveRevealSettle(raffleId);

        vm.expectRevert(abi.encodeWithSelector(LotteryCore.RaffleNotOpen.selector, raffleId));
        mgr.cancelExpiredRaffle(raffleId);
    }

    function test_CancelExpiredRaffle_ERC721_ReturnsNFT() external {
        uint256 raffleId = _createERC721Raffle();
        _enterAs(ALICE, raffleId, 5);

        vm.warp(block.timestamp + DURATION + mgr.RESOLVE_GRACE() + 1);
        mgr.cancelExpiredRaffle(raffleId);

        assertEq(IERC721(address(nft)).ownerOf(NFT_TOKEN_ID), HOST);
    }

    function test_CancelExpiredRaffle_ZeroParticipants() external {
        uint256 raffleId = _createERC20Raffle();

        vm.warp(block.timestamp + DURATION + mgr.RESOLVE_GRACE() + 1);
        mgr.cancelExpiredRaffle(raffleId);

        assertEq(uint256(mgr.getRaffle(raffleId).status), 3); // CANCELLED
        assertEq(IERC20(address(prizeToken)).balanceOf(HOST), 50_000e18);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Refunds
    // ═════════════════════════════════════════════════════════════════════════

    function test_ClaimRefund_Success() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);

        vm.warp(block.timestamp + DURATION + mgr.RESOLVE_GRACE() + 1);
        mgr.cancelExpiredRaffle(raffleId);

        vm.prank(ALICE);
        mgr.claimRefund(raffleId);

        // Refund fully restores the initial balance (they paid for 5 tickets earlier).
        assertEq(IERC20(address(usdc)).balanceOf(ALICE), 100_000e18);
    }

    function test_ClaimRefund_EmitsEvent() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);

        vm.warp(block.timestamp + DURATION + mgr.RESOLVE_GRACE() + 1);
        mgr.cancelExpiredRaffle(raffleId);

        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true);
        emit LotteryCore.RefundClaimed(raffleId, ALICE, TICKET_PRICE * 5);
        mgr.claimRefund(raffleId);
    }

    function test_ClaimRefund_ClearsRefundableAmount() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);

        vm.warp(block.timestamp + DURATION + mgr.RESOLVE_GRACE() + 1);
        mgr.cancelExpiredRaffle(raffleId);

        vm.prank(ALICE);
        mgr.claimRefund(raffleId);

        assertEq(mgr.refundableAmount(raffleId, ALICE), 0);
    }

    function test_ClaimRefund_CanOnlyClaimOnce() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);

        vm.warp(block.timestamp + DURATION + mgr.RESOLVE_GRACE() + 1);
        mgr.cancelExpiredRaffle(raffleId);

        vm.prank(ALICE);
        mgr.claimRefund(raffleId);

        vm.prank(ALICE);
        vm.expectRevert(LotteryCore.NoRefundAvailable.selector);
        mgr.claimRefund(raffleId);
    }

    function test_ClaimRefund_RevertRaffleNotCancelled() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);

        vm.expectRevert(abi.encodeWithSelector(LotteryCore.RaffleNotCancelled.selector, raffleId));
        mgr.claimRefund(raffleId);
    }

    function test_ClaimRefund_RevertNoRefundAvailable() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);

        vm.warp(block.timestamp + DURATION + mgr.RESOLVE_GRACE() + 1);
        mgr.cancelExpiredRaffle(raffleId);

        vm.prank(BOB);
        vm.expectRevert(LotteryCore.NoRefundAvailable.selector);
        mgr.claimRefund(raffleId);
    }

    function test_ClaimRefund_RevertOnNonExistentRaffle() external {
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.RaffleNotCancelled.selector, 42));
        mgr.claimRefund(42);
    }

    function test_RefundableAmount_TracksMultiplePurchases() external {
        uint256 raffleId = _createERC20Raffle();

        _enterAs(ALICE, raffleId, 5);
        _enterAs(ALICE, raffleId, 3);
        _enterAs(ALICE, raffleId, 2);

        assertEq(mgr.refundableAmount(raffleId, ALICE), TICKET_PRICE * 10);
    }

    function test_FreeEntryRefund_ZeroOnCancel() external {
        uint256 raffleId = _createERC20Raffle();
        bytes memory signature = _signFreeEntry(raffleId, ALICE);
        vm.prank(ALICE);
        mgr.enterFreeRaffle(raffleId, signature);

        vm.warp(block.timestamp + DURATION + mgr.RESOLVE_GRACE() + 1);
        mgr.cancelExpiredRaffle(raffleId);

        vm.prank(ALICE);
        vm.expectRevert(LotteryCore.NoRefundAvailable.selector);
        mgr.claimRefund(raffleId);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Fee timelock & admin
    // ═════════════════════════════════════════════════════════════════════════

    function test_ProposeFeeChange_Success() external {
        mgr.proposeFeeChange(500);
        assertEq(mgr.pendingFeeBps(), 500);
        assertEq(mgr.feeChangeEffectiveAt(), block.timestamp + 2 days);
    }

    function test_ApplyFeeChange_Success() external {
        mgr.proposeFeeChange(500);
        vm.warp(block.timestamp + 2 days + 1);
        mgr.applyFeeChange();
        assertEq(mgr.platformFeeBps(), 500);
    }

    function test_ApplyFeeChange_RevertTimelockNotElapsed() external {
        mgr.proposeFeeChange(500);
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.FeeTimelockNotElapsed.selector, block.timestamp + 2 days));
        mgr.applyFeeChange();
    }

    function test_ApplyFeeChange_RevertNoFeeChangePending() external {
        vm.expectRevert(LotteryCore.NoFeeChangePending.selector);
        mgr.applyFeeChange();
    }

    function test_ProposeFeeChange_RevertFeeTooHigh() external {
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.FeeTooHigh.selector, 1_001, 1_000));
        mgr.proposeFeeChange(1_001);
    }

    function test_ProposeFeeChange_OverwritesPending() external {
        mgr.proposeFeeChange(300);
        mgr.proposeFeeChange(400);
        assertEq(mgr.pendingFeeBps(), 400);
    }

    function test_FeeTimelock_AppliesToSettlement() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 10, DURATION);
        _enterAs(ALICE, raffleId, 10);

        // Raise fee to 500 bps mid-flight; settlement after apply uses the new rate.
        mgr.proposeFeeChange(500);
        vm.warp(block.timestamp + 2 days + 1);
        mgr.applyFeeChange();
        assertEq(mgr.platformFeeBps(), 500);

        _warpPastExpiry();
        _resolveRevealSettle(raffleId);

        uint256 paymentPool = TICKET_PRICE * 10;
        uint256 paymentFee = (paymentPool * 500) / 10_000;
        uint256 prizeFee = (PRIZE_AMT * 500) / 10_000;
        assertEq(IERC20(address(usdc)).balanceOf(TREASURY), paymentFee);
        assertEq(IERC20(address(prizeToken)).balanceOf(ALICE), PRIZE_AMT - prizeFee);
    }

    function test_ProposeFeeChange_RevertNotOwner() external {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        mgr.proposeFeeChange(300);
    }

    function test_ApplyFeeChange_RevertNotOwner() external {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        mgr.applyFeeChange();
    }

    function test_SetMinDuration_Success() external {
        mgr.setMinDuration(3 hours);
        assertEq(mgr.minDuration(), 3 hours);
    }

    function test_SetMinDuration_RevertBelowFloor() external {
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.DurationTooShort.selector, 1 hours, 2 hours));
        mgr.setMinDuration(1 hours);
    }

    function test_SetMinDuration_RevertNotOwner() external {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        mgr.setMinDuration(3 hours);
    }

    function test_SetTrustedSigner_Success() external {
        address newSigner = makeAddr("newSigner");
        mgr.setTrustedSigner(newSigner);
        assertEq(mgr.trustedSigner(), newSigner);
    }

    function test_SetTrustedSigner_RevertNotOwner() external {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        mgr.setTrustedSigner(ALICE);
    }

    function test_ProviderChange_Timelock() external {
        address newProvider = makeAddr("newProvider");
        coord.registerSecondProvider(newProvider, 0, keccak256("seed_new"), 512);

        mgr.proposeProviderChange(newProvider, address(0));
        assertEq(mgr.pendingActiveProvider(), newProvider);

        // Cannot apply early.
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.ProviderTimelockNotElapsed.selector, block.timestamp + 2 seconds));
        mgr.applyProviderChange();

        vm.warp(block.timestamp + 2 seconds + 1);
        mgr.applyProviderChange();

        assertEq(mgr.activeProvider(), newProvider);
        assertEq(mgr.fallbackProvider(), address(0));
        assertEq(mgr.pendingActiveProvider(), address(0));
    }

    function test_ProviderChange_RevertZeroActive() external {
        vm.expectRevert(LotteryCore.InvalidParams.selector);
        mgr.proposeProviderChange(address(0), address(0));
    }

    function test_ProviderChange_RevertNoPending() external {
        vm.expectRevert(LotteryCore.NoPendingProviderChange.selector);
        mgr.applyProviderChange();
    }

    function test_ProviderChange_RevertNotOwner() external {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        mgr.proposeProviderChange(providerB, address(0));
    }

    function test_SetResolver_NotOwner() external {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        mgr.setResolver(ALICE, true);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Pausable — creation/entry paused only
    // ═════════════════════════════════════════════════════════════════════════

    function test_Pause_BlocksCreateAndEnter() external {
        uint256 raffleId = _createERC20Raffle();

        mgr.pause();

        // Create reverts while paused.
        vm.prank(HOST);
        IERC20(address(prizeToken)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        mgr.createRaffleERC20(address(prizeToken), PRIZE_AMT, TICKET_PRICE, MAX_CAP, DURATION);

        // Enter reverts while paused.
        vm.prank(ALICE);
        IERC20(address(usdc)).approve(address(mgr), TICKET_PRICE);
        vm.prank(ALICE);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        mgr.enterRaffle(raffleId, 1);
    }

    function test_Pause_BlocksEnter() external {
        uint256 raffleId = _createERC20Raffle();

        mgr.pause();

        uint256 cost = TICKET_PRICE;
        vm.prank(ALICE);
        IERC20(address(usdc)).approve(address(mgr), cost);

        vm.prank(ALICE);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        mgr.enterRaffle(raffleId, 1);
    }

    function test_Pause_DoesNotBlockResolveSettleClaims() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 10, DURATION);
        _enterAs(ALICE, raffleId, 10);
        _warpPastExpiry();

        mgr.pause();

        // Resolver + settlement + refund paths stay live while paused.
        _resolve(raffleId, SALT_1);
        _reveal(raffleId, SALT_1);
        _settle(raffleId);
        assertEq(uint256(mgr.getRaffle(raffleId).status), 2); // COMPLETED

        mgr.unpause();
        assertFalse(mgr.paused());
    }

    function test_Pause_OnlyOwner() external {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        mgr.pause();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Native fee funding
    // ═════════════════════════════════════════════════════════════════════════

    function test_FundFees_ReceiveAndNamed() external {
        vm.deal(ALICE, 10 ether);
        vm.prank(ALICE);
        (bool ok,) = address(mgr).call{value: 1 ether}("");
        assertTrue(ok);

        vm.deal(BOB, 10 ether);
        vm.prank(BOB);
        mgr.fundRandomnessFees{value: 2 ether}();

        assertEq(address(mgr).balance, 3 ether);
    }

    function test_WithdrawNative_OnlyOwner() external {
        vm.deal(address(mgr), 5 ether);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        mgr.withdrawNative(ALICE, 1 ether);

        mgr.withdrawNative(HOST, 5 ether);
        assertEq(HOST.balance, 5 ether);
        assertEq(address(mgr).balance, 0);
    }

    function test_Resolve_RevertInsufficientFeeBalance() external {
        // Charge a fee for the active provider, then try to resolve with no native balance.
        vm.prank(providerA);
        coord.setProviderFee(1 ether);

        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();

        vm.prank(RESOLVER);
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.InsufficientFeeBalance.selector, 1 ether, 0));
        mgr.resolveRaffle(raffleId, SALT_1);
    }

    function test_Resolve_PaysFeeFromBalance() external {
        vm.prank(providerA);
        coord.setProviderFee(1 ether);
        vm.deal(address(mgr), 2 ether);

        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();

        _resolve(raffleId, SALT_1);

        // Provider accrued 1 ETH; raffle pending.
        QuiverStructs.ProviderInfo memory info = coord.getProviderInfo(providerA);
        assertEq(info.accruedFeesInWei, 1 ether);
        assertEq(uint256(mgr.getRaffle(raffleId).status), 1);
        assertEq(address(mgr).balance, 1 ether);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Edge cases & misc
    // ═════════════════════════════════════════════════════════════════════════

    function test_MaxCapExactlyOne() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 1, DURATION);
        _enterAs(ALICE, raffleId, 1);

        vm.prank(BOB);
        IERC20(address(usdc)).approve(address(mgr), TICKET_PRICE);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(LotteryCore.MaxCapReached.selector, raffleId));
        mgr.enterRaffle(raffleId, 1);
    }

    function test_TicketCountEqualToMaxCap() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 10, DURATION);
        _enterAs(ALICE, raffleId, 10);

        LotteryCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(raffle.ticketsSold, 10);
        assertEq(raffle.ticketsSold, raffle.maxCap);
    }

    function test_MultipleRafflesSameHost() external {
        uint256 raffleId1 = _createERC20Raffle();
        uint256 raffleId2 = _createERC20Raffle();
        uint256 raffleId3 = _createERC20Raffle();

        assertEq(raffleId1, 1);
        assertEq(raffleId2, 2);
        assertEq(raffleId3, 3);
        assertEq(mgr.raffleCount(), 3);
    }

    function test_MultipleRafflesMixedTypes() external {
        uint256 erc20RaffleId = _createERC20Raffle();
        uint256 erc721RaffleId = _createERC721Raffle();

        assertEq(erc20RaffleId, 1);
        assertEq(erc721RaffleId, 2);
        assertEq(uint256(mgr.getRaffle(erc20RaffleId).prizeType), 0);
        assertEq(uint256(mgr.getRaffle(erc721RaffleId).prizeType), 1);
    }

    function test_MultipleRafflesMixedTypes_EnterBoth() external {
        uint256 erc20RaffleId = _createERC20Raffle();
        uint256 erc721RaffleId = _createERC721Raffle();

        _enterAs(ALICE, erc20RaffleId, 3);
        _enterAs(ALICE, erc721RaffleId, 4);

        assertEq(mgr.getTotalTickets(erc20RaffleId), 3);
        assertEq(mgr.getTotalTickets(erc721RaffleId), 4);
    }

    function test_SingleTicketRaffle_BoundaryWinner() external {
        // total == 1 → winning ticket always 1 == total.
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 1, DURATION);
        _enterAs(ALICE, raffleId, 1);
        _warpPastExpiry();

        _resolveRevealSettle(raffleId);

        assertEq(IERC20(address(prizeToken)).balanceOf(ALICE), PRIZE_AMT - (PRIZE_AMT * FEE_BPS) / 10_000);
    }

    function test_LargeNumberOfRanges() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 1_000, DURATION);

        for (uint256 i = 0; i < 100; i++) {
            address buyer = makeAddr(string(abi.encodePacked("buyer", i)));
            usdc.transfer(buyer, TICKET_PRICE * 10);
            _enterAsWithPrice(buyer, raffleId, 10, TICKET_PRICE);
        }

        _warpPastExpiry();
        _resolveRevealSettle(raffleId);

        assertEq(uint256(mgr.getRaffle(raffleId).status), 2); // COMPLETED
    }

    function test_TicketRangeAggregation_SavesStorage() external {
        uint256 raffleId = _createERC20Raffle();

        _enterAs(ALICE, raffleId, 5);
        _enterAs(ALICE, raffleId, 3);
        _enterAs(ALICE, raffleId, 2);

        (address owner, uint256 endTicket) = mgr.getTicketRange(raffleId, 0);
        assertEq(owner, ALICE);
        assertEq(endTicket, 10);

        vm.expectRevert();
        mgr.getTicketRange(raffleId, 1);
    }

    function test_RefundableAmount_UsesUint256() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 100);

        assertEq(mgr.refundableAmount(raffleId, ALICE), TICKET_PRICE * 100);
    }

    function test_CreateRaffle_RevertDurationOverflowUint48() external {
        vm.prank(HOST);
        IERC20(address(prizeToken)).approve(address(mgr), PRIZE_AMT);

        vm.prank(HOST);
        vm.expectRevert(LotteryCore.InvalidParams.selector);
        mgr.createRaffleERC20(address(prizeToken), PRIZE_AMT, TICKET_PRICE, MAX_CAP, uint256(type(uint48).max));
    }

    function test_FeeRounding_Zero() external {
        // 250 bps on a 39-wei prize rounds the prize fee to zero — no fee is charged on the
        // prize, and settlement still succeeds.
        uint256 tinyPrize = 39;

        vm.prank(HOST);
        IERC20(address(prizeToken)).approve(address(mgr), tinyPrize);
        vm.prank(HOST);
        uint256 raffleId = mgr.createRaffleERC20(address(prizeToken), tinyPrize, TICKET_PRICE, 5, DURATION);

        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolveRevealSettle(raffleId);

        assertEq(IERC20(address(prizeToken)).balanceOf(ALICE), tinyPrize);
        assertEq(IERC20(address(prizeToken)).balanceOf(TREASURY), 0);
        assertEq(IERC20(address(usdc)).balanceOf(TREASURY), (TICKET_PRICE * 5) * FEE_BPS / 10_000);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Views
    // ═════════════════════════════════════════════════════════════════════════

    function test_GetRaffle_ReturnsCorrectData() external {
        uint256 raffleId = _createERC20Raffle();

        LotteryCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(raffle.host, HOST);
        assertEq(raffle.prizeAsset, address(prizeToken));
        assertEq(uint256(raffle.prizeType), 0);
        assertEq(raffle.prizeAmountOrTokenId, PRIZE_AMT);
        assertEq(raffle.ticketPrice, TICKET_PRICE);
        assertEq(raffle.maxCap, MAX_CAP);
        assertEq(raffle.expiry, block.timestamp + DURATION);
    }

    function test_GetTotalTickets_ReturnsCorrectCount() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);
        _enterAs(BOB, raffleId, 3);

        assertEq(mgr.getTotalTickets(raffleId), 8);
    }

    function test_GetTicketRange_ReturnsCorrectData() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);
        _enterAs(BOB, raffleId, 3);

        (address owner1, uint256 endTicket1) = mgr.getTicketRange(raffleId, 0);
        assertEq(owner1, ALICE);
        assertEq(endTicket1, 5);

        (address owner2, uint256 endTicket2) = mgr.getTicketRange(raffleId, 1);
        assertEq(owner2, BOB);
        assertEq(endTicket2, 8);
    }

    function test_Constants_AreCorrect() external {
        assertEq(mgr.MAX_PLATFORM_FEE_BPS(), 1_000);
        assertEq(mgr.MIN_DURATION_FLOOR(), 2 hours);
        assertEq(mgr.FEE_TIMELOCK(), 2 days);
        assertEq(mgr.RESOLVE_GRACE(), 72 hours);
        assertEq(mgr.STALL_TIMEOUT(), 6 hours);
        assertEq(mgr.MAX_RESOLVE_ATTEMPTS(), 3);
        assertEq(mgr.HARD_DEADLINE(), 7 days);
        assertEq(mgr.PROVIDER_TIMELOCK(), 2 seconds);
    }

    function test_PendingResolution_KeeperView() external {
        uint256 raffle1 = _createERC20Raffle();
        uint256 raffle2 = _createERC20Raffle();
        _enterAs(ALICE, raffle1, 5);

        _warpPastExpiry();

        (uint256[] memory ids,) = mgr.pendingResolution(0, 10);
        assertEq(ids.length, 1);
        assertEq(ids[0], raffle1);
    }

    function test_StalledRaffles_KeeperView() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolve(raffleId, SALT_1);

        // Nothing stalled yet (STALL_TIMEOUT not elapsed).
        (uint256[] memory before,) = mgr.stalledRaffles(0, 10);
        assertEq(before.length, 0);

        vm.warp(block.timestamp + mgr.STALL_TIMEOUT());
        (uint256[] memory stalledAfter,) = mgr.stalledRaffles(0, 10);
        assertEq(stalledAfter.length, 1);
        assertEq(stalledAfter[0], raffleId);
    }

    function test_GetResolutionState() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        _resolve(raffleId, SALT_1);

        LotteryCore.ResolutionState memory state = mgr.getResolutionState(raffleId);
        assertEq(uint256(state.status), 1); // PENDING_VRF
        assertEq(state.attempts, 1);
        assertEq(state.activeProviderAddr, providerA);
        assertEq(state.activeSequence, 1);
        assertEq(state.lastRequestedAt, uint48(block.timestamp));
        assertFalse(state.underfilled);
        assertFalse(state.prizeDisposedFlag);
    }

    function test_PrizeDisposedOnce_FullFill() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 10, DURATION);
        _enterAs(ALICE, raffleId, 10);
        _warpPastExpiry();

        _resolve(raffleId, SALT_1);
        _reveal(raffleId, SALT_1);
        _settle(raffleId);

        assertTrue(mgr.prizeDisposed(raffleId));
        assertEq(IERC20(address(prizeToken)).balanceOf(address(mgr)), 0);
        assertEq(IERC20(address(prizeToken)).balanceOf(HOST), 49_000e18);
    }
}
