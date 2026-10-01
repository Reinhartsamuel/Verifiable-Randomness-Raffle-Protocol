// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {
    AutomationCompatibleInterface
} from "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {FreeEntryVerifier2} from "../FreeEntryVerifier2.sol";

/// @title  RaffleCore
/// @notice Gas-optimised raffle system backed by Chainlink VRF v2.5 and Automation.
///         Supports ERC-20 tokens *or* ERC-721 NFTs as the raffle prize.
///         USDC-only ticket payments. Underfilled raffles return the prize to the
///         host and raffle the collected payments to a random winner.
///         Platform fee taken from payment pool (and prize for ERC-20 full-fills).
///         Fee changes require a 2-day timelock to reduce centralisation risk.
///
/// @dev    Security-hardened fork of RaffleManager6. Changes:
///         - V7 ARCHITECTURAL UPGRADE 1: Binary search for O(log N) winner selection
///         - V7 ARCHITECTURAL UPGRADE 2: O(1) pull-based refunds via separate mapping (DoS proof)
///         - V7 ARCHITECTURAL UPGRADE 3: TicketRange reduced to 1 storage slot (removed amountPaid)
///         - V7 ARCHITECTURAL UPGRADE 4: refundableAmount uses uint256 to prevent any overflow
///
///   Storage packing: 5 EVM slots per raffle. 1 EVM slot per ticket range.
contract RaffleCore is
    VRFConsumerBaseV2Plus,
    AutomationCompatibleInterface,
    IERC721Receiver,
    ReentrancyGuard,
    FreeEntryVerifier2
{
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────────
    // Types
    // ──────────────────────────────────────────────────────────────────────

    enum RaffleStatus {
        OPEN,
        PENDING_VRF,
        COMPLETED,
        CANCELLED
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

    // ──────────────────────────────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────────────────────────────

    mapping(uint256 => RaffleData) public raffles;
    mapping(uint256 => TicketRange[]) public ticketRanges;
    mapping(uint256 => uint96) public totalTickets;
    mapping(uint256 => uint256) private requestIdToRaffleId;
    mapping(uint256 => uint256) private rafflePaymentPool;

    /// @notice Tracks when VRF was requested per raffle (for timeout recovery).
    mapping(uint256 => uint48) private raffleVrfRequestedAt;

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

    // VRF configuration ────────────────────────────────────────────────────
    bytes32 private immutable s_keyHash;
    uint256 private immutable s_subId;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant CALLBACK_GAS_LIMIT = 300_000;
    uint32 private constant NUM_WORDS = 1;

    /// @notice How long to wait before a stuck PENDING_VRF raffle can be emergency-finalized.
    uint256 public constant VRF_TIMEOUT = 24 hours;

    // CheckUpkeep pagination ───────────────────────────────────────────────
    uint256 public lastCheckedRaffleId;
    uint256 public constant CHECK_UPKEEP_BATCH = 50;

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
    event VRFRequested(uint256 indexed raffleId, uint256 requestId);
    event RaffleExpired(uint256 indexed raffleId);
    event UnderfilledPrizeReturned(uint256 indexed raffleId, address indexed host, uint256 prizeAmountOrTokenId);
    event PlatformFeeCollected(uint256 indexed raffleId, uint256 amount);
    event FeeChangeProposed(uint256 newFeeBps, uint256 effectiveAt);
    event FeeChangeApplied(uint256 oldFeeBps, uint256 newFeeBps);
    event RaffleEmergencyFinalized(uint256 indexed raffleId);
    event RaffleExpiredCancelled(uint256 indexed raffleId);
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
    error RaffleNotPendingVRF(uint256 raffleId);
    error VRFTimeoutNotReached();
    error RaffleNotCancelled(uint256 raffleId);
    error NoRefundAvailable();
    error RaffleNotExpired(uint256 raffleId);
    error RaffleAlreadyRequestedVRF(uint256 raffleId);

    // ──────────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────────

    constructor(
        address _vrfCoordinator,
        bytes32 _keyHash,
        uint256 _subId,
        address _paymentToken,
        address _treasury,
        address _trustedSigner
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) FreeEntryVerifier2(_trustedSigner) {
        if (_paymentToken == address(0) || _treasury == address(0) || _trustedSigner == address(0)) revert InvalidParams();
        s_keyHash = _keyHash;
        s_subId = _subId;
        paymentToken = _paymentToken;
        treasury = _treasury;
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

    /// @notice Finalize a raffle stuck in PENDING_VRF after VRF_TIMEOUT.
    ///         Permissionless — anyone can call. Returns the prize to the host
    ///         and marks the raffle CANCELLED so participants can pull their refunds.
    function emergencyFinalize(uint256 _raffleId) external nonReentrant {
        RaffleData storage raffle = raffles[_raffleId];
        if (raffle.status != RaffleStatus.PENDING_VRF) {
            revert RaffleNotPendingVRF(_raffleId);
        }
        if (block.timestamp < raffleVrfRequestedAt[_raffleId] + VRF_TIMEOUT) {
            revert VRFTimeoutNotReached();
        }

        raffle.status = RaffleStatus.CANCELLED;
        delete raffleVrfRequestedAt[_raffleId];

        // Return prize to host (skip if already returned by performUpkeep for underfilled raffles)
        if (!raffle.underfilled) {
            if (raffle.prizeType == PrizeType.ERC721) {
                IERC721(raffle.prizeAsset).transferFrom(address(this), raffle.host, raffle.prizeAmountOrTokenId);
            } else {
                IERC20(raffle.prizeAsset).safeTransfer(raffle.host, raffle.prizeAmountOrTokenId);
            }
        }

        // Payment pool remains in contract for users to withdraw via claimRefund

        emit RaffleEmergencyFinalized(_raffleId);
    }

    /// @notice Cancel a raffle that expired without getting a VRF request.
    ///         Permissionless — anyone can call. Only callable when:
    ///         - status == OPEN
    ///         - past expiry
    ///         - VRF was never requested (raffleVrfRequestedAt == 0)
    ///         Returns prize to host and enables participant refunds.
    function cancelExpiredRaffle(uint256 _raffleId) external nonReentrant {
        RaffleData storage raffle = raffles[_raffleId];
        if (raffle.status != RaffleStatus.OPEN) {
            revert RaffleNotOpen(_raffleId);
        }
        if (block.timestamp < raffle.expiry) {
            revert RaffleNotExpired(_raffleId);
        }
        if (raffleVrfRequestedAt[_raffleId] != 0) {
            revert RaffleAlreadyRequestedVRF(_raffleId);
        }

        raffle.status = RaffleStatus.CANCELLED;

        _returnPrizeToHost(_raffleId, raffle);

        emit RaffleExpiredCancelled(_raffleId);
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
    ) external returns (uint256 raffleId) {
        if (_asset == address(0) || _amount == 0 || _ticketPrice == 0 || _maxCap == 0 || _duration == 0) {
            revert InvalidParams();
        }
        if (_duration < minDuration) {
            revert DurationTooShort(_duration, minDuration);
        }

        raffleId = _initRaffle(msg.sender, _asset, PrizeType.ERC20, _amount, _ticketPrice, _maxCap, _duration);

        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);

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
    ) external returns (uint256 raffleId) {
        if (_nft == address(0) || _ticketPrice == 0 || _maxCap == 0 || _duration == 0) {
            revert InvalidParams();
        }
        if (_duration < minDuration) {
            revert DurationTooShort(_duration, minDuration);
        }

        raffleId = _initRaffle(msg.sender, _nft, PrizeType.ERC721, _tokenId, _ticketPrice, _maxCap, _duration);

        IERC721(_nft).safeTransferFrom(msg.sender, address(this), _tokenId);

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

    function enterRaffle(uint256 _raffleId, uint256 _ticketCount) external nonReentrant {
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

    function enterFreeRaffle(uint256 _raffleId, bytes calldata _signature) external nonReentrant {
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
    // Chainlink Automation (paginated)
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Paginated scan: checks up to CHECK_UPKEEP_BATCH raffles per call.
    ///         Wraps around from cursor to catch raffles that expired after
    ///         the cursor jumped past them.
    function checkUpkeep(bytes calldata) external view override returns (bool, bytes memory) {
        uint256 start = lastCheckedRaffleId + 1;
        uint256 count;

        // Scan forward from cursor to raffleCount
        for (uint256 i = start; i <= raffleCount && count < CHECK_UPKEEP_BATCH;) {
            if (raffles[i].status == RaffleStatus.OPEN && block.timestamp >= raffles[i].expiry) {
                return (true, abi.encode(i));
            }
            unchecked {
                ++i;
                ++count;
            }
        }

        // Wrap: if cursor > 1, scan from 1 up to cursor with its own budget
        if (start > 1) {
            uint256 wrapCount;
            for (uint256 i = 1; i < start && wrapCount < CHECK_UPKEEP_BATCH;) {
                if (raffles[i].status == RaffleStatus.OPEN && block.timestamp >= raffles[i].expiry) {
                    return (true, abi.encode(i));
                }
                unchecked {
                    ++i;
                    ++wrapCount;
                }
            }
        }

        return (false, "");
    }

    function performUpkeep(bytes calldata performData) external override nonReentrant {
        uint256 raffleId = abi.decode(performData, (uint256));
        if (raffleId == 0 || raffleId > raffleCount) return;
        RaffleData storage raffle = raffles[raffleId];

        if (raffle.status != RaffleStatus.OPEN || block.timestamp < raffle.expiry) return;

        // Update pagination cursor
        if (raffleId > lastCheckedRaffleId) {
            lastCheckedRaffleId = raffleId;
        }

        uint256 total = totalTickets[raffleId];

        // Zero participants → return prize, mark completed
        if (total == 0) {
            raffle.underfilled = true;
            raffle.status = RaffleStatus.COMPLETED;
            _returnPrizeToHost(raffleId, raffle);
            emit RaffleExpired(raffleId);
            return;
        }

        // Underfilled → return prize to host now, VRF will award the payment pool
        if (total < raffle.maxCap && !raffle.underfilled) {
            raffle.underfilled = true;
            _returnPrizeToHost(raffleId, raffle);
        }

        // Request VRF
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: s_keyHash,
                subId: s_subId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: CALLBACK_GAS_LIMIT,
                numWords: NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );

        requestIdToRaffleId[requestId] = raffleId;
        raffleVrfRequestedAt[raffleId] = uint48(block.timestamp);
        raffle.status = RaffleStatus.PENDING_VRF;
        emit VRFRequested(raffleId, requestId);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Chainlink VRF v2.5 – fulfillment callback
    // ──────────────────────────────────────────────────────────────────────

    function fulfillRandomWords(uint256 _requestId, uint256[] calldata _randomWords) internal override nonReentrant {
        uint256 raffleId = requestIdToRaffleId[_requestId];
        delete requestIdToRaffleId[_requestId];
        delete raffleVrfRequestedAt[raffleId];

        RaffleData storage raffle = raffles[raffleId];
        if (raffle.status != RaffleStatus.PENDING_VRF) return;

        uint256 total = totalTickets[raffleId];
        if (total == 0) {
            raffle.status = RaffleStatus.COMPLETED;
            raffle.underfilled = true;
            _returnPrizeToHost(raffleId, raffle);
            emit RaffleExpired(raffleId);
            return;
        }

        uint256 winningTicket = (_randomWords[0] % total) + 1;
        address winner;

        // O(log N) binary search for winner selection
        TicketRange[] storage ranges = ticketRanges[raffleId];
        uint256 low = 0;
        uint256 high = ranges.length - 1;

        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (winningTicket <= ranges[mid].endTicket) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        winner = ranges[low].owner;

        raffle.status = RaffleStatus.COMPLETED;

        if (raffle.prizeType == PrizeType.ERC721 && !raffle.underfilled) {
            _distributeERC721(raffleId, raffle, winner);
        } else {
            _distribute(raffleId, raffle, winner);
        }

        emit WinnerPicked(raffleId, winner);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Participant Refunds (Pull-based, O(1))
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Claim a refund for a cancelled raffle.
    ///         Only available after emergencyFinalize sets status to CANCELLED.
    ///         O(1) complexity, immune to DoS via large purchase histories.
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

    function _returnPrizeToHost(uint256 _raffleId, RaffleData storage _raffle) internal {
        if (_raffle.prizeType == PrizeType.ERC721) {
            IERC721(_raffle.prizeAsset).transferFrom(address(this), _raffle.host, _raffle.prizeAmountOrTokenId);
        } else {
            IERC20(_raffle.prizeAsset).safeTransfer(_raffle.host, _raffle.prizeAmountOrTokenId);
        }
        emit UnderfilledPrizeReturned(_raffleId, _raffle.host, _raffle.prizeAmountOrTokenId);
    }

    function _computeFee(uint256 _amount) internal view returns (uint256) {
        return (_amount * platformFeeBps) / 10_000;
    }

    /// @dev Distribute prizes, payments, and fees (used for underfilled + ERC-20 full-fill).
    function _distribute(uint256 _raffleId, RaffleData storage _raffle, address _winner) internal {
        uint256 paymentPool = rafflePaymentPool[_raffleId];
        delete rafflePaymentPool[_raffleId];
        uint256 paymentFee = _computeFee(paymentPool);

        if (_raffle.underfilled) {
            IERC20(paymentToken).safeTransfer(_winner, paymentPool - paymentFee);
            if (paymentFee > 0) {
                IERC20(paymentToken).safeTransfer(treasury, paymentFee);
                emit PlatformFeeCollected(_raffleId, paymentFee);
            }
            emit UnderfilledPayout(_raffleId, _winner, paymentToken, paymentPool - paymentFee, paymentFee);
        } else {
            // Full-fill with ERC-20 prize
            uint256 prizeFee = _computeFee(_raffle.prizeAmountOrTokenId);
            IERC20(_raffle.prizeAsset).safeTransfer(_winner, _raffle.prizeAmountOrTokenId - prizeFee);
            IERC20(paymentToken).safeTransfer(_raffle.host, paymentPool - paymentFee);

            uint256 totalFees = prizeFee + paymentFee;
            if (prizeFee > 0) {
                IERC20(_raffle.prizeAsset).safeTransfer(treasury, prizeFee);
            }
            if (paymentFee > 0) {
                IERC20(paymentToken).safeTransfer(treasury, paymentFee);
            }
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
    }

    /// @dev Distribute ERC-721 prize via transferFrom (no onERC721Received callback).
    function _distributeERC721(uint256 _raffleId, RaffleData storage _raffle, address _winner) internal {
        uint256 paymentPool = rafflePaymentPool[_raffleId];
        delete rafflePaymentPool[_raffleId];
        uint256 paymentFee = _computeFee(paymentPool);

        IERC721(_raffle.prizeAsset).transferFrom(address(this), _winner, _raffle.prizeAmountOrTokenId);

        IERC20(paymentToken).safeTransfer(_raffle.host, paymentPool - paymentFee);
        if (paymentFee > 0) {
            IERC20(paymentToken).safeTransfer(treasury, paymentFee);
            emit PlatformFeeCollected(_raffleId, paymentFee);
        }
        emit NFTPrizeAwarded(
            _raffleId, _winner, _raffle.prizeAsset, _raffle.prizeAmountOrTokenId, paymentPool - paymentFee, paymentFee
        );
    }
}
