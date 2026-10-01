import { parseAbiItem } from 'viem';

/**
 * Trimmed LotteryCore ABI — only what the keeper reads, calls and decodes.
 * Errors are included so viem decodes custom reverts (NotResolver,
 * InsufficientFeeBalance, ...) into `errorName`/`args` instead of raw bytes.
 */
export const lotteryCoreAbi = [
  // ── Keeper helper views ──────────────────────────────────────────────────
  {
    inputs: [
      { internalType: 'uint256', name: '_cursor', type: 'uint256' },
      { internalType: 'uint256', name: '_limit', type: 'uint256' },
    ],
    name: 'pendingResolution',
    outputs: [
      { internalType: 'uint256[]', name: 'raffleIds', type: 'uint256[]' },
      { internalType: 'uint256', name: 'nextCursor', type: 'uint256' },
    ],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [
      { internalType: 'uint256', name: '_cursor', type: 'uint256' },
      { internalType: 'uint256', name: '_limit', type: 'uint256' },
    ],
    name: 'stalledRaffles',
    outputs: [
      { internalType: 'uint256[]', name: 'raffleIds', type: 'uint256[]' },
      { internalType: 'uint256', name: 'nextCursor', type: 'uint256' },
    ],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [{ internalType: 'uint256', name: '_raffleId', type: 'uint256' }],
    name: 'getRaffle',
    outputs: [
      {
        components: [
          { internalType: 'address', name: 'host', type: 'address' },
          { internalType: 'uint48', name: 'expiry', type: 'uint48' },
          { internalType: 'enum LotteryCore.RaffleStatus', name: 'status', type: 'uint8' },
          { internalType: 'bool', name: 'underfilled', type: 'bool' },
          { internalType: 'enum LotteryCore.PrizeType', name: 'prizeType', type: 'uint8' },
          { internalType: 'address', name: 'prizeAsset', type: 'address' },
          { internalType: 'uint96', name: 'ticketsSold', type: 'uint96' },
          { internalType: 'uint256', name: 'prizeAmountOrTokenId', type: 'uint256' },
          { internalType: 'uint256', name: 'ticketPrice', type: 'uint256' },
          { internalType: 'uint256', name: 'maxCap', type: 'uint256' },
        ],
        internalType: 'struct LotteryCore.RaffleData',
        name: '',
        type: 'tuple',
      },
    ],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [{ internalType: 'uint256', name: '_raffleId', type: 'uint256' }],
    name: 'getResolutionState',
    outputs: [
      {
        components: [
          { internalType: 'enum LotteryCore.RaffleStatus', name: 'status', type: 'uint8' },
          { internalType: 'uint8', name: 'attempts', type: 'uint8' },
          { internalType: 'address', name: 'activeProviderAddr', type: 'address' },
          { internalType: 'uint64', name: 'activeSequence', type: 'uint64' },
          { internalType: 'uint48', name: 'lastRequestedAt', type: 'uint48' },
          { internalType: 'bool', name: 'underfilled', type: 'bool' },
          { internalType: 'bool', name: 'prizeDisposedFlag', type: 'bool' },
        ],
        internalType: 'struct LotteryCore.ResolutionState',
        name: '',
        type: 'tuple',
      },
    ],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [],
    name: 'randomnessFee',
    outputs: [{ internalType: 'uint128', name: '', type: 'uint128' }],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [],
    name: 'raffleCount',
    outputs: [{ internalType: 'uint256', name: '', type: 'uint256' }],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [{ internalType: 'address', name: '', type: 'address' }],
    name: 'isResolver',
    outputs: [{ internalType: 'bool', name: '', type: 'bool' }],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [],
    name: 'activeProvider',
    outputs: [{ internalType: 'address', name: '', type: 'address' }],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [],
    name: 'fallbackProvider',
    outputs: [{ internalType: 'address', name: '', type: 'address' }],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [],
    name: 'MAX_RESOLVE_ATTEMPTS',
    outputs: [{ internalType: 'uint8', name: '', type: 'uint8' }],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [],
    name: 'STALL_TIMEOUT',
    outputs: [{ internalType: 'uint256', name: '', type: 'uint256' }],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [],
    name: 'HARD_DEADLINE',
    outputs: [{ internalType: 'uint256', name: '', type: 'uint256' }],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [],
    name: 'RESOLVE_GRACE',
    outputs: [{ internalType: 'uint256', name: '', type: 'uint256' }],
    stateMutability: 'view',
    type: 'function',
  },

  // ── Resolution / settlement writes ───────────────────────────────────────
  {
    inputs: [
      { internalType: 'uint256', name: '_raffleId', type: 'uint256' },
      { internalType: 'bytes32', name: '_salt', type: 'bytes32' },
    ],
    name: 'resolveRaffle',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
  {
    inputs: [
      { internalType: 'uint256', name: '_raffleId', type: 'uint256' },
      { internalType: 'bytes32', name: '_salt', type: 'bytes32' },
    ],
    name: 'retryResolve',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
  {
    inputs: [{ internalType: 'uint256', name: '_raffleId', type: 'uint256' }],
    name: 'cancelStalledRaffle',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
  {
    inputs: [{ internalType: 'uint256', name: '_raffleId', type: 'uint256' }],
    name: 'cancelExpiredRaffle',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
  {
    inputs: [{ internalType: 'uint256', name: '_raffleId', type: 'uint256' }],
    name: 'pokeFailedCallback',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
  {
    inputs: [{ internalType: 'uint256', name: '_raffleId', type: 'uint256' }],
    name: 'settle',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
  {
    inputs: [],
    name: 'fundRandomnessFees',
    outputs: [],
    stateMutability: 'payable',
    type: 'function',
  },

  // ── Events ───────────────────────────────────────────────────────────────
  {
    anonymous: false,
    inputs: [
      { indexed: true, internalType: 'uint256', name: 'raffleId', type: 'uint256' },
      { indexed: false, internalType: 'uint64', name: 'seq', type: 'uint64' },
      { indexed: false, internalType: 'bytes32', name: 'randomNumber', type: 'bytes32' },
    ],
    name: 'RandomnessFulfilled',
    type: 'event',
  },
  {
    anonymous: false,
    inputs: [
      { indexed: true, internalType: 'uint256', name: 'raffleId', type: 'uint256' },
      { indexed: true, internalType: 'address', name: 'provider', type: 'address' },
      { indexed: true, internalType: 'uint64', name: 'seq', type: 'uint64' },
      { indexed: false, internalType: 'uint8', name: 'attempt', type: 'uint8' },
    ],
    name: 'RandomnessRequested',
    type: 'event',
  },
  {
    anonymous: false,
    inputs: [
      { indexed: true, internalType: 'uint256', name: 'raffleId', type: 'uint256' },
      { indexed: true, internalType: 'address', name: 'provider', type: 'address' },
      { indexed: false, internalType: 'bytes', name: 'reason', type: 'bytes' },
    ],
    name: 'RandomnessRequestFailed',
    type: 'event',
  },
  {
    anonymous: false,
    inputs: [
      { indexed: true, internalType: 'uint256', name: 'raffleId', type: 'uint256' },
      { indexed: false, internalType: 'uint8', name: 'nextAttempt', type: 'uint8' },
    ],
    name: 'RaffleStalled',
    type: 'event',
  },
  {
    anonymous: false,
    inputs: [
      { indexed: true, internalType: 'uint256', name: 'raffleId', type: 'uint256' },
      { indexed: true, internalType: 'address', name: 'winner', type: 'address' },
    ],
    name: 'WinnerPicked',
    type: 'event',
  },
  {
    anonymous: false,
    inputs: [
      { indexed: true, internalType: 'uint256', name: 'raffleId', type: 'uint256' },
      { indexed: true, internalType: 'address', name: 'winner', type: 'address' },
      { indexed: false, internalType: 'address', name: 'paymentToken', type: 'address' },
      { indexed: false, internalType: 'uint256', name: 'winnerAmount', type: 'uint256' },
      { indexed: false, internalType: 'uint256', name: 'feeAmount', type: 'uint256' },
    ],
    name: 'UnderfilledPayout',
    type: 'event',
  },
  {
    anonymous: false,
    inputs: [
      { indexed: true, internalType: 'uint256', name: 'raffleId', type: 'uint256' },
      { indexed: true, internalType: 'address', name: 'winner', type: 'address' },
      { indexed: false, internalType: 'address', name: 'prizeAsset', type: 'address' },
      { indexed: false, internalType: 'uint256', name: 'winnerPrizeAmount', type: 'uint256' },
      { indexed: false, internalType: 'uint256', name: 'hostAmount', type: 'uint256' },
      { indexed: false, internalType: 'uint256', name: 'prizeFee', type: 'uint256' },
      { indexed: false, internalType: 'uint256', name: 'paymentFee', type: 'uint256' },
    ],
    name: 'TokenPrizeAwarded',
    type: 'event',
  },
  {
    anonymous: false,
    inputs: [
      { indexed: true, internalType: 'uint256', name: 'raffleId', type: 'uint256' },
      { indexed: true, internalType: 'address', name: 'winner', type: 'address' },
      { indexed: false, internalType: 'address', name: 'nftContract', type: 'address' },
      { indexed: false, internalType: 'uint256', name: 'tokenId', type: 'uint256' },
      { indexed: false, internalType: 'uint256', name: 'hostAmount', type: 'uint256' },
      { indexed: false, internalType: 'uint256', name: 'feeAmount', type: 'uint256' },
    ],
    name: 'NFTPrizeAwarded',
    type: 'event',
  },
  {
    anonymous: false,
    inputs: [
      { indexed: true, internalType: 'uint256', name: 'raffleId', type: 'uint256' },
      { indexed: false, internalType: 'uint256', name: 'amount', type: 'uint256' },
    ],
    name: 'PlatformFeeCollected',
    type: 'event',
  },
  {
    anonymous: false,
    inputs: [
      { indexed: true, internalType: 'address', name: 'token', type: 'address' },
      { indexed: true, internalType: 'address', name: 'to', type: 'address' },
      { indexed: false, internalType: 'uint256', name: 'amount', type: 'uint256' },
    ],
    name: 'PayoutEscrowed',
    type: 'event',
  },
  {
    anonymous: false,
    inputs: [
      { indexed: true, internalType: 'address', name: 'nft', type: 'address' },
      { indexed: true, internalType: 'uint256', name: 'tokenId', type: 'uint256' },
      { indexed: true, internalType: 'address', name: 'claimant', type: 'address' },
    ],
    name: 'NftEscrowed',
    type: 'event',
  },
  {
    anonymous: false,
    inputs: [
      { indexed: true, internalType: 'uint256', name: 'raffleId', type: 'uint256' },
      { indexed: true, internalType: 'address', name: 'host', type: 'address' },
      { indexed: false, internalType: 'uint256', name: 'prizeAmountOrTokenId', type: 'uint256' },
    ],
    name: 'UnderfilledPrizeReturned',
    type: 'event',
  },
  {
    anonymous: false,
    inputs: [{ indexed: true, internalType: 'uint256', name: 'raffleId', type: 'uint256' }],
    name: 'RaffleCancelledStalled',
    type: 'event',
  },
  {
    anonymous: false,
    inputs: [{ indexed: true, internalType: 'uint256', name: 'raffleId', type: 'uint256' }],
    name: 'RaffleExpiredCancelled',
    type: 'event',
  },
  {
    anonymous: false,
    inputs: [{ indexed: false, internalType: 'address', name: 'from', type: 'address' }, { indexed: false, internalType: 'uint256', name: 'amount', type: 'uint256' }],
    name: 'RandomnessFeeFunded',
    type: 'event',
  },

  // ── Errors (for revert decoding) ─────────────────────────────────────────
  { inputs: [{ internalType: 'uint256', name: 'raffleId', type: 'uint256' }], name: 'RaffleNotOpen', type: 'error' },
  { inputs: [{ internalType: 'uint256', name: 'raffleId', type: 'uint256' }], name: 'RaffleNotExpired', type: 'error' },
  { inputs: [{ internalType: 'uint256', name: 'raffleId', type: 'uint256' }], name: 'RaffleNoTickets', type: 'error' },
  { inputs: [{ internalType: 'address', name: 'caller', type: 'address' }], name: 'NotResolver', type: 'error' },
  { inputs: [], name: 'SaltZero', type: 'error' },
  { inputs: [], name: 'SaltAlreadyUsed', type: 'error' },
  { inputs: [{ internalType: 'uint256', name: 'raffleId', type: 'uint256' }], name: 'RaffleNotPendingVrf', type: 'error' },
  { inputs: [], name: 'StallTimeoutNotReached', type: 'error' },
  { inputs: [], name: 'MaxAttemptsReached', type: 'error' },
  { inputs: [], name: 'FailedCallbackPending', type: 'error' },
  { inputs: [{ internalType: 'uint256', name: 'raffleId', type: 'uint256' }], name: 'RaffleNotResolved', type: 'error' },
  {
    inputs: [
      { internalType: 'uint256', name: 'required', type: 'uint256' },
      { internalType: 'uint256', name: 'available', type: 'uint256' },
    ],
    name: 'InsufficientFeeBalance',
    type: 'error',
  },
  { inputs: [], name: 'GraceNotElapsed', type: 'error' },
  { inputs: [], name: 'StalledConditionNotMet', type: 'error' },
  { inputs: [{ internalType: 'uint256', name: 'raffleId', type: 'uint256' }], name: 'RaffleHasTickets', type: 'error' },
  { inputs: [], name: 'InvalidParams', type: 'error' },
  { inputs: [], name: 'EnforcedPause', type: 'error' },
  { inputs: [], name: 'ExpectedPause', type: 'error' },
  { inputs: [{ internalType: 'address', name: 'caller', type: 'address' }], name: 'CallerNotCoordinator', type: 'error' },
  { inputs: [{ internalType: 'uint256', name: 'raffleId', type: 'uint256' }], name: 'RaffleNotCancelled', type: 'error' },
] as const;

/** Typed log filter for cron #2's fulfillment queue. */
export const randomnessFulfilledEvent = parseAbiItem(
  'event RandomnessFulfilled(uint256 indexed raffleId, uint64 seq, bytes32 randomNumber)',
);
