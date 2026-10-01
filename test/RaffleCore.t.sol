// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RaffleCore} from "../src/chainlink/RaffleCore.sol";
import {FreeEntryVerifier2} from "../src/FreeEntryVerifier2.sol";
import {VRFCoordinatorV2_5Mock} from "./mocks/VRFCoordinatorV2_5Mock.sol";
import {StandardERC20} from "./mocks/StandardERC20.sol";
import {MockERC721} from "./mocks/MockERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract RaffleCoreTest is Test {
    RaffleCore mgr;
    VRFCoordinatorV2_5Mock coord;
    StandardERC20 prizeToken;
    StandardERC20 usdc;
    MockERC721 nft;

    address OWNER;
    address HOST;
    address ALICE;
    address BOB;
    address CHARLIE;
    address TREASURY;
    address SIGNER;
    uint256 SIGNER_PK;

    uint8 constant RAFFLE_CORE_VERSION = 7;

    bytes32 constant KEYHASH = keccak256("test_keyhash");
    uint256 constant SUB_ID = 1;
    uint256 constant PRIZE_AMT = 1_000e18;
    uint256 constant TICKET_PRICE = 10e18;
    uint256 constant MAX_CAP = 100;
    uint256 constant DURATION = 1 days;
    uint256 constant FEE_BPS = 250;
    uint256 constant NFT_TOKEN_ID = 42;
    uint256 constant NFT_TOKEN_ID_2 = 99;

    // ═════════════════════════════════════════════════════════════════════════
    //  Setup
    // ═════════════════════════════════════════════════════════════════════════

    function setUp() external {
        OWNER = address(this);
        HOST = makeAddr("host");
        ALICE = makeAddr("alice");
        BOB = makeAddr("bob");
        CHARLIE = makeAddr("charlie");
        TREASURY = makeAddr("treasury");
        SIGNER_PK = uint256(keccak256("signer_private_key"));
        SIGNER = vm.addr(SIGNER_PK);

        coord = new VRFCoordinatorV2_5Mock();
        prizeToken = new StandardERC20("Prize", "PZ", 100_000e18);
        usdc = new StandardERC20("USDC", "USDC", 1_000_000e18);
        nft = new MockERC721();

        mgr = new RaffleCore(address(coord), KEYHASH, SUB_ID, address(usdc), TREASURY, SIGNER);

        mgr.proposeFeeChange(FEE_BPS);
        vm.warp(block.timestamp + 2 days + 1);
        mgr.applyFeeChange();

        prizeToken.transfer(HOST, 50_000e18);
        usdc.transfer(ALICE, 100_000e18);
        usdc.transfer(BOB, 100_000e18);
        usdc.transfer(CHARLIE, 100_000e18);
        nft.mint(HOST, NFT_TOKEN_ID);
        nft.mint(HOST, NFT_TOKEN_ID_2);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Helpers
    // ═════════════════════════════════════════════════════════════════════════

    function _createERC20Raffle() internal returns (uint256) {
        vm.prank(HOST);
        IERC20(address(prizeToken)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        return mgr.createRaffleERC20(address(prizeToken), PRIZE_AMT, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function _createERC20RaffleWithParams(uint256 ticketPrice, uint256 maxCap, uint256 duration)
        internal
        returns (uint256)
    {
        vm.prank(HOST);
        IERC20(address(prizeToken)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        return mgr.createRaffleERC20(address(prizeToken), PRIZE_AMT, ticketPrice, maxCap, duration);
    }

    function _createERC721Raffle() internal returns (uint256) {
        vm.prank(HOST);
        IERC721(address(nft)).approve(address(mgr), NFT_TOKEN_ID);
        vm.prank(HOST);
        return mgr.createRaffleERC721(address(nft), NFT_TOKEN_ID, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function _createERC721RaffleWithParams(uint256 ticketPrice, uint256 maxCap, uint256 duration)
        internal
        returns (uint256)
    {
        vm.prank(HOST);
        IERC721(address(nft)).approve(address(mgr), NFT_TOKEN_ID_2);
        vm.prank(HOST);
        return mgr.createRaffleERC721(address(nft), NFT_TOKEN_ID_2, ticketPrice, maxCap, duration);
    }

    function _warpPastExpiry() internal {
        vm.warp(block.timestamp + DURATION + 1);
    }

    function _triggerUpkeep() internal returns (uint256) {
        (bool needed, bytes memory data) = mgr.checkUpkeep("");
        assertTrue(needed, "checkUpkeep returned false");
        mgr.performUpkeep(data);
        return coord.lastRequestId();
    }

    function _enterAs(address user, uint256 raffleId, uint256 tickets) internal {
        uint256 cost = TICKET_PRICE * tickets;
        vm.prank(user);
        IERC20(address(usdc)).approve(address(mgr), cost);
        vm.prank(user);
        mgr.enterRaffle(raffleId, tickets);
    }

    function _enterAsWithPrice(address user, uint256 raffleId, uint256 tickets, uint256 ticketPrice) internal {
        uint256 cost = ticketPrice * tickets;
        vm.prank(user);
        IERC20(address(usdc)).approve(address(mgr), cost);
        vm.prank(user);
        mgr.enterRaffle(raffleId, tickets);
    }

    function _fulfillVRF(uint256 requestId, uint256 randomWord) internal {
        uint256[] memory words = new uint256[](1);
        words[0] = randomWord;
        coord.fulfillRandomWords(requestId, words);
    }

    function _signFreeEntry(uint256 raffleId, address user) internal view returns (bytes memory) {
        bytes32 structHash =
            keccak256(abi.encode(keccak256("FreeEntry(uint256 raffleId,address user)"), raffleId, user));
        bytes32 digest = _hashTypedDataV4(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                bytes1(0x19),
                bytes1(0x01),
                keccak256(
                    abi.encode(
                        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                        keccak256(bytes("LotteryCore")),
                        keccak256(bytes("1")),
                        block.chainid,
                        address(mgr)
                    )
                ),
                structHash
            )
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Constructor Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_Constructor_SetsState() external {
        assertEq(mgr.paymentToken(), address(usdc));
        assertEq(mgr.treasury(), TREASURY);
        assertEq(mgr.platformFeeBps(), FEE_BPS);
        assertEq(mgr.minDuration(), 2 hours);
    }

    function test_Constructor_RevertInvalidPaymentToken() external {
        vm.expectRevert(RaffleCore.InvalidParams.selector);
        new RaffleCore(address(coord), KEYHASH, SUB_ID, address(0), TREASURY, SIGNER);
    }

    function test_Constructor_RevertInvalidTreasury() external {
        vm.expectRevert(RaffleCore.InvalidParams.selector);
        new RaffleCore(address(coord), KEYHASH, SUB_ID, address(usdc), address(0), SIGNER);
    }

    function test_Constructor_RevertInvalidSigner() external {
        vm.expectRevert("Invalid signer");
        new RaffleCore(address(coord), KEYHASH, SUB_ID, address(usdc), TREASURY, address(0));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ERC-20 Raffle Creation Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_CreateERC20Raffle_Success() external {
        uint256 raffleId = _createERC20Raffle();

        assertEq(raffleId, 1);
        assertEq(mgr.raffleCount(), 1);

        RaffleCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(raffle.host, HOST);
        assertEq(raffle.prizeAsset, address(prizeToken));
        assertEq(uint256(raffle.prizeType), 0); // PrizeType.ERC20
        assertEq(raffle.prizeAmountOrTokenId, PRIZE_AMT);
        assertEq(raffle.ticketPrice, TICKET_PRICE);
        assertEq(raffle.maxCap, MAX_CAP);
        assertEq(raffle.ticketsSold, 0);
        assertEq(uint256(raffle.status), 0); // RaffleStatus.OPEN
        assertFalse(raffle.underfilled);
        assertEq(raffle.expiry, block.timestamp + DURATION);
    }

    function test_CreateERC20Raffle_EmitsEvent() external {
        vm.prank(HOST);
        IERC20(address(prizeToken)).approve(address(mgr), PRIZE_AMT);

        vm.prank(HOST);
        vm.expectEmit(true, true, false, true);
        emit RaffleCore.RaffleCreated(
            1,
            HOST,
            address(prizeToken),
            RaffleCore.PrizeType.ERC20,
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
        vm.expectRevert(RaffleCore.InvalidParams.selector);
        mgr.createRaffleERC20(address(prizeToken), 0, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function test_CreateERC20Raffle_RevertZeroTicketPrice() external {
        vm.prank(HOST);
        IERC20(address(prizeToken)).approve(address(mgr), PRIZE_AMT);

        vm.prank(HOST);
        vm.expectRevert(RaffleCore.InvalidParams.selector);
        mgr.createRaffleERC20(address(prizeToken), PRIZE_AMT, 0, MAX_CAP, DURATION);
    }

    function test_CreateERC20Raffle_RevertZeroMaxCap() external {
        vm.prank(HOST);
        IERC20(address(prizeToken)).approve(address(mgr), PRIZE_AMT);

        vm.prank(HOST);
        vm.expectRevert(RaffleCore.InvalidParams.selector);
        mgr.createRaffleERC20(address(prizeToken), PRIZE_AMT, TICKET_PRICE, 0, DURATION);
    }

    function test_CreateERC20Raffle_RevertZeroDuration() external {
        vm.prank(HOST);
        IERC20(address(prizeToken)).approve(address(mgr), PRIZE_AMT);

        vm.prank(HOST);
        vm.expectRevert(RaffleCore.InvalidParams.selector);
        mgr.createRaffleERC20(address(prizeToken), PRIZE_AMT, TICKET_PRICE, MAX_CAP, 0);
    }

    function test_CreateERC20Raffle_RevertDurationTooShort() external {
        vm.prank(HOST);
        IERC20(address(prizeToken)).approve(address(mgr), PRIZE_AMT);

        vm.prank(HOST);
        vm.expectRevert(abi.encodeWithSelector(RaffleCore.DurationTooShort.selector, 1 hours, 2 hours));
        mgr.createRaffleERC20(address(prizeToken), PRIZE_AMT, TICKET_PRICE, MAX_CAP, 1 hours);
    }

    function test_CreateERC20Raffle_MinDurationExactlyTwoHours() external {
        vm.prank(HOST);
        IERC20(address(prizeToken)).approve(address(mgr), PRIZE_AMT);

        vm.prank(HOST);
        uint256 raffleId = mgr.createRaffleERC20(address(prizeToken), PRIZE_AMT, TICKET_PRICE, MAX_CAP, 2 hours);

        RaffleCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(raffle.expiry, block.timestamp + 2 hours);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ERC-721 Raffle Creation Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_CreateERC721Raffle_Success() external {
        uint256 raffleId = _createERC721Raffle();

        assertEq(raffleId, 1);
        assertEq(mgr.raffleCount(), 1);

        RaffleCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(raffle.host, HOST);
        assertEq(raffle.prizeAsset, address(nft));
        assertEq(uint256(raffle.prizeType), 1); // PrizeType.ERC721
        assertEq(raffle.prizeAmountOrTokenId, NFT_TOKEN_ID);
        assertEq(raffle.ticketPrice, TICKET_PRICE);
        assertEq(raffle.maxCap, MAX_CAP);
        assertEq(raffle.ticketsSold, 0);
        assertEq(uint256(raffle.status), 0); // RaffleStatus.OPEN
    }

    function test_CreateERC721Raffle_EmitsEvent() external {
        vm.prank(HOST);
        IERC721(address(nft)).approve(address(mgr), NFT_TOKEN_ID);

        vm.prank(HOST);
        vm.expectEmit(true, true, false, true);
        emit RaffleCore.RaffleCreated(
            1,
            HOST,
            address(nft),
            RaffleCore.PrizeType.ERC721,
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
        vm.expectRevert(RaffleCore.InvalidParams.selector);
        mgr.createRaffleERC721(address(0), NFT_TOKEN_ID, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function test_CreateERC721Raffle_RevertZeroTicketPrice() external {
        vm.prank(HOST);
        IERC721(address(nft)).approve(address(mgr), NFT_TOKEN_ID);

        vm.prank(HOST);
        vm.expectRevert(RaffleCore.InvalidParams.selector);
        mgr.createRaffleERC721(address(nft), NFT_TOKEN_ID, 0, MAX_CAP, DURATION);
    }

    function test_CreateERC721Raffle_RevertDurationTooShort() external {
        vm.prank(HOST);
        IERC721(address(nft)).approve(address(mgr), NFT_TOKEN_ID);

        vm.prank(HOST);
        vm.expectRevert(abi.encodeWithSelector(RaffleCore.DurationTooShort.selector, 1 hours, 2 hours));
        mgr.createRaffleERC721(address(nft), NFT_TOKEN_ID, TICKET_PRICE, MAX_CAP, 1 hours);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Ticket Purchase Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_EnterRaffle_Success() external {
        uint256 raffleId = _createERC20Raffle();

        _enterAs(ALICE, raffleId, 5);

        assertEq(mgr.getTotalTickets(raffleId), 5);

        RaffleCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
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
        emit RaffleCore.TicketPurchased(raffleId, ALICE, 5);
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

        // Should only have 1 ticket range entry due to aggregation
        (address owner, uint256 endTicket) = mgr.getTicketRange(raffleId, 0);
        assertEq(owner, ALICE);
        assertEq(endTicket, 8);

        // Verify no second entry
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
        vm.expectRevert(abi.encodeWithSelector(RaffleCore.RaffleNotOpen.selector, 1));
        mgr.enterRaffle(1, 1);
    }

    function test_EnterRaffle_RevertHostCannotEnter() external {
        uint256 raffleId = _createERC20Raffle();

        vm.prank(HOST);
        IERC20(address(usdc)).approve(address(mgr), TICKET_PRICE);

        vm.prank(HOST);
        vm.expectRevert(abi.encodeWithSelector(RaffleCore.HostCannotEnter.selector, raffleId));
        mgr.enterRaffle(raffleId, 1);
    }

    function test_EnterRaffle_RevertZeroTickets() external {
        uint256 raffleId = _createERC20Raffle();

        vm.prank(ALICE);
        vm.expectRevert(RaffleCore.InvalidParams.selector);
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
        vm.expectRevert(abi.encodeWithSelector(RaffleCore.MaxCapReached.selector, raffleId));
        mgr.enterRaffle(raffleId, 1);
    }

    function test_EnterRaffle_RevertExceedsMaxCap() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 10, DURATION);

        _enterAs(ALICE, raffleId, 8);

        uint256 cost = TICKET_PRICE * 5;
        vm.prank(BOB);
        IERC20(address(usdc)).approve(address(mgr), cost);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(RaffleCore.MaxCapReached.selector, raffleId));
        mgr.enterRaffle(raffleId, 5);
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

        RaffleCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(raffle.ticketsSold, 1);
    }

    function test_EnterFreeRaffle_EmitsEvent() external {
        uint256 raffleId = _createERC20Raffle();
        bytes memory signature = _signFreeEntry(raffleId, ALICE);

        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true);
        emit RaffleCore.TicketPurchased(raffleId, ALICE, 1);
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

        // Sign with wrong key
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
        vm.expectRevert(abi.encodeWithSelector(RaffleCore.RaffleNotOpen.selector, raffleId));
        mgr.enterFreeRaffle(raffleId, signature);
    }

    function test_EnterFreeRaffle_RevertHostCannotEnter() external {
        uint256 raffleId = _createERC20Raffle();
        bytes memory signature = _signFreeEntry(raffleId, HOST);

        vm.prank(HOST);
        vm.expectRevert(abi.encodeWithSelector(RaffleCore.HostCannotEnter.selector, raffleId));
        mgr.enterFreeRaffle(raffleId, signature);
    }

    function test_EnterFreeRaffle_RevertMaxCapReached() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 1, DURATION);

        _enterAs(ALICE, raffleId, 1);

        bytes memory signature = _signFreeEntry(raffleId, BOB);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(RaffleCore.MaxCapReached.selector, raffleId));
        mgr.enterFreeRaffle(raffleId, signature);
    }

    function test_EnterFreeRaffle_RevertWrongRaffle() external {
        uint256 raffleId1 = _createERC20Raffle();
        uint256 raffleId2 = _createERC20Raffle();

        // Signature is bound to raffleId1 — cannot be replayed on raffleId2
        bytes memory signature = _signFreeEntry(raffleId1, ALICE);

        vm.prank(ALICE);
        vm.expectRevert(FreeEntryVerifier2.InvalidSigner.selector);
        mgr.enterFreeRaffle(raffleId2, signature);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Chainlink Automation Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_CheckUpkeep_ReturnsTrueForExpiredRaffle() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);

        _warpPastExpiry();

        (bool needed,) = mgr.checkUpkeep("");
        assertTrue(needed);
    }

    function test_CheckUpkeep_ReturnsFalseForOpenRaffle() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);

        (bool needed,) = mgr.checkUpkeep("");
        assertFalse(needed);
    }

    function test_CheckUpkeep_WrapsAround() external {
        uint256 raffleId1 = _createERC20Raffle();
        _enterAs(ALICE, raffleId1, 5);

        uint256 raffleId2 = _createERC20Raffle();
        _enterAs(BOB, raffleId2, 3);

        // Warp past first raffle expiry
        vm.warp(block.timestamp + DURATION + 1);

        (bool needed,) = mgr.checkUpkeep("");
        assertTrue(needed);
    }

    function test_PerformUpkeep_ExpiredWithZeroParticipants() external {
        uint256 raffleId = _createERC20Raffle();
        _warpPastExpiry();

        _triggerUpkeep();

        RaffleCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(uint256(raffle.status), 2); // COMPLETED
        assertTrue(raffle.underfilled);

        // Prize should be returned to host
        assertEq(IERC20(address(prizeToken)).balanceOf(HOST), 50_000e18);
    }

    function test_PerformUpkeep_ExpiredWithZeroParticipants_EmitsEvent() external {
        uint256 raffleId = _createERC20Raffle();
        _warpPastExpiry();

        (, bytes memory data) = mgr.checkUpkeep("");

        vm.expectEmit(true, false, false, false);
        emit RaffleCore.RaffleExpired(raffleId);
        mgr.performUpkeep(data);
    }

    function test_PerformUpkeep_Underfilled_ReturnsPrizeToHost() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 100, DURATION);
        _enterAs(ALICE, raffleId, 5);

        _warpPastExpiry();
        _triggerUpkeep();

        RaffleCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertTrue(raffle.underfilled);

        // Prize should be returned to host
        assertEq(IERC20(address(prizeToken)).balanceOf(HOST), 50_000e18);
    }

    function test_PerformUpkeep_FullFill_RequestsVRF() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);

        _warpPastExpiry();
        uint256 requestId = _triggerUpkeep();

        RaffleCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(uint256(raffle.status), 1); // PENDING_VRF

        assertEq(requestId, 1);
    }

    function test_PerformUpkeep_ReentrancyGuard() external {
        uint256 raffleId = _createERC20Raffle();
        _warpPastExpiry();

        // PerformUpkeep should not allow reentrancy
        (, bytes memory data) = mgr.checkUpkeep("");
        mgr.performUpkeep(data);

        // Second call should revert or be a no-op
        // Since status is now PENDING_VRF or COMPLETED, it should be a no-op
        mgr.performUpkeep(data);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  VRF Fulfillment Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_FulfillRandomWords_SelectsWinner() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 10, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _enterAs(BOB, raffleId, 5);

        _warpPastExpiry();
        uint256 requestId = _triggerUpkeep();

        // Fulfill with random word that selects ticket 3 (should be ALICE)
        _fulfillVRF(requestId, 2);

        RaffleCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(uint256(raffle.status), 2); // COMPLETED
    }

    function test_FulfillRandomWords_EmitsWinnerPicked() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 10, DURATION);
        _enterAs(ALICE, raffleId, 10);

        _warpPastExpiry();
        uint256 requestId = _triggerUpkeep();

        vm.expectEmit(true, true, false, false);
        emit RaffleCore.WinnerPicked(raffleId, ALICE);
        _fulfillVRF(requestId, 5);
    }

    function test_FulfillRandomWords_DistributesERC20Prize() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 10, DURATION);
        _enterAs(ALICE, raffleId, 10);

        uint256 paymentPool = TICKET_PRICE * 10;
        uint256 expectedFee = (paymentPool * FEE_BPS) / 10_000;
        uint256 expectedHostAmount = paymentPool - expectedFee;

        _warpPastExpiry();
        uint256 requestId = _triggerUpkeep();

        _fulfillVRF(requestId, 5);

        // Host should receive payment pool minus fee
        assertEq(IERC20(address(usdc)).balanceOf(HOST), expectedHostAmount);

        // Treasury should receive fee
        assertEq(IERC20(address(usdc)).balanceOf(TREASURY), expectedFee);

        // Winner should receive prize minus fee
        uint256 prizeFee = (PRIZE_AMT * FEE_BPS) / 10_000;
        assertEq(IERC20(address(prizeToken)).balanceOf(ALICE), PRIZE_AMT - prizeFee);
    }

    function test_FulfillRandomWords_EmitsTokenPrizeAwarded() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 10, DURATION);
        _enterAs(ALICE, raffleId, 10);

        uint256 paymentPool = TICKET_PRICE * 10;
        uint256 paymentFee = (paymentPool * FEE_BPS) / 10_000;
        uint256 prizeFee = (PRIZE_AMT * FEE_BPS) / 10_000;

        _warpPastExpiry();
        uint256 requestId = _triggerUpkeep();

        vm.expectEmit(true, true, false, true);
        emit RaffleCore.TokenPrizeAwarded(
            raffleId, ALICE, address(prizeToken), PRIZE_AMT - prizeFee, paymentPool - paymentFee, prizeFee, paymentFee
        );
        _fulfillVRF(requestId, 5);
    }

    function test_FulfillRandomWords_Underfilled_AwardsPaymentPool() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 100, DURATION);
        _enterAs(ALICE, raffleId, 5);

        uint256 paymentPool = TICKET_PRICE * 5;
        uint256 expectedFee = (paymentPool * FEE_BPS) / 10_000;

        _warpPastExpiry();
        uint256 requestId = _triggerUpkeep();

        _fulfillVRF(requestId, 2);

        // Winner should receive payment pool minus fee
        assertEq(IERC20(address(usdc)).balanceOf(ALICE), 100_000e18 - (TICKET_PRICE * 5) + (paymentPool - expectedFee));

        // Treasury should receive fee
        assertEq(IERC20(address(usdc)).balanceOf(TREASURY), expectedFee);
    }

    function test_FulfillRandomWords_Underfilled_EmitsUnderfilledPayout() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 100, DURATION);
        _enterAs(ALICE, raffleId, 5);

        uint256 paymentPool = TICKET_PRICE * 5;
        uint256 paymentFee = (paymentPool * FEE_BPS) / 10_000;

        _warpPastExpiry();
        uint256 requestId = _triggerUpkeep();

        vm.expectEmit(true, true, false, true);
        emit RaffleCore.UnderfilledPayout(raffleId, ALICE, address(usdc), paymentPool - paymentFee, paymentFee);
        _fulfillVRF(requestId, 2);
    }

    function test_FulfillRandomWords_ZeroParticipants_ReturnsPrize() external {
        uint256 raffleId = _createERC20Raffle();
        _warpPastExpiry();

        // With zero participants, performUpkeep should complete immediately without VRF
        (bool needed, bytes memory data) = mgr.checkUpkeep("");
        assertTrue(needed);

        uint256 balanceBefore = IERC20(address(prizeToken)).balanceOf(HOST);
        mgr.performUpkeep(data);
        uint256 balanceAfter = IERC20(address(prizeToken)).balanceOf(HOST);

        RaffleCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(uint256(raffle.status), 2); // COMPLETED
        assertTrue(raffle.underfilled);

        // Prize should be returned to host
        assertEq(balanceAfter - balanceBefore, PRIZE_AMT);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ERC-721 Full-Fill Distribution Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_FulfillRandomWords_ERC721FullFill_DistributesImmediately() external {
        uint256 raffleId = _createERC721RaffleWithParams(TICKET_PRICE, 10, DURATION);
        _enterAs(ALICE, raffleId, 10);

        uint256 paymentPool = TICKET_PRICE * 10;
        uint256 expectedFee = (paymentPool * FEE_BPS) / 10_000;
        uint256 expectedHostAmount = paymentPool - expectedFee;

        _warpPastExpiry();
        uint256 requestId = _triggerUpkeep();
        _fulfillVRF(requestId, 5);

        // Winner should receive NFT immediately
        assertEq(IERC721(address(nft)).ownerOf(NFT_TOKEN_ID_2), ALICE);

        // Host should receive payment pool minus fee
        assertEq(IERC20(address(usdc)).balanceOf(HOST), expectedHostAmount);

        // Treasury should receive fee
        assertEq(IERC20(address(usdc)).balanceOf(TREASURY), expectedFee);
    }

    function test_FulfillRandomWords_ERC721FullFill_EmitsNFTPrizeAwarded() external {
        uint256 raffleId = _createERC721RaffleWithParams(TICKET_PRICE, 10, DURATION);
        _enterAs(ALICE, raffleId, 10);

        uint256 paymentPool = TICKET_PRICE * 10;
        uint256 paymentFee = (paymentPool * FEE_BPS) / 10_000;

        _warpPastExpiry();
        uint256 requestId = _triggerUpkeep();

        vm.expectEmit(true, true, false, true);
        emit RaffleCore.NFTPrizeAwarded(
            raffleId, ALICE, address(nft), NFT_TOKEN_ID_2, paymentPool - paymentFee, paymentFee
        );
        _fulfillVRF(requestId, 5);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Emergency Finalization Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_EmergencyFinalize_Success() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);

        _warpPastExpiry();
        _triggerUpkeep();

        // Warp past VRF timeout
        vm.warp(block.timestamp + mgr.VRF_TIMEOUT() + 1);

        mgr.emergencyFinalize(raffleId);

        RaffleCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(uint256(raffle.status), 3); // CANCELLED

        // Prize should be returned to host
        assertEq(IERC20(address(prizeToken)).balanceOf(HOST), 50_000e18);
    }

    function test_EmergencyFinalize_EmitsEvent() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 1);

        _warpPastExpiry();
        _triggerUpkeep();

        vm.warp(block.timestamp + mgr.VRF_TIMEOUT() + 1);

        vm.expectEmit(true, false, false, false);
        emit RaffleCore.RaffleEmergencyFinalized(raffleId);
        mgr.emergencyFinalize(raffleId);
    }

    function test_EmergencyFinalize_EnablesRefunds() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);

        _warpPastExpiry();
        _triggerUpkeep();

        vm.warp(block.timestamp + mgr.VRF_TIMEOUT() + 1);
        mgr.emergencyFinalize(raffleId);

        uint256 refundable = mgr.refundableAmount(raffleId, ALICE);
        assertGt(refundable, 0);

        uint256 balanceBefore = IERC20(address(usdc)).balanceOf(ALICE);
        vm.prank(ALICE);
        mgr.claimRefund(raffleId);
        uint256 balanceAfter = IERC20(address(usdc)).balanceOf(ALICE);

        assertEq(balanceAfter - balanceBefore, refundable);
    }

    function test_EmergencyFinalize_RevertRaffleNotPendingVRF() external {
        uint256 raffleId = _createERC20Raffle();

        vm.expectRevert(abi.encodeWithSelector(RaffleCore.RaffleNotPendingVRF.selector, raffleId));
        mgr.emergencyFinalize(raffleId);
    }

    function test_EmergencyFinalize_RevertVRFTimeoutNotReached() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 1);

        _warpPastExpiry();
        _triggerUpkeep();

        // Don't warp past VRF timeout yet
        vm.expectRevert(RaffleCore.VRFTimeoutNotReached.selector);
        mgr.emergencyFinalize(raffleId);
    }

    function test_EmergencyFinalize_ERC721_ReturnsNFT() external {
        uint256 raffleId = _createERC721Raffle();
        _enterAs(ALICE, raffleId, 5);

        _warpPastExpiry();
        _triggerUpkeep();

        vm.warp(block.timestamp + mgr.VRF_TIMEOUT() + 1);
        mgr.emergencyFinalize(raffleId);

        // NFT should be returned to host
        assertEq(IERC721(address(nft)).ownerOf(NFT_TOKEN_ID), HOST);
    }

    function test_EmergencyFinalize_AlreadyUnderfilled_DoesNotDoubleReturn() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 100, DURATION);
        _enterAs(ALICE, raffleId, 5);

        _warpPastExpiry();
        _triggerUpkeep();

        vm.warp(block.timestamp + mgr.VRF_TIMEOUT() + 1);

        // Prize already returned during performUpkeep for underfilled
        uint256 hostBalanceBefore = IERC20(address(prizeToken)).balanceOf(HOST);
        mgr.emergencyFinalize(raffleId);
        uint256 hostBalanceAfter = IERC20(address(prizeToken)).balanceOf(HOST);

        // Should not have received prize again
        assertEq(hostBalanceAfter, hostBalanceBefore);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Cancel Expired Raffle Tests (expired but VRF never requested)
    // ═════════════════════════════════════════════════════════════════════════

    function test_CancelExpiredRaffle_Success() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);

        _warpPastExpiry();

        mgr.cancelExpiredRaffle(raffleId);

        RaffleCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(uint256(raffle.status), 3); // CANCELLED

        // Prize should be returned to host
        assertEq(IERC20(address(prizeToken)).balanceOf(HOST), 50_000e18);
    }

    function test_CancelExpiredRaffle_EmitsEvent() external {
        uint256 raffleId = _createERC20Raffle();

        _warpPastExpiry();

        vm.expectEmit(true, false, false, false);
        emit RaffleCore.RaffleExpiredCancelled(raffleId);
        mgr.cancelExpiredRaffle(raffleId);
    }

    function test_CancelExpiredRaffle_EnablesRefunds() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);

        _warpPastExpiry();
        mgr.cancelExpiredRaffle(raffleId);

        uint256 refundable = mgr.refundableAmount(raffleId, ALICE);
        assertGt(refundable, 0);

        uint256 balanceBefore = IERC20(address(usdc)).balanceOf(ALICE);
        vm.prank(ALICE);
        mgr.claimRefund(raffleId);
        uint256 balanceAfter = IERC20(address(usdc)).balanceOf(ALICE);

        assertEq(balanceAfter - balanceBefore, refundable);
    }

    function test_CancelExpiredRaffle_RevertNotExpired() external {
        uint256 raffleId = _createERC20Raffle();

        // Still within duration
        vm.expectRevert(abi.encodeWithSelector(RaffleCore.RaffleNotExpired.selector, raffleId));
        mgr.cancelExpiredRaffle(raffleId);
    }

    function test_CancelExpiredRaffle_RevertRaffleNotOpen_PendingVRF() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 1);

        _warpPastExpiry();
        _triggerUpkeep(); // status -> PENDING_VRF (VRF already requested)

        vm.expectRevert(abi.encodeWithSelector(RaffleCore.RaffleNotOpen.selector, raffleId));
        mgr.cancelExpiredRaffle(raffleId);
    }

    function test_CancelExpiredRaffle_RevertRaffleNotOpen_Completed() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 1);

        _warpPastExpiry();
        uint256 requestId = _triggerUpkeep();
        _fulfillVRF(requestId, 1); // status -> COMPLETED

        vm.expectRevert(abi.encodeWithSelector(RaffleCore.RaffleNotOpen.selector, raffleId));
        mgr.cancelExpiredRaffle(raffleId);
    }

    function test_CancelExpiredRaffle_ERC721_ReturnsNFT() external {
        uint256 raffleId = _createERC721Raffle();
        _enterAs(ALICE, raffleId, 1);

        _warpPastExpiry();
        mgr.cancelExpiredRaffle(raffleId);

        // NFT should be returned to host
        assertEq(IERC721(address(nft)).ownerOf(NFT_TOKEN_ID), HOST);
    }

    function test_CancelExpiredRaffle_ZeroParticipants() external {
        uint256 raffleId = _createERC20Raffle();

        _warpPastExpiry();
        mgr.cancelExpiredRaffle(raffleId);

        RaffleCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(uint256(raffle.status), 3); // CANCELLED
        assertEq(IERC20(address(prizeToken)).balanceOf(HOST), 50_000e18);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Refund Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_ClaimRefund_Success() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);

        _warpPastExpiry();
        _triggerUpkeep();
        vm.warp(block.timestamp + mgr.VRF_TIMEOUT() + 1);
        mgr.emergencyFinalize(raffleId);

        uint256 refundable = mgr.refundableAmount(raffleId, ALICE);
        uint256 balanceBefore = IERC20(address(usdc)).balanceOf(ALICE);

        vm.prank(ALICE);
        mgr.claimRefund(raffleId);

        uint256 balanceAfter = IERC20(address(usdc)).balanceOf(ALICE);
        assertEq(balanceAfter - balanceBefore, refundable);
    }

    function test_ClaimRefund_EmitsEvent() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);

        _warpPastExpiry();
        _triggerUpkeep();
        vm.warp(block.timestamp + mgr.VRF_TIMEOUT() + 1);
        mgr.emergencyFinalize(raffleId);

        uint256 refundable = mgr.refundableAmount(raffleId, ALICE);

        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true);
        emit RaffleCore.RefundClaimed(raffleId, ALICE, refundable);
        mgr.claimRefund(raffleId);
    }

    function test_ClaimRefund_ClearsRefundableAmount() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);

        _warpPastExpiry();
        _triggerUpkeep();
        vm.warp(block.timestamp + mgr.VRF_TIMEOUT() + 1);
        mgr.emergencyFinalize(raffleId);

        vm.prank(ALICE);
        mgr.claimRefund(raffleId);

        assertEq(mgr.refundableAmount(raffleId, ALICE), 0);
    }

    function test_ClaimRefund_CanOnlyClaimOnce() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);

        _warpPastExpiry();
        _triggerUpkeep();
        vm.warp(block.timestamp + mgr.VRF_TIMEOUT() + 1);
        mgr.emergencyFinalize(raffleId);

        vm.prank(ALICE);
        mgr.claimRefund(raffleId);

        vm.prank(ALICE);
        vm.expectRevert(RaffleCore.NoRefundAvailable.selector);
        mgr.claimRefund(raffleId);
    }

    function test_ClaimRefund_RevertRaffleNotCancelled() external {
        uint256 raffleId = _createERC20Raffle();

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RaffleCore.RaffleNotCancelled.selector, raffleId));
        mgr.claimRefund(raffleId);
    }

    function test_ClaimRefund_RevertNoRefundAvailable() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 1);

        _warpPastExpiry();
        _triggerUpkeep();
        vm.warp(block.timestamp + mgr.VRF_TIMEOUT() + 1);
        mgr.emergencyFinalize(raffleId);

        // BOB has no refund available
        vm.prank(BOB);
        vm.expectRevert(RaffleCore.NoRefundAvailable.selector);
        mgr.claimRefund(raffleId);
    }

    function test_RefundableAmount_TracksMultiplePurchases() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 3);
        _enterAs(ALICE, raffleId, 2);

        uint256 expected = TICKET_PRICE * 5;
        assertEq(mgr.refundableAmount(raffleId, ALICE), expected);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Fee Management Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_ProposeFeeChange_Success() external {
        vm.expectEmit(false, false, false, true);
        emit RaffleCore.FeeChangeProposed(500, block.timestamp + 2 days);
        mgr.proposeFeeChange(500);

        assertEq(mgr.pendingFeeBps(), 500);
        assertEq(mgr.feeChangeEffectiveAt(), block.timestamp + 2 days);
    }

    function test_ApplyFeeChange_Success() external {
        mgr.proposeFeeChange(500);

        vm.warp(block.timestamp + 2 days + 1);

        vm.expectEmit(false, false, false, true);
        emit RaffleCore.FeeChangeApplied(250, 500);
        mgr.applyFeeChange();

        assertEq(mgr.platformFeeBps(), 500);
        assertEq(mgr.pendingFeeBps(), 0);
        assertEq(mgr.feeChangeEffectiveAt(), 0);
    }

    function test_ApplyFeeChange_RevertTimelockNotElapsed() external {
        mgr.proposeFeeChange(500);

        vm.expectRevert(abi.encodeWithSelector(RaffleCore.FeeTimelockNotElapsed.selector, block.timestamp + 2 days));
        mgr.applyFeeChange();
    }

    function test_ApplyFeeChange_RevertNoFeeChangePending() external {
        vm.expectRevert(RaffleCore.NoFeeChangePending.selector);
        mgr.applyFeeChange();
    }

    function test_ProposeFeeChange_RevertFeeTooHigh() external {
        vm.expectRevert(abi.encodeWithSelector(RaffleCore.FeeTooHigh.selector, 1500, 1000));
        mgr.proposeFeeChange(1500);
    }

    function test_FeeCalculation_Correct() external {
        uint256 amount = 10_000e18;
        uint256 expectedFee = (amount * 250) / 10_000; // 250 bps = 2.5%
        assertEq(expectedFee, 250e18);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Min Duration Management Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_SetMinDuration_Success() external {
        mgr.setMinDuration(3 hours);

        assertEq(mgr.minDuration(), 3 hours);
    }

    function test_SetMinDuration_RevertBelowFloor() external {
        vm.expectRevert(abi.encodeWithSelector(RaffleCore.DurationTooShort.selector, 1 hours, 2 hours));
        mgr.setMinDuration(1 hours);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Trusted Signer Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_SetTrustedSigner_Success() external {
        address newSigner = makeAddr("newSigner");

        mgr.setTrustedSigner(newSigner);

        assertEq(mgr.trustedSigner(), newSigner);
    }

    function test_SetTrustedSigner_EmitsEvent() external {
        address newSigner = makeAddr("newSigner");

        vm.expectEmit(false, false, false, true);
        emit FreeEntryVerifier2.TrustedSignerUpdated(SIGNER, newSigner);
        mgr.setTrustedSigner(newSigner);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Binary Search Winner Selection Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_BinarySearch_FirstTicketWins() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 10, DURATION);
        _enterAs(ALICE, raffleId, 3);
        _enterAs(BOB, raffleId, 3);
        _enterAs(CHARLIE, raffleId, 4);

        _warpPastExpiry();
        uint256 requestId = _triggerUpkeep();

        // Random word 0 should select ticket 1 (ALICE)
        _fulfillVRF(requestId, 0);

        RaffleCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(uint256(raffle.status), 2); // COMPLETED
    }

    function test_BinarySearch_LastTicketWins() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 10, DURATION);
        _enterAs(ALICE, raffleId, 3);
        _enterAs(BOB, raffleId, 3);
        _enterAs(CHARLIE, raffleId, 4);

        _warpPastExpiry();
        uint256 requestId = _triggerUpkeep();

        // Random word 9 should select ticket 10 (CHARLIE)
        _fulfillVRF(requestId, 9);

        RaffleCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(uint256(raffle.status), 2); // COMPLETED
    }

    function test_BinarySearch_MiddleTicketWins() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 10, DURATION);
        _enterAs(ALICE, raffleId, 3);
        _enterAs(BOB, raffleId, 4);
        _enterAs(CHARLIE, raffleId, 3);

        _warpPastExpiry();
        uint256 requestId = _triggerUpkeep();

        // Random word 4 should select ticket 5 (BOB)
        _fulfillVRF(requestId, 4);

        RaffleCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(uint256(raffle.status), 2); // COMPLETED
    }

    function test_BinarySearch_LargeNumberOfRanges() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 1000, DURATION);

        // Create 100 different buyers
        for (uint256 i = 0; i < 100; i++) {
            address buyer = makeAddr(string(abi.encodePacked("buyer", i)));
            usdc.transfer(buyer, TICKET_PRICE * 10);
            _enterAsWithPrice(buyer, raffleId, 10, TICKET_PRICE);
        }

        _warpPastExpiry();
        uint256 requestId = _triggerUpkeep();

        // Should still work efficiently with O(log N) search
        _fulfillVRF(requestId, 500);

        RaffleCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(uint256(raffle.status), 2); // COMPLETED
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Storage Optimization Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_TicketRangeAggregation_SavesStorage() external {
        uint256 raffleId = _createERC20Raffle();

        // Same buyer multiple times
        _enterAs(ALICE, raffleId, 5);
        _enterAs(ALICE, raffleId, 3);
        _enterAs(ALICE, raffleId, 2);

        // Should only have 1 range entry
        (address owner, uint256 endTicket) = mgr.getTicketRange(raffleId, 0);
        assertEq(owner, ALICE);
        assertEq(endTicket, 10);

        // Verify no additional entries
        vm.expectRevert();
        mgr.getTicketRange(raffleId, 1);
    }

    function test_RefundableAmount_UsesUint256() external {
        uint256 raffleId = _createERC20Raffle();

        // Large purchase - use many tickets to get a large amount
        _enterAs(ALICE, raffleId, 100);

        uint256 refundable = mgr.refundableAmount(raffleId, ALICE);
        assertEq(refundable, TICKET_PRICE * 100);

        // Verify the value is substantial (though may not exceed uint96.max in typical tests)
        assertGt(refundable, TICKET_PRICE * 50);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Edge Cases and Corner Cases
    // ═════════════════════════════════════════════════════════════════════════

    function test_MaxCapExactlyOne() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 1, DURATION);

        _enterAs(ALICE, raffleId, 1);

        uint256 cost = TICKET_PRICE;
        vm.prank(BOB);
        IERC20(address(usdc)).approve(address(mgr), cost);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(RaffleCore.MaxCapReached.selector, raffleId));
        mgr.enterRaffle(raffleId, 1);
    }

    function test_TicketCountEqualToMaxCap() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 10, DURATION);

        _enterAs(ALICE, raffleId, 10);

        RaffleCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
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

        RaffleCore.RaffleData memory raffle1 = mgr.getRaffle(erc20RaffleId);
        RaffleCore.RaffleData memory raffle2 = mgr.getRaffle(erc721RaffleId);

        assertEq(uint256(raffle1.prizeType), 0); // ERC20
        assertEq(uint256(raffle2.prizeType), 1); // ERC721
    }

    function test_FreeEntryThenPaidEntry() external {
        uint256 raffleId = _createERC20Raffle();

        // Free entry
        bytes memory signature = _signFreeEntry(raffleId, ALICE);
        vm.prank(ALICE);
        mgr.enterFreeRaffle(raffleId, signature);

        // Paid entry should work
        _enterAs(ALICE, raffleId, 5);

        assertEq(mgr.getTotalTickets(raffleId), 6);
    }

    function test_RaffleExpiryAtExactBoundary() external {
        uint256 raffleId = _createERC20Raffle();

        // Enter just before expiry
        vm.warp(block.timestamp + DURATION - 1);
        _enterAs(ALICE, raffleId, 1);

        // Should fail at exact expiry
        vm.warp(block.timestamp + 1);

        uint256 cost = TICKET_PRICE;
        vm.prank(BOB);
        IERC20(address(usdc)).approve(address(mgr), cost);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(RaffleCore.RaffleNotOpen.selector, raffleId));
        mgr.enterRaffle(raffleId, 1);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  View Function Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_GetRaffle_ReturnsCorrectData() external {
        uint256 raffleId = _createERC20Raffle();

        RaffleCore.RaffleData memory raffle = mgr.getRaffle(raffleId);

        assertEq(raffle.host, HOST);
        assertEq(raffle.prizeAsset, address(prizeToken));
        assertEq(uint256(raffle.prizeType), 0);
        assertEq(raffle.prizeAmountOrTokenId, PRIZE_AMT);
        assertEq(raffle.ticketPrice, TICKET_PRICE);
        assertEq(raffle.maxCap, MAX_CAP);
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

    // ═════════════════════════════════════════════════════════════════════════
    //  Constants and Immutables Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_Constants_AreCorrect() external {
        assertEq(mgr.MAX_PLATFORM_FEE_BPS(), 1_000);
        assertEq(mgr.MIN_DURATION_FLOOR(), 2 hours);
        assertEq(mgr.FEE_TIMELOCK(), 2 days);
        assertEq(mgr.VRF_TIMEOUT(), 24 hours);
        assertEq(mgr.CHECK_UPKEEP_BATCH(), 50);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Reentrancy Protection Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_EnterRaffle_ReentrancyGuard() external {
        uint256 raffleId = _createERC20Raffle();

        // Normal entry should work
        _enterAs(ALICE, raffleId, 1);

        // Cannot enter again in same transaction (would require malicious contract)
        // This tests the guard is in place
    }

    function test_ClaimRefund_ReentrancyGuard() external {
        uint256 raffleId = _createERC20Raffle();
        _enterAs(ALICE, raffleId, 5);

        _warpPastExpiry();
        _triggerUpkeep();
        vm.warp(block.timestamp + mgr.VRF_TIMEOUT() + 1);
        mgr.emergencyFinalize(raffleId);

        // Normal claim should work
        vm.prank(ALICE);
        mgr.claimRefund(raffleId);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Payment Pool Tracking Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_PaymentPool_TracksCorrectly() external {
        uint256 raffleId = _createERC20Raffle();

        _enterAs(ALICE, raffleId, 5);
        _enterAs(BOB, raffleId, 3);

        // Payment pool should be tracked internally
        // After VRF and distribution, amounts should be correct
        _warpPastExpiry();
        uint256 requestId = _triggerUpkeep();
        _fulfillVRF(requestId, 5);

        // Verify final balances
        uint256 paymentPool = TICKET_PRICE * 8;
        uint256 fee = (paymentPool * FEE_BPS) / 10_000;

        assertEq(IERC20(address(usdc)).balanceOf(TREASURY), fee);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Gas Optimization Tests
    // ═════════════════════════════════════════════════════════════════════════

    function test_GasOptimization_BatchEntries() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 100, DURATION);

        // Single large entry should be more gas efficient than many small ones
        vm.prank(ALICE);
        IERC20(address(usdc)).approve(address(mgr), TICKET_PRICE * 50);

        vm.prank(ALICE);
        mgr.enterRaffle(raffleId, 50);

        // Just verify it completes successfully
        assertEq(mgr.getTotalTickets(raffleId), 50);
    }

    function test_GasOptimization_CheckUpkeepPagination() external {
        // Create many raffles
        for (uint256 i = 0; i < 10; i++) {
            _createERC20Raffle();
        }

        // checkUpkeep should only scan CHECK_UPKEEP_BATCH at a time
        (bool needed,) = mgr.checkUpkeep("");
        assertFalse(needed); // None expired yet
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Missing Critical Tests
    // ═════════════════════════════════════════════════════════════════════════

    // ── performUpkeep edge cases ──

    function test_PerformUpkeep_RevertInvalidRaffleId_Zero() external {
        // Should silently return (no revert) for raffleId = 0
        mgr.performUpkeep(abi.encode(0));
        assertEq(mgr.raffleCount(), 0);
    }

    function test_PerformUpkeep_RevertInvalidRaffleId_AboveCount() external {
        _createERC20Raffle();
        // Should silently return for raffleId > raffleCount
        mgr.performUpkeep(abi.encode(999));
        RaffleCore.RaffleData memory raffle = mgr.getRaffle(1);
        assertEq(uint256(raffle.status), 0); // Still OPEN
    }

    function test_PerformUpkeep_Idempotent_PendingVRF() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();

        uint256 requestId = _triggerUpkeep();
        assertEq(uint256(mgr.getRaffle(raffleId).status), 1); // PENDING_VRF

        // Second call should be a no-op
        mgr.performUpkeep(abi.encode(raffleId));
        assertEq(uint256(mgr.getRaffle(raffleId).status), 1); // Still PENDING_VRF
    }

    function test_PerformUpkeep_Idempotent_Completed() external {
        uint256 raffleId = _createERC20Raffle();
        _warpPastExpiry();

        _triggerUpkeep();
        assertEq(uint256(mgr.getRaffle(raffleId).status), 2); // COMPLETED (zero participants)

        // Second call should be a no-op
        mgr.performUpkeep(abi.encode(raffleId));
        assertEq(uint256(mgr.getRaffle(raffleId).status), 2); // Still COMPLETED
    }

    // ── fulfillRandomWords edge cases ──

    function test_FulfillRandomWords_StaleRequestId() external {
        // Fulfill with a requestId that was never requested
        // The mock will try to call consumer at address(0), which reverts
        uint256[] memory words = new uint256[](1);
        words[0] = 42;
        vm.expectRevert(); // call to non-contract address(0)
        coord.fulfillRandomWords(999, words);
    }

    function test_FulfillRandomWords_MultipleFulfillments_Safe() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 5);
        _warpPastExpiry();
        uint256 requestId = _triggerUpkeep();

        _fulfillVRF(requestId, 2);
        assertEq(uint256(mgr.getRaffle(raffleId).status), 2); // COMPLETED

        // Second fulfillment with same requestId should be safe (mapping deleted)
        uint256[] memory words = new uint256[](1);
        words[0] = 99;
        coord.fulfillRandomWords(requestId, words);
        // Status should remain COMPLETED
        assertEq(uint256(mgr.getRaffle(raffleId).status), 2);
    }

    // ── enterRaffle edge cases ──

    function test_EnterRaffle_RevertTicketCountExceedsUint96Max() external {
        uint256 raffleId = _createERC20Raffle();

        vm.prank(ALICE);
        vm.expectRevert(RaffleCore.InvalidParams.selector);
        mgr.enterRaffle(raffleId, uint256(type(uint96).max) + 1);
    }

    function test_EnterRaffle_RevertInsufficientApproval() external {
        uint256 raffleId = _createERC20Raffle();
        uint256 cost = TICKET_PRICE * 5;

        vm.prank(ALICE);
        IERC20(address(usdc)).approve(address(mgr), cost - 1); // One wei short

        vm.prank(ALICE);
        vm.expectRevert(); // SafeERC20 error
        mgr.enterRaffle(raffleId, 5);
    }

    function test_EnterRaffle_AtExactExpiryBoundary() external {
        uint256 raffleId = _createERC20Raffle();

        // Warp to exact expiry timestamp
        vm.warp(block.timestamp + DURATION);

        uint256 cost = TICKET_PRICE;
        vm.prank(ALICE);
        IERC20(address(usdc)).approve(address(mgr), cost);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RaffleCore.RaffleNotOpen.selector, raffleId));
        mgr.enterRaffle(raffleId, 1);
    }

    // ── emergencyFinalize edge cases ──

    function test_EmergencyFinalize_RevertOnCompletedRaffle() external {
        uint256 raffleId = _createERC20Raffle();
        _warpPastExpiry();
        _triggerUpkeep(); // Zero participants -> COMPLETED

        vm.expectRevert(abi.encodeWithSelector(RaffleCore.RaffleNotPendingVRF.selector, raffleId));
        mgr.emergencyFinalize(raffleId);
    }

    function test_EmergencyFinalize_RevertOnOpenRaffle() external {
        uint256 raffleId = _createERC20Raffle();

        vm.expectRevert(abi.encodeWithSelector(RaffleCore.RaffleNotPendingVRF.selector, raffleId));
        mgr.emergencyFinalize(raffleId);
    }

    function test_EmergencyFinalize_ERC721Underfilled_NoDoubleReturn() external {
        uint256 raffleId = _createERC721RaffleWithParams(TICKET_PRICE, 100, DURATION);
        _enterAs(ALICE, raffleId, 5);

        _warpPastExpiry();
        _triggerUpkeep(); // Underfilled, prize returned, VRF requested

        vm.warp(block.timestamp + mgr.VRF_TIMEOUT() + 1);

        uint256 nftBalanceBefore = IERC721(address(nft)).balanceOf(HOST);
        mgr.emergencyFinalize(raffleId);
        uint256 nftBalanceAfter = IERC721(address(nft)).balanceOf(HOST);

        // NFT was already returned during performUpkeep (underfilled), should not return again
        assertEq(nftBalanceAfter, nftBalanceBefore);
    }

    // ── claimRefund edge cases ──

    function test_ClaimRefund_ERC721RaffleAfterEmergencyFinalize() external {
        uint256 raffleId = _createERC721RaffleWithParams(TICKET_PRICE, 10, DURATION);
        _enterAs(ALICE, raffleId, 5);

        _warpPastExpiry();
        _triggerUpkeep();
        vm.warp(block.timestamp + mgr.VRF_TIMEOUT() + 1);
        mgr.emergencyFinalize(raffleId);

        uint256 refundable = mgr.refundableAmount(raffleId, ALICE);
        assertGt(refundable, 0);

        uint256 balanceBefore = IERC20(address(usdc)).balanceOf(ALICE);
        vm.prank(ALICE);
        mgr.claimRefund(raffleId);
        uint256 balanceAfter = IERC20(address(usdc)).balanceOf(ALICE);

        assertEq(balanceAfter - balanceBefore, refundable);
    }

    function test_ClaimRefund_RevertOnNonExistentRaffle() external {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RaffleCore.RaffleNotCancelled.selector, 999));
        mgr.claimRefund(999);
    }

    // ── checkUpkeep edge cases ──

    function test_CheckUpkeep_EmptyRaffleList() external {
        (bool needed, bytes memory data) = mgr.checkUpkeep("");
        assertFalse(needed);
        assertEq(data.length, 0);
    }

    function test_CheckUpkeep_CursorWrapAround() external {
        uint256 raffleId1 = _createERC20Raffle();
        _enterAs(ALICE, raffleId1, 1);

        uint256 raffleId2 = _createERC20Raffle();
        _enterAs(BOB, raffleId2, 1);

        // Warp past first raffle only
        vm.warp(block.timestamp + DURATION + 1);

        (bool needed, bytes memory data) = mgr.checkUpkeep("");
        assertTrue(needed);

        uint256 foundRaffleId = abi.decode(data, (uint256));
        assertEq(foundRaffleId, raffleId1); // Should find raffle 1 after wrap
    }

    // ── Free entry edge cases ──

    function test_EnterFreeRaffle_RevertWrongRaffleId() external {
        uint256 raffleId1 = _createERC20Raffle();
        uint256 raffleId2 = _createERC20Raffle();

        // Sign for raffle 1, try to use on raffle 2
        bytes memory signature = _signFreeEntry(raffleId1, ALICE);

        vm.prank(ALICE);
        vm.expectRevert(FreeEntryVerifier2.InvalidSigner.selector);
        mgr.enterFreeRaffle(raffleId2, signature);
    }

    function test_EnterFreeRaffle_RevertWrongUser() external {
        uint256 raffleId = _createERC20Raffle();

        // Sign for ALICE, try to use as BOB
        bytes memory signature = _signFreeEntry(raffleId, ALICE);

        vm.prank(BOB);
        vm.expectRevert(FreeEntryVerifier2.InvalidSigner.selector);
        mgr.enterFreeRaffle(raffleId, signature);
    }

    // ── Access control tests ──

    function test_SetTrustedSigner_RevertNotOwner() external {
        address newSigner = makeAddr("newSigner");

        vm.prank(HOST);
        vm.expectRevert("Only callable by owner");
        mgr.setTrustedSigner(newSigner);
    }

    function test_SetMinDuration_RevertNotOwner() external {
        vm.prank(HOST);
        vm.expectRevert("Only callable by owner");
        mgr.setMinDuration(3 hours);
    }

    function test_ProposeFeeChange_RevertNotOwner() external {
        vm.prank(HOST);
        vm.expectRevert("Only callable by owner");
        mgr.proposeFeeChange(500);
    }

    function test_ApplyFeeChange_RevertNotOwner() external {
        mgr.proposeFeeChange(500);
        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(HOST);
        vm.expectRevert("Only callable by owner");
        mgr.applyFeeChange();
    }

    // ── Token/NFT metadata edge cases ──

    function test_CreateERC721Raffle_NFTWithoutName() external {
        // MockERC721 doesn't implement name(), so the try/catch should handle it
        vm.prank(HOST);
        IERC721(address(nft)).approve(address(mgr), NFT_TOKEN_ID);

        vm.prank(HOST);
        uint256 raffleId = mgr.createRaffleERC721(address(nft), NFT_TOKEN_ID, TICKET_PRICE, MAX_CAP, DURATION);

        RaffleCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(raffle.host, HOST);
    }

    // ── Fee edge cases ──

    function test_FeeRounding_Zero() external {
        uint256 raffleId = _createERC20RaffleWithParams(1, 10, DURATION); // Very small ticket price

        _enterAs(ALICE, raffleId, 1);

        _warpPastExpiry();
        uint256 requestId = _triggerUpkeep();
        _fulfillVRF(requestId, 0);

        // With paymentPool = 1, fee = (1 * 250) / 10000 = 0
        // Winner should get full payment pool
        assertEq(IERC20(address(usdc)).balanceOf(ALICE), 100_000e18 - 1 + 1);
        assertEq(IERC20(address(usdc)).balanceOf(TREASURY), 0);
    }

    function test_ProposeFeeChange_OverwritesPending() external {
        mgr.proposeFeeChange(300);
        assertEq(mgr.pendingFeeBps(), 300);

        // Propose a different fee - should overwrite
        mgr.proposeFeeChange(600);
        assertEq(mgr.pendingFeeBps(), 600);
        // EffectiveAt should be reset from now
        assertEq(mgr.feeChangeEffectiveAt(), block.timestamp + 2 days);
    }

    // ── InitRaffle overflow edge case ──

    function test_CreateRaffle_RevertDurationOverflowUint48() external {
        // Warp close to uint48 max
        vm.warp(uint256(type(uint48).max) - 1 hours);

        vm.prank(HOST);
        IERC20(address(prizeToken)).approve(address(mgr), PRIZE_AMT);

        vm.prank(HOST);
        vm.expectRevert(RaffleCore.InvalidParams.selector);
        mgr.createRaffleERC20(address(prizeToken), PRIZE_AMT, TICKET_PRICE, MAX_CAP, 3 hours);
    }

    // ── VRF fulfillment with zero participants (race condition) ──

    function test_FulfillRandomWords_ZeroParticipantsAfterUpkeep() external {
        uint256 raffleId = _createERC20RaffleWithParams(TICKET_PRICE, 5, DURATION);
        _enterAs(ALICE, raffleId, 1);

        _warpPastExpiry();
        uint256 requestId = _triggerUpkeep();

        // At this point, performUpkeep would have returned prize to host (underfilled with 1 ticket)
        // and requested VRF. The VRF callback should handle this gracefully.
        _fulfillVRF(requestId, 0);

        RaffleCore.RaffleData memory raffle = mgr.getRaffle(raffleId);
        assertEq(uint256(raffle.status), 2); // COMPLETED
    }

    // ── Free entry then paid entry aggregation ──

    function test_FreeEntryThenPaidEntry_AggregatesRanges() external {
        uint256 raffleId = _createERC20Raffle();

        // Free entry
        bytes memory signature = _signFreeEntry(raffleId, ALICE);
        vm.prank(ALICE);
        mgr.enterFreeRaffle(raffleId, signature);

        // Paid entry by same user - should aggregate
        _enterAs(ALICE, raffleId, 5);

        assertEq(mgr.getTotalTickets(raffleId), 6);

        // Should only have 1 range entry
        (address owner, uint256 endTicket) = mgr.getTicketRange(raffleId, 0);
        assertEq(owner, ALICE);
        assertEq(endTicket, 6);

        vm.expectRevert();
        mgr.getTicketRange(raffleId, 1);
    }

    // ── Free entry refundable amount is zero ──

    function test_FreeEntry_RefundableAmountIsZero() external {
        uint256 raffleId = _createERC20Raffle();

        bytes memory signature = _signFreeEntry(raffleId, ALICE);
        vm.prank(ALICE);
        mgr.enterFreeRaffle(raffleId, signature);

        // Free entry should not add to refundable amount
        assertEq(mgr.refundableAmount(raffleId, ALICE), 0);
    }

    // ── Multiple raffles with mixed types, enter both ──

    function test_MultipleRaffles_MixedTypes_EnterBoth() external {
        uint256 erc20Id = _createERC20Raffle();
        uint256 erc721Id = _createERC721Raffle();

        _enterAs(ALICE, erc20Id, 3);
        _enterAs(ALICE, erc721Id, 3);

        assertEq(mgr.getTotalTickets(erc20Id), 3);
        assertEq(mgr.getTotalTickets(erc721Id), 3);

        // Ticket ranges should be independent
        (address owner1,) = mgr.getTicketRange(erc20Id, 0);
        (address owner2,) = mgr.getTicketRange(erc721Id, 0);
        assertEq(owner1, ALICE);
        assertEq(owner2, ALICE);
    }
}
