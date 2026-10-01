// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LotteryCore} from "../src/quiver/LotteryCore.sol";
import {MockQuiverCoordinator} from "./mocks/MockQuiverCoordinator.sol";
import {StandardERC20} from "./mocks/StandardERC20.sol";
import {MockERC721} from "./mocks/MockERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice Shared scaffolding for the LotteryCore suites. Deploys the mock coordinator,
///         registers an active + a fallback provider (both fee 0, known seeds), deploys the
///         contract as owner = this test, sets a 250 bps platform fee via the 2-day timelock,
///         whitelists RESOLVER, and funds the users.
abstract contract QuiverBaseTest is Test {
    LotteryCore mgr;
    MockQuiverCoordinator coord;
    StandardERC20 prizeToken;
    StandardERC20 usdc;
    MockERC721 nft;
    MockERC721 nft2;

    address providerA;
    address providerB;

    address OWNER;
    address RESOLVER;
    address HOST;
    address ALICE;
    address BOB;
    address CHARLIE;
    address TREASURY;
    address SIGNER;
    uint256 SIGNER_PK;

    uint256 constant PRIZE_AMT = 1_000e18;
    uint256 constant TICKET_PRICE = 10e18;
    uint256 constant MAX_CAP = 100;
    uint256 constant DURATION = 1 days;
    uint256 constant FEE_BPS = 250;
    uint256 constant NFT_TOKEN_ID = 42;
    uint256 constant NFT_TOKEN_ID_2 = 99;

    bytes32 constant SALT_1 = keccak256("salt_1");

    function setUp() public virtual {
        OWNER = address(this);
        RESOLVER = makeAddr("resolver");
        HOST = makeAddr("host");
        ALICE = makeAddr("alice");
        BOB = makeAddr("bob");
        CHARLIE = makeAddr("charlie");
        TREASURY = makeAddr("treasury");
        SIGNER_PK = uint256(keccak256("signer_private_key"));
        SIGNER = vm.addr(SIGNER_PK);

        providerA = makeAddr("providerA");
        providerB = makeAddr("providerB");

        coord = new MockQuiverCoordinator();
        // Small chains: the mock computes the anchor by hashing `chainLength` times, and tests
        // only ever consume a handful of links per provider.
        coord.registerProviderWithSeed(providerA, 0, keccak256("seed_a"), 512, 32);
        coord.registerSecondProvider(providerB, 0, keccak256("seed_b"), 512);

        prizeToken = new StandardERC20("Prize", "PZ", 100_000e18);
        usdc = new StandardERC20("USDC", "USDC", 1_000_000e18);
        nft = new MockERC721();
        nft2 = new MockERC721();

        mgr = new LotteryCore({
            _quiver: address(coord),
            _provider: providerA,
            _fallbackProvider: providerB,
            _paymentToken: address(usdc),
            _treasury: TREASURY,
            _trustedSigner: SIGNER,
            _initialOwner: OWNER
        });

        mgr.proposeFeeChange(FEE_BPS);
        vm.warp(block.timestamp + 2 days + 1);
        mgr.applyFeeChange();
        mgr.setResolver(RESOLVER, true);

        prizeToken.transfer(HOST, 50_000e18);
        usdc.transfer(ALICE, 100_000e18);
        usdc.transfer(BOB, 100_000e18);
        usdc.transfer(CHARLIE, 100_000e18);
        nft.mint(HOST, NFT_TOKEN_ID);
        nft.mint(HOST, NFT_TOKEN_ID_2);
        nft2.mint(HOST, 777);
    }

    // ── Raffle creation helpers ───────────────────────────────────────────

    function _createERC20Raffle() internal returns (uint256) {
        return _createERC20RaffleWithParams(TICKET_PRICE, MAX_CAP, DURATION);
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

    // ── Lifecycle helpers ─────────────────────────────────────────────────

    function _warpPastExpiry() internal {
        vm.warp(block.timestamp + DURATION + 1);
    }

    function _userRandomForAttempt(uint256 raffleId, bytes32 salt, uint8 attempt) internal view returns (bytes32) {
        return keccak256(abi.encode(salt, raffleId, attempt, address(mgr), block.chainid));
    }

    /// @notice userRandom for the raffle's currently in-flight request (attempt == recorded count).
    function _userRandom(uint256 raffleId, bytes32 salt) internal view returns (bytes32) {
        return _userRandomForAttempt(raffleId, salt, uint8(mgr.resolveAttempts(raffleId)));
    }

    function _resolve(uint256 raffleId, bytes32 salt) internal {
        vm.prank(RESOLVER);
        mgr.resolveRaffle(raffleId, salt);
    }

    function _retryResolve(uint256 raffleId, bytes32 salt) internal {
        vm.prank(RESOLVER);
        mgr.retryResolve(raffleId, salt);
    }

    /// @notice Drive the mock keeper: reveal the raffle's current request and land the callback.
    function _reveal(uint256 raffleId, bytes32 salt) internal {
        address provider = mgr.activeProviderOf(raffleId);
        uint64 seq = mgr.activeSeq(raffleId);
        coord.revealAuto(provider, seq, _userRandom(raffleId, salt));
    }

    function _settle(uint256 raffleId) internal {
        mgr.settle(raffleId);
    }

    /// @notice Full happy path: assume already expired with tickets → resolve → reveal → settle.
    function _resolveRevealSettle(uint256 raffleId) internal {
        _resolve(raffleId, SALT_1);
        _reveal(raffleId, SALT_1);
        _settle(raffleId);
    }

    // ── Free-entry signing helpers ────────────────────────────────────────

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
}
