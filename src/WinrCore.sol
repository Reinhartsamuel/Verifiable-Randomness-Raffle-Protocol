// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {QuiverConsumer} from "quiver/QuiverConsumer.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {FreeEntryVerifier2} from "./FreeEntryVerifier2.sol";

/// @title  WinrCore
/// @notice Gas-optimised raffle system backed by Quiver VRF (push/callback flow) + a
///         self-operated resolver keeper, on Robinhood Chain. Supports ERC-20 tokens *or*
///         ERC-721 NFTs as the raffle prize. USDC-only ticket payments. Underfilled raffles
///         return the prize to the host and raffle the collected payments to a random
///         winner. Platform fee taken from payment pool (and prize for ERC-20 full-fills).
///         Fee changes require a 2-day timelock.
///
/// @dev    Security model:
///         - Resolution is resolver-gated with a fresh, secret-until-landed salt
///           (`resolveRaffle`/`retryResolve`), not a publicly-derivable on-chain seed. This
///           reduces a malicious/colluding randomness provider to *stalling only* — it can
///           force re-draws (bounded by `MAX_RESOLVE_ATTEMPTS`) or a cancel+refund, but
///           cannot pick the winner.
///         - The Quiver request is wrapped in try/catch so a paused/exhausted/insufficient-fee
///           provider cannot permanently strand a raffle's escrowed funds.
///         - The push-flow callback (`_fulfillRandomness`) never reverts, does no external
///           calls, and is O(1) — it only stores the randomness and flips status to
///           `RESOLVED`. All economic transfers happen in the separate, permissionless
///           `settle()`.
///         - Payouts are push-with-escrow-fallback: a failed transfer (blacklisted winner,
///           reverting/returndata-bomb prize token) is credited to `claimable` / `nftClaimant`
///           instead of reverting the whole settlement.
///         - `(provider, sequenceNumber)` is the request index (not `sequenceNumber` alone),
///           so a second/fallback provider cannot collide with the active provider's numbering.
///         - Prize disposal is centralised and idempotent (`prizeDisposed`), happening exactly
///           once in `settle()` or a cancel path — never at request time, where a retried
///           request could otherwise double-transfer.
///
///   Storage packing: `RaffleData` occupies 5 EVM slots so `getRaffle` ABI decoding is
///   unaffected. All resolution state lives in separate mappings.
contract WinrCore is QuiverConsumer, IERC721Receiver, ReentrancyGuard, FreeEntryVerifier2, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────────
    // Types
    // ──────────────────────────────────────────────────────────────────────

    /// @dev RESOLVED appended at index 4 — indices 0-3 retain their original meaning so any
    ///      frontend/indexer decoding existing enum values does not break.
    enum RaffleStatus {
        OPEN,
        PENDING_VRF,
        COMPLETED,
        CANCELLED,
        RESOLVED
    }

    enum PrizeType {
        ERC20,
        ERC721
    }

    struct RaffleData {
        address host; // 20 B  ┐
        uint48 expiry; //  6 B  │ Slot 0
        RaffleStatus status; //  1 B  │
        bool underfilled; //  1 B  │
        PrizeType prizeType; //  1 B  ┘
        address prizeAsset; // 20 B  ┐
        uint96 ticketsSold; // 12 B  ┘ Slot 1
        uint256 prizeAmountOrTokenId; // 32 B     Slot 2
        uint256 ticketPrice; // 32 B     Slot 3
        uint256 maxCap; // 32 B     Slot 4
    }

    struct TicketRange {
        address owner; // 20 B ┐ Slot 0
        uint96 endTicket; // 12 B ┘
    }

    struct ResolutionState {
        RaffleStatus status;
        uint8 attempts;
        address activeProviderAddr;
        uint64 activeSequence;
        uint48 lastRequestedAt;
        bool underfilled;
        bool prizeDisposedFlag;
    }

    // ──────────────────────────────────────────────────────────────────────
    // State — raffle core
    // ──────────────────────────────────────────────────────────────────────

    mapping(uint256 => RaffleData) public raffles;
    mapping(uint256 => TicketRange[]) public ticketRanges;
    mapping(uint256 => uint96) public totalTickets;
    mapping(uint256 => uint256) private rafflePaymentPool;

    uint256 public raffleCount;

    /// @notice O(1) refund accounting per user per raffle.
    mapping(uint256 => mapping(address => uint256)) public refundableAmount;

    // Payment & fee configuration ─────────────────────────────────────────
    address public immutable paymentToken;
    address public immutable treasury;
    uint256 public platformFeeBps;
    uint256 public constant MAX_PLATFORM_FEE_BPS = 1_000;

    /// @notice Minimum raffle duration. Enforced at ≥ 2 hours.
    uint256 public minDuration = 2 hours;
    uint256 public constant MIN_DURATION_FLOOR = 2 hours;

    // Fee timelock ─────────────────────────────────────────────────────────
    uint256 public pendingFeeBps;
    uint256 public feeChangeEffectiveAt;
    uint256 public constant FEE_TIMELOCK = 2 days;

    // ──────────────────────────────────────────────────────────────────────
    // State — Quiver randomness / resolution
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Randomness delivered for a RESOLVED raffle, consumed once by settle().
    mapping(uint256 => bytes32) public raffleRandomness;
    /// @notice Resolve attempts made so far for a raffle (bounded by MAX_RESOLVE_ATTEMPTS).
    mapping(uint256 => uint8) public resolveAttempts;
    /// @notice Provider servicing the raffle's current in-flight request.
    mapping(uint256 => address) public activeProviderOf;
    /// @notice Sequence number of the raffle's current in-flight request.
    mapping(uint256 => uint64) public activeSeq;
    /// @notice Timestamp of the last successfully-submitted request (stall-timeout anchor).
    mapping(uint256 => uint48) public lastRequestAt;
    /// @notice Idempotency guard — the prize may be disposed (to winner or back to host) once.
    mapping(uint256 => bool) public prizeDisposed;
    /// @notice Per-raffle salt replay guard (a leaked/observed salt cannot be resubmitted).
    mapping(uint256 => mapping(bytes32 => bool)) public usedSalt;
    /// @notice Request index keyed by (provider, sequenceNumber) — fixes cross-provider
    ///         sequence-number collisions from a flat `seq => raffleId` mapping.
    mapping(address => mapping(uint64 => uint256)) private seqToRaffleId;

    address public activeProvider;
    address public fallbackProvider;
    address public pendingActiveProvider;
    address public pendingFallbackProvider;
    uint256 public providerChangeEffectiveAt;
    // uint256 public constant PROVIDER_TIMELOCK = 2 days;
    uint256 public constant PROVIDER_TIMELOCK = 2 seconds;

    uint256 public constant RESOLVE_GRACE = 72 hours;
    uint256 public constant STALL_TIMEOUT = 6 hours;
    uint8 public constant MAX_RESOLVE_ATTEMPTS = 3;
    uint256 public constant HARD_DEADLINE = 7 days;

    uint256 private constant TRANSFER_GAS_LIMIT = 200_000;

    /// @notice Resolver keeper allowlist.
    mapping(address => bool) public isResolver;

    // ──────────────────────────────────────────────────────────────────────
    // State — escrowed payouts (push-with-fallback)
    // ──────────────────────────────────────────────────────────────────────

    mapping(address => mapping(address => uint256)) public claimable; // token => to => amount
    mapping(address => mapping(uint256 => address)) public nftClaimant; // nft => tokenId => claimant

    // ──────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────

    event RaffleCreated(
        uint256 indexed raffleId,
        address indexed host,
        address prizeAsset,
        PrizeType prizeType,
        uint256 prizeAmountOrTokenId,
        uint48 expiry,
        string prizeSymbol,
        uint256 decimals,
        uint256 ticketPrice,
        uint256 maxCap
    );
    event TicketPurchased(uint256 indexed raffleId, address indexed buyer, uint256 ticketCount);
    event WinnerPicked(uint256 indexed raffleId, address indexed winner);
    event RandomnessRequested(uint256 indexed raffleId, address indexed provider, uint64 indexed seq, uint8 attempt);
    event RandomnessFulfilled(uint256 indexed raffleId, uint64 seq, bytes32 randomNumber);
    event RandomnessRequestFailed(uint256 indexed raffleId, address indexed provider, bytes reason);
    event UnexpectedCallback(address indexed provider, uint64 indexed seq);
    event StaleCallback(uint256 indexed raffleId, address indexed provider, uint64 seq);
    event RaffleStalled(uint256 indexed raffleId, uint8 nextAttempt);
    event RaffleExpired(uint256 indexed raffleId);
    event UnderfilledPrizeReturned(uint256 indexed raffleId, address indexed host, uint256 prizeAmountOrTokenId);
    event PlatformFeeCollected(uint256 indexed raffleId, uint256 amount);
    event FeeChangeProposed(uint256 newFeeBps, uint256 effectiveAt);
    event FeeChangeApplied(uint256 oldFeeBps, uint256 newFeeBps);
    event ProviderChangeProposed(address newActiveProvider, address newFallbackProvider, uint256 effectiveAt);
    event ProviderChangeApplied(
        address oldActiveProvider, address oldFallbackProvider, address newActiveProvider, address newFallbackProvider
    );
    event ResolverUpdated(address indexed resolver, bool allowed);
    event RaffleExpiredCancelled(uint256 indexed raffleId);
    event RaffleCancelledStalled(uint256 indexed raffleId);
    event UnderfilledPayout(
        uint256 indexed raffleId, address indexed winner, address paymentToken, uint256 winnerAmount, uint256 feeAmount
    );
    event NFTPrizeAwarded(
        uint256 indexed raffleId,
        address indexed winner,
        address nftContract,
        uint256 tokenId,
        uint256 hostAmount,
        uint256 feeAmount
    );
    event TokenPrizeAwarded(
        uint256 indexed raffleId,
        address indexed winner,
        address prizeAsset,
        uint256 winnerPrizeAmount,
        uint256 hostAmount,
        uint256 prizeFee,
        uint256 paymentFee
    );
    event RefundClaimed(uint256 indexed raffleId, address indexed user, uint256 amount);
    event PayoutEscrowed(address indexed token, address indexed to, uint256 amount);
    event PayoutClaimed(address indexed token, address indexed to, uint256 amount);
    event NftEscrowed(address indexed nft, uint256 indexed tokenId, address indexed claimant);
    event NftClaimed(address indexed nft, uint256 indexed tokenId, address indexed claimant);
    event RandomnessFeeFunded(address indexed from, uint256 amount);
    event NativeWithdrawn(address indexed to, uint256 amount);

    // ──────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────

    error InvalidParams();
    error RaffleNotOpen(uint256 raffleId);
    error MaxCapReached(uint256 raffleId);
    error HostCannotEnter(uint256 raffleId);
    error FeeTooHigh(uint256 requested, uint256 max);
    error FeeTimelockNotElapsed(uint256 effectiveAt);
    error NoFeeChangePending();
    error DurationTooShort(uint256 requested, uint256 minimum);
    error RaffleNotCancelled(uint256 raffleId);
    error NoRefundAvailable();
    error RaffleNotExpired(uint256 raffleId);
    error RaffleHasTickets(uint256 raffleId);
    error RaffleNoTickets(uint256 raffleId);
    error NotResolver(address caller);
    error SaltZero();
    error SaltAlreadyUsed();
    error RaffleNotPendingVrf(uint256 raffleId);
    error StallTimeoutNotReached();
    error MaxAttemptsReached();
    error FailedCallbackPending();
    error RaffleNotResolved(uint256 raffleId);
    error InsufficientFeeBalance(uint256 required, uint256 available);
    error NoPendingProviderChange();
    error ProviderTimelockNotElapsed(uint256 effectiveAt);
    error NoClaimable();
    error NoNftClaim();
    error GraceNotElapsed();
    error StalledConditionNotMet();
    error PrizeAmountMismatch(uint256 requested, uint256 received);
    error NativeTransferFailed();

    // ──────────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────────

    constructor(
        address _quiver,
        address _provider,
        address _fallbackProvider,
        address _paymentToken,
        address _treasury,
        address _trustedSigner,
        address _initialOwner
    ) QuiverConsumer(_quiver, _provider) FreeEntryVerifier2(_trustedSigner) Ownable(_initialOwner) {
        if (_paymentToken == address(0) || _treasury == address(0)) revert InvalidParams();
        paymentToken = _paymentToken;
        treasury = _treasury;
        activeProvider = _provider;
        fallbackProvider = _fallbackProvider;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Admin
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Update the trusted signer for free entry signatures.
    function setTrustedSigner(address _newSigner) external onlyOwner {
        _setTrustedSigner(_newSigner);
    }

    /// @notice Update the minimum raffle duration. Enforced ≥ 2 hours.
    function setMinDuration(uint256 _newMinDuration) external onlyOwner {
        if (_newMinDuration < MIN_DURATION_FLOOR) {
            revert DurationTooShort(_newMinDuration, MIN_DURATION_FLOOR);
        }
        minDuration = _newMinDuration;
    }

    /// @notice Propose a new platform fee. Becomes active after FEE_TIMELOCK.
    function proposeFeeChange(uint256 _newFeeBps) external onlyOwner {
        if (_newFeeBps > MAX_PLATFORM_FEE_BPS) {
            revert FeeTooHigh(_newFeeBps, MAX_PLATFORM_FEE_BPS);
        }
        pendingFeeBps = _newFeeBps;
        feeChangeEffectiveAt = block.timestamp + FEE_TIMELOCK;
        emit FeeChangeProposed(_newFeeBps, feeChangeEffectiveAt);
    }

    /// @notice Apply the pending fee change after the timelock has elapsed.
    function applyFeeChange() external onlyOwner {
        if (feeChangeEffectiveAt == 0) revert NoFeeChangePending();
        if (block.timestamp < feeChangeEffectiveAt) {
            revert FeeTimelockNotElapsed(feeChangeEffectiveAt);
        }
        uint256 oldFee = platformFeeBps;
        platformFeeBps = pendingFeeBps;
        pendingFeeBps = 0;
        feeChangeEffectiveAt = 0;
        emit FeeChangeApplied(oldFee, platformFeeBps);
    }

    /// @notice Propose a new active/fallback Quiver provider pair. Becomes active after
    ///         PROVIDER_TIMELOCK — prevents the owner from instantly swapping in a provider
    ///         it controls to bias an in-flight draw. `_newFallback` may be address(0) to
    ///         disable the fallback (retries stay on the active provider).
    function proposeProviderChange(address _newActive, address _newFallback) external onlyOwner {
        if (_newActive == address(0)) revert InvalidParams();
        pendingActiveProvider = _newActive;
        pendingFallbackProvider = _newFallback;
        providerChangeEffectiveAt = block.timestamp + PROVIDER_TIMELOCK;
        emit ProviderChangeProposed(_newActive, _newFallback, providerChangeEffectiveAt);
    }

    /// @notice Apply the pending provider change after the timelock has elapsed.
    function applyProviderChange() external onlyOwner {
        if (providerChangeEffectiveAt == 0) revert NoPendingProviderChange();
        if (block.timestamp < providerChangeEffectiveAt) {
            revert ProviderTimelockNotElapsed(providerChangeEffectiveAt);
        }
        address oldActive = activeProvider;
        address oldFallback = fallbackProvider;
        activeProvider = pendingActiveProvider;
        fallbackProvider = pendingFallbackProvider;
        pendingActiveProvider = address(0);
        pendingFallbackProvider = address(0);
        providerChangeEffectiveAt = 0;
        emit ProviderChangeApplied(oldActive, oldFallback, activeProvider, fallbackProvider);
    }

    /// @notice Grant/revoke the resolver keeper role.
    function setResolver(address _resolver, bool _allowed) external onlyOwner {
        if (_resolver == address(0)) revert InvalidParams();
        isResolver[_resolver] = _allowed;
        emit ResolverUpdated(_resolver, _allowed);
    }

    /// @notice Pause raffle creation/entry (never resolution, settlement, or refunds).
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ──────────────────────────────────────────────────────────────────────
    // Native fee funding
    // ──────────────────────────────────────────────────────────────────────

    receive() external payable {
        emit RandomnessFeeFunded(msg.sender, msg.value);
    }

    /// @notice Explicit named entrypoint to fund the Quiver randomness fee balance.
    function fundRandomnessFees() external payable {
        emit RandomnessFeeFunded(msg.sender, msg.value);
    }

    /// @notice Withdraw native balance not earmarked for pending requests. Owner-only.
    function withdrawNative(address _to, uint256 _amount) external onlyOwner {
        if (_to == address(0)) revert InvalidParams();
        (bool ok,) = _to.call{value: _amount}("");
        if (!ok) revert NativeTransferFailed();
        emit NativeWithdrawn(_to, _amount);
    }

    /// @notice Current fee (in wei) to request from the active provider.
    function randomnessFee() external view returns (uint128) {
        return QUIVER.getFee(activeProvider);
    }

    // ──────────────────────────────────────────────────────────────────────
    // ERC-721 receiver
    // ──────────────────────────────────────────────────────────────────────

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Core – raffle creation
    // ──────────────────────────────────────────────────────────────────────

    function createRaffleERC20(
        address _asset,
        uint256 _amount,
        uint256 _ticketPrice,
        uint256 _maxCap,
        uint256 _duration
    ) external nonReentrant whenNotPaused returns (uint256 raffleId) {
        if (_asset == address(0) || _amount == 0 || _ticketPrice == 0 || _maxCap == 0 || _duration == 0) {
            revert InvalidParams();
        }
        if (_duration < minDuration) {
            revert DurationTooShort(_duration, minDuration);
        }

        raffleId = _initRaffle(msg.sender, _asset, PrizeType.ERC20, _amount, _ticketPrice, _maxCap, _duration);

        uint256 balBefore = IERC20(_asset).balanceOf(address(this));
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 received = IERC20(_asset).balanceOf(address(this)) - balBefore;
        if (received != _amount) revert PrizeAmountMismatch(_amount, received);

        string memory sym = IERC20Metadata(_asset).symbol();
        uint256 dec = IERC20Metadata(_asset).decimals();

        emit RaffleCreated(
            raffleId,
            msg.sender,
            _asset,
            PrizeType.ERC20,
            _amount,
            uint48(block.timestamp + _duration),
            sym,
            dec,
            _ticketPrice,
            _maxCap
        );
    }

    function createRaffleERC721(
        address _nft,
        uint256 _tokenId,
        uint256 _ticketPrice,
        uint256 _maxCap,
        uint256 _duration
    ) external nonReentrant whenNotPaused returns (uint256 raffleId) {
        if (_nft == address(0) || _ticketPrice == 0 || _maxCap == 0 || _duration == 0) {
            revert InvalidParams();
        }
        if (_duration < minDuration) {
            revert DurationTooShort(_duration, minDuration);
        }

        raffleId = _initRaffle(msg.sender, _nft, PrizeType.ERC721, _tokenId, _ticketPrice, _maxCap, _duration);

        IERC721(_nft).safeTransferFrom(msg.sender, address(this), _tokenId);
        if (IERC721(_nft).ownerOf(_tokenId) != address(this)) {
            revert PrizeAmountMismatch(_tokenId, 0);
        }

        string memory sym = "";
        try IERC721Metadata(_nft).name() returns (string memory n) {
            sym = n;
        } catch {}

        emit RaffleCreated(
            raffleId,
            msg.sender,
            _nft,
            PrizeType.ERC721,
            _tokenId,
            uint48(block.timestamp + _duration),
            sym,
            0,
            _ticketPrice,
            _maxCap
        );
    }

    // ──────────────────────────────────────────────────────────────────────
    // Core – ticket purchase
    // ──────────────────────────────────────────────────────────────────────

    function enterRaffle(uint256 _raffleId, uint256 _ticketCount) external nonReentrant whenNotPaused {
        RaffleData storage raffle = raffles[_raffleId];

        if (raffle.status != RaffleStatus.OPEN || block.timestamp >= raffle.expiry) revert RaffleNotOpen(_raffleId);
        if (msg.sender == raffle.host) revert HostCannotEnter(_raffleId);
        if (_ticketCount == 0) revert InvalidParams();
        if (_ticketCount > type(uint96).max) revert InvalidParams();

        uint256 currentTotal = totalTickets[_raffleId];
        if (currentTotal + _ticketCount > raffle.maxCap) {
            revert MaxCapReached(_raffleId);
        }

        uint256 totalCost = raffle.ticketPrice * _ticketCount;
        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), totalCost);

        _addTickets(_raffleId, msg.sender, _ticketCount, totalCost);
        raffle.ticketsSold += uint96(_ticketCount);
        rafflePaymentPool[_raffleId] += totalCost;

        emit TicketPurchased(_raffleId, msg.sender, _ticketCount);
    }

    function enterFreeRaffle(uint256 _raffleId, bytes calldata _signature) external nonReentrant whenNotPaused {
        RaffleData storage raffle = raffles[_raffleId];

        if (raffle.status != RaffleStatus.OPEN || block.timestamp >= raffle.expiry) revert RaffleNotOpen(_raffleId);
        if (msg.sender == raffle.host) revert HostCannotEnter(_raffleId);
        if (totalTickets[_raffleId] + 1 > raffle.maxCap) {
            revert MaxCapReached(_raffleId);
        }

        verifyAndClaim(_raffleId, msg.sender, _signature);

        _addTickets(_raffleId, msg.sender, 1, 0);
        raffle.ticketsSold += 1;

        emit TicketPurchased(_raffleId, msg.sender, 1);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Resolution — resolver-gated request, permissionless retry poke / settle
    // ──────────────────────────────────────────────────────────────────────

    modifier onlyResolver() {
        if (!isResolver[msg.sender]) revert NotResolver(msg.sender);
        _;
    }

    /// @notice Kick off resolution of an expired, ticketed raffle. Resolver-only. `_salt`
    ///         must be a fresh, off-chain CSPRNG value that stays secret until this tx lands —
    ///         it is folded into the request's user-contribution so the randomness provider
    ///         cannot precompute or grind the outcome.
    function resolveRaffle(uint256 _raffleId, bytes32 _salt) external onlyResolver nonReentrant {
        RaffleData storage raffle = raffles[_raffleId];
        if (raffle.status != RaffleStatus.OPEN) revert RaffleNotOpen(_raffleId);
        if (block.timestamp < raffle.expiry) revert RaffleNotExpired(_raffleId);

        uint256 total = totalTickets[_raffleId];
        if (total == 0) revert RaffleNoTickets(_raffleId);

        if (total < raffle.maxCap && !raffle.underfilled) {
            raffle.underfilled = true;
        }

        _requestResolution(_raffleId, raffle, _salt, activeProvider);
    }

    /// @notice Retry a stalled PENDING_VRF raffle whose callback never arrived. Resolver-only.
    ///         Uses the fallback provider when one is configured, else retries the active
    ///         provider. Bounded by MAX_RESOLVE_ATTEMPTS.
    function retryResolve(uint256 _raffleId, bytes32 _salt) external onlyResolver nonReentrant {
        RaffleData storage raffle = raffles[_raffleId];
        if (raffle.status != RaffleStatus.PENDING_VRF) revert RaffleNotPendingVrf(_raffleId);
        if (block.timestamp < lastRequestAt[_raffleId] + STALL_TIMEOUT) revert StallTimeoutNotReached();
        if (resolveAttempts[_raffleId] >= MAX_RESOLVE_ATTEMPTS) revert MaxAttemptsReached();

        address provider = activeProviderOf[_raffleId];
        (bool hasFailed,) = QUIVER.getFailedCallback(provider, activeSeq[_raffleId]);
        if (hasFailed) revert FailedCallbackPending();

        address nextProvider = fallbackProvider != address(0) ? fallbackProvider : activeProvider;
        emit RaffleStalled(_raffleId, resolveAttempts[_raffleId] + 1);
        _requestResolution(_raffleId, raffle, _salt, nextProvider);
    }

    /// @notice Redeliver a previously-failed callback for a raffle's active request.
    ///         Permissionless — anyone can nudge the coordinator's retry buffer.
    function pokeFailedCallback(uint256 _raffleId) external nonReentrant {
        if (raffles[_raffleId].status != RaffleStatus.PENDING_VRF) revert RaffleNotPendingVrf(_raffleId);
        QUIVER.retryCallback(activeProviderOf[_raffleId], activeSeq[_raffleId]);
    }

    function _requestResolution(uint256 _raffleId, RaffleData storage _raffle, bytes32 _salt, address _provider)
        internal
    {
        if (_salt == bytes32(0)) revert SaltZero();
        if (usedSalt[_raffleId][_salt]) revert SaltAlreadyUsed();
        usedSalt[_raffleId][_salt] = true;

        uint128 fee;
        try QUIVER.getFee(_provider) returns (uint128 f) {
            fee = f;
        } catch (bytes memory reason) {
            emit RandomnessRequestFailed(_raffleId, _provider, reason);
            return;
        }

        // Underfunded fee balance is the operator's own fault (only the resolver calls this
        // path) — revert loudly rather than silently stalling the raffle.
        if (address(this).balance < fee) revert InsufficientFeeBalance(fee, address(this).balance);

        uint8 attempt = resolveAttempts[_raffleId] + 1;
        bytes32 userRandom = keccak256(abi.encode(_salt, _raffleId, attempt, address(this), block.chainid));

        try QUIVER.requestWithCallback{value: fee}(_provider, userRandom) returns (uint64 seq) {
            resolveAttempts[_raffleId] = attempt;
            activeProviderOf[_raffleId] = _provider;
            activeSeq[_raffleId] = seq;
            lastRequestAt[_raffleId] = uint48(block.timestamp);
            seqToRaffleId[_provider][seq] = _raffleId;
            _raffle.status = RaffleStatus.PENDING_VRF;
            emit RandomnessRequested(_raffleId, _provider, seq, attempt);
        } catch (bytes memory reason) {
            emit RandomnessRequestFailed(_raffleId, _provider, reason);
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // Quiver VRF – fulfillment callback (lean: no external calls, never reverts)
    // ──────────────────────────────────────────────────────────────────────

    function _fulfillRandomness(uint64 seq, address provider, bytes32 rnd) internal override {
        uint256 raffleId = seqToRaffleId[provider][seq];
        if (raffleId == 0) {
            emit UnexpectedCallback(provider, seq);
            return;
        }

        RaffleData storage raffle = raffles[raffleId];
        if (raffle.status != RaffleStatus.PENDING_VRF) {
            emit StaleCallback(raffleId, provider, seq);
            return;
        }
        if (activeSeq[raffleId] != seq || activeProviderOf[raffleId] != provider) {
            emit StaleCallback(raffleId, provider, seq);
            return;
        }

        delete seqToRaffleId[provider][seq];
        raffleRandomness[raffleId] = rnd;
        raffle.status = RaffleStatus.RESOLVED;
        emit RandomnessFulfilled(raffleId, seq, rnd);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Settlement — permissionless, pays out exactly once
    // ──────────────────────────────────────────────────────────────────────

    function settle(uint256 _raffleId) external nonReentrant {
        RaffleData storage raffle = raffles[_raffleId];
        if (raffle.status != RaffleStatus.RESOLVED) revert RaffleNotResolved(_raffleId);

        bytes32 rnd = raffleRandomness[_raffleId];
        uint256 total = totalTickets[_raffleId];
        uint256 winningTicket = (uint256(rnd) % total) + 1;
        address winner = _findWinner(_raffleId, winningTicket);

        raffle.status = RaffleStatus.COMPLETED;

        if (raffle.underfilled) {
            _disposePrizeToHost(_raffleId, raffle);
            _distributeUnderfilledPayment(_raffleId, winner);
        } else if (raffle.prizeType == PrizeType.ERC721) {
            _distributeERC721(_raffleId, raffle, winner);
        } else {
            _distributeERC20FullFill(_raffleId, raffle, winner);
        }

        emit WinnerPicked(_raffleId, winner);
    }

    /// @notice Permissionless completion for a raffle that expired with zero entrants.
    function completeEmptyRaffle(uint256 _raffleId) external nonReentrant {
        RaffleData storage raffle = raffles[_raffleId];
        if (raffle.status != RaffleStatus.OPEN) revert RaffleNotOpen(_raffleId);
        if (block.timestamp < raffle.expiry) revert RaffleNotExpired(_raffleId);
        if (totalTickets[_raffleId] != 0) revert RaffleHasTickets(_raffleId);

        raffle.underfilled = true;
        raffle.status = RaffleStatus.COMPLETED;
        _disposePrizeToHost(_raffleId, raffle);
        emit RaffleExpired(_raffleId);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Cancellation (liveness fallback) — refunds, never a weak-entropy resolve
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Cancel a raffle that expired without ever getting a successful randomness
    ///         request in flight. Permissionless, but gated by RESOLVE_GRACE so it cannot
    ///         front-run the resolver keeper the instant a raffle expires.
    function cancelExpiredRaffle(uint256 _raffleId) external nonReentrant {
        RaffleData storage raffle = raffles[_raffleId];
        if (raffle.status != RaffleStatus.OPEN) revert RaffleNotOpen(_raffleId);
        if (block.timestamp < raffle.expiry + RESOLVE_GRACE) revert GraceNotElapsed();

        raffle.status = RaffleStatus.CANCELLED;
        _disposePrizeToHost(_raffleId, raffle);
        emit RaffleExpiredCancelled(_raffleId);
    }

    /// @notice Cancel a raffle stuck in PENDING_VRF because the provider withheld its reveal
    ///         across every retry attempt, or because HARD_DEADLINE has passed regardless.
    ///         Permissionless.
    function cancelStalledRaffle(uint256 _raffleId) external nonReentrant {
        RaffleData storage raffle = raffles[_raffleId];
        if (raffle.status != RaffleStatus.PENDING_VRF) revert RaffleNotPendingVrf(_raffleId);

        bool attemptsExhausted = resolveAttempts[_raffleId] >= MAX_RESOLVE_ATTEMPTS
            && block.timestamp >= lastRequestAt[_raffleId] + STALL_TIMEOUT;
        bool hardDeadlinePassed = block.timestamp >= raffle.expiry + HARD_DEADLINE;
        if (!attemptsExhausted && !hardDeadlinePassed) revert StalledConditionNotMet();

        raffle.status = RaffleStatus.CANCELLED;
        _disposePrizeToHost(_raffleId, raffle);
        emit RaffleCancelledStalled(_raffleId);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Participant refunds (pull-based, O(1))
    // ──────────────────────────────────────────────────────────────────────

    function claimRefund(uint256 _raffleId) external nonReentrant {
        RaffleData storage raffle = raffles[_raffleId];
        if (raffle.status != RaffleStatus.CANCELLED) revert RaffleNotCancelled(_raffleId);

        uint256 amount = refundableAmount[_raffleId][msg.sender];
        if (amount == 0) revert NoRefundAvailable();

        refundableAmount[_raffleId][msg.sender] = 0;
        IERC20(paymentToken).safeTransfer(msg.sender, amount);
        emit RefundClaimed(_raffleId, msg.sender, amount);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Escrowed payout claims (pull-only)
    // ──────────────────────────────────────────────────────────────────────

    function claim(address _token) external nonReentrant {
        uint256 amount = claimable[_token][msg.sender];
        if (amount == 0) revert NoClaimable();
        claimable[_token][msg.sender] = 0;
        IERC20(_token).safeTransfer(msg.sender, amount);
        emit PayoutClaimed(_token, msg.sender, amount);
    }

    function claimNft(address _nft, uint256 _tokenId) external nonReentrant {
        if (nftClaimant[_nft][_tokenId] != msg.sender) revert NoNftClaim();
        delete nftClaimant[_nft][_tokenId];
        IERC721(_nft).transferFrom(address(this), msg.sender, _tokenId);
        emit NftClaimed(_nft, _tokenId, msg.sender);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────────────────────────────

    function getRaffle(uint256 _raffleId) external view returns (RaffleData memory) {
        return raffles[_raffleId];
    }

    function getTotalTickets(uint256 _raffleId) external view returns (uint256) {
        return totalTickets[_raffleId];
    }

    function getTicketRange(uint256 _raffleId, uint256 _index)
        external
        view
        returns (address owner, uint256 endTicket)
    {
        TicketRange storage range = ticketRanges[_raffleId][_index];
        return (range.owner, range.endTicket);
    }

    function getResolutionState(uint256 _raffleId) external view returns (ResolutionState memory) {
        return ResolutionState({
            status: raffles[_raffleId].status,
            attempts: resolveAttempts[_raffleId],
            activeProviderAddr: activeProviderOf[_raffleId],
            activeSequence: activeSeq[_raffleId],
            lastRequestedAt: lastRequestAt[_raffleId],
            underfilled: raffles[_raffleId].underfilled,
            prizeDisposedFlag: prizeDisposed[_raffleId]
        });
    }

    /// @notice Keeper helper: up to `_limit` OPEN, ticketed, expired raffle ids from `_cursor`.
    function pendingResolution(uint256 _cursor, uint256 _limit)
        external
        view
        returns (uint256[] memory raffleIds, uint256 nextCursor)
    {
        uint256[] memory buf = new uint256[](_limit);
        uint256 count;
        uint256 i = _cursor + 1;
        for (; i <= raffleCount && count < _limit; ++i) {
            RaffleData storage r = raffles[i];
            if (r.status == RaffleStatus.OPEN && block.timestamp >= r.expiry && totalTickets[i] > 0) {
                buf[count++] = i;
            }
        }
        raffleIds = new uint256[](count);
        for (uint256 j = 0; j < count; ++j) {
            raffleIds[j] = buf[j];
        }
        nextCursor = i > raffleCount ? 0 : i - 1;
    }

    /// @notice Keeper helper: up to `_limit` PENDING_VRF raffle ids stalled past STALL_TIMEOUT.
    function stalledRaffles(uint256 _cursor, uint256 _limit)
        external
        view
        returns (uint256[] memory raffleIds, uint256 nextCursor)
    {
        uint256[] memory buf = new uint256[](_limit);
        uint256 count;
        uint256 i = _cursor + 1;
        for (; i <= raffleCount && count < _limit; ++i) {
            if (raffles[i].status == RaffleStatus.PENDING_VRF && block.timestamp >= lastRequestAt[i] + STALL_TIMEOUT) {
                buf[count++] = i;
            }
        }
        raffleIds = new uint256[](count);
        for (uint256 j = 0; j < count; ++j) {
            raffleIds[j] = buf[j];
        }
        nextCursor = i > raffleCount ? 0 : i - 1;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ──────────────────────────────────────────────────────────────────────

    function _initRaffle(
        address _host,
        address _asset,
        PrizeType _prizeType,
        uint256 _prizeAmountOrTokenId,
        uint256 _ticketPrice,
        uint256 _maxCap,
        uint256 _duration
    ) internal returns (uint256 raffleId) {
        if (block.timestamp + _duration > type(uint48).max) {
            revert InvalidParams();
        }
        if (_maxCap > type(uint96).max) revert InvalidParams();

        raffleId = ++raffleCount;
        raffles[raffleId] = RaffleData({
            host: _host,
            expiry: uint48(block.timestamp + _duration),
            status: RaffleStatus.OPEN,
            underfilled: false,
            prizeType: _prizeType,
            prizeAsset: _asset,
            ticketsSold: 0,
            prizeAmountOrTokenId: _prizeAmountOrTokenId,
            ticketPrice: _ticketPrice,
            maxCap: _maxCap
        });
    }

    function _addTickets(uint256 _raffleId, address _buyer, uint256 _ticketCount, uint256 _amountPaid) internal {
        if (_ticketCount > type(uint96).max) revert InvalidParams();
        TicketRange[] storage ranges = ticketRanges[_raffleId];
        uint256 len = ranges.length;
        uint96 currentTotal = totalTickets[_raffleId];
        uint96 newTotal = currentTotal + uint96(_ticketCount);

        // Aggregate consecutive purchases by the same buyer to save storage
        if (len > 0 && ranges[len - 1].owner == _buyer) {
            ranges[len - 1].endTicket = newTotal;
        } else {
            ranges.push(TicketRange({owner: _buyer, endTicket: newTotal}));
        }
        totalTickets[_raffleId] = newTotal;

        // O(1) refund accounting (uint256 prevents any overflow)
        refundableAmount[_raffleId][_buyer] += _amountPaid;
    }

    function _computeFee(uint256 _amount) internal view returns (uint256) {
        return (_amount * platformFeeBps) / 10_000;
    }

    /// @dev O(log N) binary search for winner selection.
    function _findWinner(uint256 _raffleId, uint256 _winningTicket) internal view returns (address) {
        TicketRange[] storage ranges = ticketRanges[_raffleId];
        uint256 low = 0;
        uint256 high = ranges.length - 1;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (_winningTicket <= ranges[mid].endTicket) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        return ranges[low].owner;
    }

    /// @dev Idempotent: disposes the raw prize (ERC-20 amount or ERC-721 tokenId) back to the
    ///      host. Used by settle() for underfilled raffles and by both cancel paths. Routed
    ///      through the escrow-capable payout helpers so a misbehaving prize token/host cannot
    ///      brick settlement or cancellation.
    function _disposePrizeToHost(uint256 _raffleId, RaffleData storage _raffle) internal {
        if (prizeDisposed[_raffleId]) return;
        prizeDisposed[_raffleId] = true;
        if (_raffle.prizeType == PrizeType.ERC721) {
            _payoutNft(_raffle.prizeAsset, _raffle.host, _raffle.prizeAmountOrTokenId);
        } else {
            _payout(_raffle.prizeAsset, _raffle.host, _raffle.prizeAmountOrTokenId);
        }
        emit UnderfilledPrizeReturned(_raffleId, _raffle.host, _raffle.prizeAmountOrTokenId);
    }

    function _distributeUnderfilledPayment(uint256 _raffleId, address _winner) internal {
        uint256 paymentPool = rafflePaymentPool[_raffleId];
        delete rafflePaymentPool[_raffleId];
        uint256 fee = _computeFee(paymentPool);

        _payout(paymentToken, _winner, paymentPool - fee);
        if (fee > 0) {
            _payout(paymentToken, treasury, fee);
            emit PlatformFeeCollected(_raffleId, fee);
        }
        emit UnderfilledPayout(_raffleId, _winner, paymentToken, paymentPool - fee, fee);
    }

    function _distributeERC20FullFill(uint256 _raffleId, RaffleData storage _raffle, address _winner) internal {
        uint256 paymentPool = rafflePaymentPool[_raffleId];
        delete rafflePaymentPool[_raffleId];
        uint256 paymentFee = _computeFee(paymentPool);
        uint256 prizeFee = _computeFee(_raffle.prizeAmountOrTokenId);

        if (!prizeDisposed[_raffleId]) {
            prizeDisposed[_raffleId] = true;
            _payout(_raffle.prizeAsset, _winner, _raffle.prizeAmountOrTokenId - prizeFee);
            if (prizeFee > 0) {
                _payout(_raffle.prizeAsset, treasury, prizeFee);
            }
        }
        _payout(paymentToken, _raffle.host, paymentPool - paymentFee);
        if (paymentFee > 0) {
            _payout(paymentToken, treasury, paymentFee);
        }

        uint256 totalFees = prizeFee + paymentFee;
        if (totalFees > 0) emit PlatformFeeCollected(_raffleId, totalFees);
        emit TokenPrizeAwarded(
            _raffleId,
            _winner,
            _raffle.prizeAsset,
            _raffle.prizeAmountOrTokenId - prizeFee,
            paymentPool - paymentFee,
            prizeFee,
            paymentFee
        );
    }

    function _distributeERC721(uint256 _raffleId, RaffleData storage _raffle, address _winner) internal {
        uint256 paymentPool = rafflePaymentPool[_raffleId];
        delete rafflePaymentPool[_raffleId];
        uint256 paymentFee = _computeFee(paymentPool);

        if (!prizeDisposed[_raffleId]) {
            prizeDisposed[_raffleId] = true;
            _payoutNft(_raffle.prizeAsset, _winner, _raffle.prizeAmountOrTokenId);
        }

        _payout(paymentToken, _raffle.host, paymentPool - paymentFee);
        if (paymentFee > 0) {
            _payout(paymentToken, treasury, paymentFee);
            emit PlatformFeeCollected(_raffleId, paymentFee);
        }
        emit NFTPrizeAwarded(
            _raffleId, _winner, _raffle.prizeAsset, _raffle.prizeAmountOrTokenId, paymentPool - paymentFee, paymentFee
        );
    }

    /// @dev Non-reverting ERC-20 payout: on failure, credits `claimable` instead of bricking
    ///      the caller (settle/cancel). Bounded gas + truncated returndata copy make this
    ///      safe against reentrancy attempts and returndata-bomb tokens.
    function _payout(address _token, address _to, uint256 _amount) internal {
        if (_amount == 0) return;
        if (_tryTransfer(_token, _to, _amount)) return;
        claimable[_token][_to] += _amount;
        emit PayoutEscrowed(_token, _to, _amount);
    }

    function _tryTransfer(address _token, address _to, uint256 _amount) private returns (bool ok) {
        bytes memory callData = abi.encodeWithSelector(IERC20.transfer.selector, _to, _amount);
        uint256 gasLimit = TRANSFER_GAS_LIMIT;
        bool success;
        uint256 retSize;
        assembly {
            success := call(gasLimit, _token, 0, add(callData, 0x20), mload(callData), 0, 0x20)
            retSize := returndatasize()
            if gt(retSize, 32) { retSize := 32 }
            returndatacopy(0, 0, retSize)
        }
        if (!success) return false;
        if (retSize == 0) return true; // non-standard token with no return value
        uint256 decoded;
        assembly {
            decoded := mload(0)
        }
        return decoded != 0;
    }

    /// @dev Non-reverting ERC-721 payout: on failure, credits `nftClaimant` instead of
    ///      bricking settlement. Uses `transferFrom` (not `safeTransferFrom`) so a recipient
    ///      contract's `onERC721Received` cannot itself grief the transfer.
    function _payoutNft(address _nft, address _to, uint256 _tokenId) internal {
        bytes memory callData = abi.encodeWithSelector(IERC721.transferFrom.selector, address(this), _to, _tokenId);
        uint256 gasLimit = TRANSFER_GAS_LIMIT;
        address nft = _nft;
        bool success;
        assembly {
            success := call(gasLimit, nft, 0, add(callData, 0x20), mload(callData), 0, 0)
        }
        if (!success) {
            nftClaimant[_nft][_tokenId] = _to;
            emit NftEscrowed(_nft, _tokenId, _to);
        }
    }
}
