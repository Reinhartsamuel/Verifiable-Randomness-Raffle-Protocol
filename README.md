# Winr Contract

A gas-optimized, decentralized raffle system built with Foundry, OpenZeppelin, and
[Quiver](https://quiver.dev) verifiable randomness, deployed on **Robinhood Chain**.

> **Core contract: [`src/WinrCore.sol`](src/WinrCore.sol)** — this README documents `WinrCore`.
> The older `RaffledCore.sol` / `RaffleManager*.sol` contracts (Chainlink VRF + Automation on
> Base) are legacy and no longer the production flow.

## Overview

**Winr** lets anyone create and manage trustless raffles on Robinhood Chain. Each raffle escrows
an **ERC-20 token** or an **ERC-721 NFT** as the prize and sells tickets for **USDC**. Winners are
drawn with verifiable on-chain randomness from Quiver, and resolution is driven by a self-operated
resolver keeper rather than Chainlink Automation.

### Key Features

- 🎲 **Quiver VRF (push/callback flow)**: verifiable randomness for winner selection.
- 🏆 **Dual prize types**: ERC-20 tokens *or* ERC-721 NFTs escrowed as the prize.
- 💵 **USDC ticket payments** via a single immutable payment token.
- 🔐 **Resolver-gated resolution**: a fresh, secret-until-landed salt is folded into every request,
  so a malicious/colluding randomness provider can at worst stall — never pick the winner.
- ⚖️ **Underfilled handling**: if `maxCap` isn't reached, the prize returns to the host and the
  collected payment pool is raffled to a random entrant.
- ♻️ **Cancel + pull refunds**: stalled or expired raffles can be cancelled; entrants pull refunds
  with O(1) accounting.
- 🛟 **Push-with-escrow-fallback payouts**: a failed transfer (blacklisted winner, reverting token)
  is credited to `claimable` / `nftClaimant` instead of bricking settlement.
- ⏱️ **Timelocked admin**: platform-fee changes require a 2-day timelock.
- 🎟️ **Signed free entries**: EIP-712 `FreeEntry(raffleId,user)` signatures allow off-chain
  sponsored entries.
- ⏸️ **Pausable** creation/entry (resolution, settlement, and refunds stay live).

## Deployment (Robinhood Chain — Mainnet)

| Item | Value |
|------|-------|
| Network | Robinhood Chain **mainnet** |
| Chain ID | `4663` |
| RPC | `https://rpc.mainnet.chain.robinhood.com` |
| Explorer | `https://robinhoodchain.blockscout.com` |
| **WinrCore** | [`0x7Df6b990102cAA91EEfC5f9BFDc6dE90C6e7f947`](https://robinhoodchain.blockscout.com/address/0x7Df6b990102cAA91EEfC5f9BFDc6dE90C6e7f947) |
| **Quiver Coordinator** | `0x8cF4f562301fA966F153eE1e3D46D975DF21C9a3` |
| **Quiver Provider (active)** | `0xeB8E79d3495638Dde48336D01A1f1229822bB016` |
| Quiver Provider (fallback) | `0x062Fa60c76f4755836eE45641d1D45fB6f5E88C1` |
| Payment token (USDC) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| Treasury | `0x8f177216fB37FD3CCE07E70dA06b6370CEfB28C2` |
| Free-entry signer | `0x14dC79964da2C08b23698B3D3cc7Ca32193d9955` |
| Owner | `0xAcd635171bDcAE7e654e3C4412AfCA04F199D178` |
| Deploy tx | `0x8cab354dee2f8df8b73b7da500b948b6d4e6769c1c60cb89fb6602243d29c158` |

**Website:** [https://winr.fun](https://winr.fun)

> The constructor takes `(coordinator, provider, fallbackProvider, paymentToken, treasury,
> trustedSigner, initialOwner)` and is set from the deployment broadcast. Always re-read live
> values (`activeProvider()`, `fallbackProvider()`, `getCoordinator()`, `randomnessFee()`) before
> relying on them, as provider changes are timelocked but applyable.

### Robinhood Chain — Testnet

| Item | Value |
|------|-------|
| Chain ID | `46630` |
| RPC | `https://rpc.testnet.chain.robinhood.com` |
| Quiver Coordinator | `0x1da30d6465f657F11B4D7F6Db0B16aD79152fb40` |
| Quiver Provider | `0xc84CC91131b63d9BECFDe7b2DB3D0C653B690541` |

## Architecture

### Contract: `WinrCore.sol`

`WinrCore` inherits from:

- [`QuiverConsumer`](lib/quiver-kit/src/QuiverConsumer.sol) — Quiver push-flow randomness
  (`quiverCallback` → `_fulfillRandomness`).
- [`FreeEntryVerifier2`](src/FreeEntryVerifier2.sol) — EIP-712 signed free-entry verification.
- `ReentrancyGuard` — reentrancy protection (OpenZeppelin).
- `Ownable2Step` — two-step ownership transfer (OpenZeppelin).
- `Pausable` — emergency pause of creation/entry.
- `IERC721Receiver` — accepts escrowed NFT prizes.

### Storage design

Each raffle is packed into a 5-slot `RaffleData` struct so `getRaffle` ABI decoding stays stable:

```solidity
struct RaffleData {
    address host;                 // 20 B  ┐
    uint48  expiry;               //  6 B  │ Slot 0
    RaffleStatus status;          //  1 B  │
    bool    underfilled;          //  1 B  │
    PrizeType prizeType;          //  1 B  ┘
    address prizeAsset;           // 20 B  ┐
    uint96  ticketsSold;          // 12 B  ┘ Slot 1
    uint256 prizeAmountOrTokenId; // 32 B     Slot 2
    uint256 ticketPrice;          // 32 B     Slot 3
    uint256 maxCap;               // 32 B     Slot 4
}
```

All resolution state lives in separate mappings (`raffleRandomness`, `resolveAttempts`,
`activeProviderOf`, `activeSeq`, `lastRequestAt`, `prizeDisposed`, `usedSalt`, `seqToRaffleId`).

### Ticket accounting

```solidity
struct TicketRange { address owner; uint96 endTicket; } // packed into one slot
mapping(uint256 => TicketRange[]) public ticketRanges;
mapping(uint256 => uint96)        public totalTickets;
mapping(uint256 => mapping(address => uint256)) public refundableAmount;
```

Consecutive purchases by the same buyer are aggregated into one range, so winner selection is
**O(log N)** binary search over ranges, and refunds are **O(1)** per user.

### Status lifecycle

```
OPEN ──resolveRaffle()──► PENDING_VRF ──fulfill──► RESOLVED ──settle()──► COMPLETED
  │                                                                         
  ├── completeEmptyRaffle()   (expired, zero entrants → prize back to host)  
  ├── cancelExpiredRaffle()   (expired + RESOLVE_GRACE, no request in flight)
  └── cancelStalledRaffle()   (PENDING_VRF stalled → CANCELLED, pull refunds)
CANCELLED ──claimRefund()──► entrant refunded
```

`RESOLVED` is appended at enum index 4, so indices 0–3 keep their original meaning for
existing frontends/indexers.

## Core Functions

### Create a raffle

```solidity
function createRaffleERC20(
    address _asset, uint256 _amount, uint256 _ticketPrice, uint256 _maxCap, uint256 _duration
) external returns (uint256 raffleId);

function createRaffleERC721(
    address _nft, uint256 _tokenId, uint256 _ticketPrice, uint256 _maxCap, uint256 _duration
) external returns (uint256 raffleId);
```

- Host must approve the prize token/NFT before calling.
- `_duration` must be ≥ `minDuration` (floor `2 hours`).
- Prize is escrowed via `safeTransferFrom`; ERC-20 receipt is balance-checked
  (`PrizeAmountMismatch`).

### Enter a raffle

```solidity
function enterRaffle(uint256 _raffleId, uint256 _ticketCount) external; // pays USDC
function enterFreeRaffle(uint256 _raffleId, bytes _signature) external;  // EIP-712 signed
```

- Raffle must be `OPEN` and not expired; the host cannot enter its own raffle.
- USDC is pulled with `safeTransferFrom`; free entries must carry a valid
  `FreeEntry(raffleId,user)` signature and cannot be double-claimed.

### Resolution (resolver keeper only)

```solidity
function resolveRaffle(uint256 _raffleId, bytes32 _salt) external;   // OPEN → PENDING_VRF
function retryResolve(uint256 _raffleId, bytes32 _salt) external;    // stalled PENDING_VRF
```

- `_salt` is a fresh CSPRNG value that stays secret until the tx lands; it is folded into
  `userRandom = keccak256(salt, raffleId, attempt, this, chainid)` so the provider cannot
  precompute or grind the outcome. Salt replay is blocked (`usedSalt` / `SaltAlreadyUsed`).
- Retries use the fallback provider when configured, bounded by `MAX_RESOLVE_ATTEMPTS (3)`.
- `pokeFailedCallback(id)` is permissionless and redelivers a buffered callback.

### Fulfillment (Quiver callback)

```solidity
function _fulfillRandomness(uint64 seq, address provider, bytes32 rnd) internal override;
```

Called only via `quiverCallback` from the coordinator. It is intentionally lean — no external
calls, no reverts, O(1): it stores the randomness and flips status to `RESOLVED`. All economic
transfers happen later in the permissionless `settle()`.

### Settlement (permissionless)

```solidity
function settle(uint256 _raffleId) external; // RESOLVED → COMPLETED, pays out once
```

- `winningTicket = (randomness % totalTickets) + 1`, resolved to a winner via binary search.
- **Full fill, ERC-20 prize**: winner receives the prize (minus `platformFeeBps` on the prize),
  host receives the USDC pool (minus fee), treasury receives fees.
- **Full fill, ERC-721 prize**: winner receives the NFT, host receives the USDC pool minus fee.
- **Underfilled**: prize returns to the host and the USDC pool (minus fee) is raffled to a random
  entrant.
- `completeEmptyRaffle(id)` handles an expired raffle with zero entrants (prize back to host).
- Payouts are push-with-escrow-fallback: on a failed transfer, funds/`tokenId` are credited to
  `claimable` / `nftClaimant` (`PayoutEscrowed` / `NftEscrowed`) rather than reverting.

### Cancellation & refunds

```solidity
function cancelExpiredRaffle(uint256 _raffleId) external; // expiry + RESOLVE_GRACE (72h)
function cancelStalledRaffle(uint256 _raffleId) external; // attempts exhausted or HARD_DEADLINE
function claimRefund(uint256 _raffleId) external;         // CANCELLED → pull refund
function claim(address _token) external;                  // claim escrowed ERC-20 payout
function claimNft(address _nft, uint256 _tokenId) external; // claim escrowed NFT payout
```

- Cancellation never fabricates a winner; entrants pull their exact USDC contributions.
- Prize disposal is idempotent (`prizeDisposed`) and happens exactly once.

### Admin

```solidity
function setTrustedSigner(address _newSigner) external onlyOwner;
function setMinDuration(uint256 _newMinDuration) external onlyOwner; // floor 2 hours
function proposeFeeChange(uint256 _newFeeBps) external onlyOwner;    // ≤ 1000 bps, 2-day timelock
function applyFeeChange() external onlyOwner;
function proposeProviderChange(address _newActive, address _newFallback) external onlyOwner;
function applyProviderChange() external onlyOwner;
function setResolver(address _resolver, bool _allowed) external onlyOwner;
function fundRandomnessFees() external payable;  // fund the Quiver request balance
function withdrawNative(address _to, uint256 _amount) external onlyOwner;
function pause() external onlyOwner;
function unpause() external onlyOwner;
```

### Keeper / integration views

```solidity
function getRaffle(uint256 _raffleId) external view returns (RaffleData memory);
function getTotalTickets(uint256 _raffleId) external view returns (uint256);
function getTicketRange(uint256 _raffleId, uint256 _index) external view returns (address, uint256);
function getResolutionState(uint256 _raffleId) external view returns (ResolutionState memory);
function pendingResolution(uint256 _cursor, uint256 _limit) external view returns (uint256[] memory, uint256);
function stalledRaffles(uint256 _cursor, uint256 _limit) external view returns (uint256[] memory, uint256);
function randomnessFee() external view returns (uint128);
```

`pendingResolution` / `stalledRaffles` are cursor-paged helpers used by the off-chain keeper to
find expired or stalled raffles without scanning unbounded state.

## Events

```solidity
event RaffleCreated(uint256 indexed raffleId, address indexed host, address prizeAsset, PrizeType prizeType, uint256 prizeAmountOrTokenId, uint48 expiry, string prizeSymbol, uint256 decimals, uint256 ticketPrice, uint256 maxCap);
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
event UnderfilledPayout(uint256 indexed raffleId, address indexed winner, address paymentToken, uint256 winnerAmount, uint256 feeAmount);
event TokenPrizeAwarded(uint256 indexed raffleId, address indexed winner, address prizeAsset, uint256 winnerPrizeAmount, uint256 hostAmount, uint256 prizeFee, uint256 paymentFee);
event NFTPrizeAwarded(uint256 indexed raffleId, address indexed winner, address nftContract, uint256 tokenId, uint256 hostAmount, uint256 feeAmount);
event PlatformFeeCollected(uint256 indexed raffleId, uint256 amount);
event FeeChangeProposed(uint256 newFeeBps, uint256 effectiveAt);
event FeeChangeApplied(uint256 oldFeeBps, uint256 newFeeBps);
event ProviderChangeProposed(address newActiveProvider, address newFallbackProvider, uint256 effectiveAt);
event ProviderChangeApplied(address oldActiveProvider, address oldFallbackProvider, address newActiveProvider, address newFallbackProvider);
event ResolverUpdated(address indexed resolver, bool allowed);
event RaffleExpiredCancelled(uint256 indexed raffleId);
event RaffleCancelledStalled(uint256 indexed raffleId);
event RefundClaimed(uint256 indexed raffleId, address indexed user, uint256 amount);
event PayoutEscrowed(address indexed token, address indexed to, uint256 amount);
event PayoutClaimed(address indexed token, address indexed to, uint256 amount);
event NftEscrowed(address indexed nft, uint256 indexed tokenId, address indexed claimant);
event NftClaimed(address indexed nft, uint256 indexed tokenId, address indexed claimant);
event RandomnessFeeFunded(address indexed from, uint256 amount);
event NativeWithdrawn(address indexed to, uint256 amount);
event FreeEntryClaimed(uint256 raffleId, address user, address signer);
event TrustedSignerUpdated(address oldSigner, address newSigner);
```

## Security Model

- **Provider cannot bias the draw.** Resolution is resolver-gated with a fresh secret salt; the
  provider is reduced to *stalling only* — it can force redraws (bounded by
  `MAX_RESOLVE_ATTEMPTS`) or a cancel+refund, but never pick the winner.
- **No permanent stranding.** The Quiver request is wrapped in `try/catch`, so a paused/exhausted/
  insufficient-fee provider cannot trap escrowed funds; cancel paths return the prize and enable
  refunds.
- **Lean callback.** `_fulfillRandomness` never reverts and does no external calls. A reverting
  callback would route randomness into the coordinator retry buffer instead. All transfers happen
  in the separate permissionless `settle()`.
- **Idempotent prize disposal.** `prizeDisposed` guarantees the prize moves exactly once across
  settle/cancel paths; retried requests cannot double-transfer.
- **Escrow fallback.** Failed payouts are credited (`claimable` / `nftClaimant`) instead of
  bricking settlement. `_tryTransfer` uses bounded gas and truncated returndata, safe against
  returndata-bomb tokens.
- **Replay/reentrancy.** `ReentrancyGuard` on all state-changing external functions, CEI ordering,
  per-raffle salt replay guard, and a `(provider, sequenceNumber)` request index that prevents
  cross-provider sequence collisions.
- **Access control.** Resolver allowlist (`isResolver`), `Ownable2Step`, 2-day fee timelock,
  timelocked provider rotation, and pausing that never blocks resolution/settlement/refunds.

## Development Setup

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Git

### Installation

```bash
git clone <repository-url>
cd raffled-contract
forge install
forge build
```

### Environment Configuration

The `DeployWinrCore.s.sol` script reads these variables (create a `.env`, never commit it):

```env
DEPLOYER_PRIVATE_KEY=0x...
QUIVER_COORDINATOR=0x8cF4f562301fA966F153eE1e3D46D975DF21C9a3
QUIVER_PROVIDER=0xeB8E79d3495638Dde48336D01A1f1229822bB016
QUIVER_FALLBACK_PROVIDER=0x062Fa60c76f4755836eE45641d1D45fB6f5E88C1
PAYMENT_TOKEN=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
TREASURY=0x8f177216fB37FD3CCE07E70dA06b6370CEfB28C2
RAFFLE_SIGNER=0x14dC79964da2C08b23698B3D3cc7Ca32193d9955
RAFFLE_OWNER=0xAcd635171bDcAE7e654e3C4412AfCA04F199D178
```

### Running Tests

```bash
forge test
forge test --gas-report
forge test -vvv
forge test --match-path test/WinrCore.t.sol
forge coverage
```

The WinrCore suite includes `WinrCore.t.sol`, `WinrCoreFork.t.sol`, `WinrCoreFuzz.t.sol`,
`WinrCoreRandomness.t.sol`, and `WinrCoreSettlement.t.sol`.

### Deployment

```bash
forge script script/DeployWinrCore.s.sol \
  --rpc-url robinhood_mainnet \
  --broadcast -vvvv
```

After deploy:

1. `setResolver(keeper, true)`
2. `proposeFeeChange(...)` then `applyFeeChange()` after the timelock
3. `fundRandomnessFees()` with native ETH if `randomnessFee()` is non-zero
4. Verify on Blockscout (see below)

```bash
forge verify-contract --watch \
  --rpc-url robinhood_mainnet \
  0x7Df6b990102cAA91EEfC5f9BFDc6dE90C6e7f947 \
  src/WinrCore.sol:WinrCore \
  --verifier blockscout \
  --verifier-url "https://robinhoodchain.blockscout.com/api/"
```

## Keeper

Resolution and settlement are driven off-chain by [`winr-keeper`](winr-keeper/README.md), a
standalone Node service with two cron jobs:

| Job | Interval | Purpose |
|-----|----------|---------|
| resolve | 2 min | `pendingResolution()` → `resolveRaffle(id, salt)`; sweeps `stalledRaffles()` → `retryResolve` / `cancelStalledRaffle`; auto-tops-up the fee balance. |
| settle | 45 s | Scans `RandomnessFulfilled` logs and calls permissionless `settle(id)` for every `RESOLVED` raffle. |

See [winr-keeper/README.md](winr-keeper/README.md) for the operator checklist, configuration, and
error handling.

## Project Structure

```
raffled-contract/
├── src/
│   ├── WinrCore.sol             # Production contract
│   ├── FreeEntryVerifier2.sol   # EIP-712 free-entry verification
│   └── interfaces/              # Quiver / legacy interfaces
├── script/
│   └── DeployWinrCore.s.sol     # Deployment script
├── test/
│   ├── WinrCore*.t.sol          # WinrCore test suite
│   └── mocks/                   # Test tokens, coordinators, NFTs
├── winr-keeper/                 # Off-chain resolve + settle keeper
├── broadcast/                   # Deployment records (chain-id keyed)
├── lib/                         # Foundry dependencies (OZ v5, forge-std, quiver-kit)
└── foundry.toml                 # Foundry + RPC config
```

Legacy, non-production sources retained for reference: `src/RaffledCore.sol`,
`src/RaffleManager{3,4,5,6}.sol`, and their tests/scripts (Chainlink on Base).

## Integration Guide

- **Event indexing**: index `RaffleCreated`, `TicketPurchased`, `RandomnessFulfilled`,
  `WinnerPicked`, and the payout/refund events.
- **Resolution**: the keeper handles it; you can offer a "Resolve now" that calls
  `pokeFailedCallback` / `cancelStalledRaffle` where permissionless.
- **Settlement**: call `settle(id)` on any `RESOLVED` raffle (permissionless).
- **Escrows**: surface `claim` / `claimNft` to recipients of `PayoutEscrowed` / `NftEscrowed`.
- **Refunds**: after `CANCELLED`, surface `claimRefund(id)` to entrants.

## Useful Commands

```bash
forge build
forge test
forge fmt
forge snapshot
anvil

# Inspect a raffle
cast call 0x7Df6b990102cAA91EEfC5f9BFDc6dE90C6e7f947 "getRaffle(uint256)" <raffleId> --rpc-url robinhood_mainnet
cast call 0x7Df6b990102cAA91EEfC5f9BFDc6dE90C6e7f947 "pendingResolution(uint256,uint256)" 0 50 --rpc-url robinhood_mainnet

# Contract ABI
forge inspect WinrCore abi > WinrCore.json
```

## License

MIT License - see [LICENSE](LICENSE) file for details

## Resources

- [Foundry Book](https://book.getfoundry.sh/)
- [Quiver integration skill](lib/quiver-kit/plugins/quiver/skills/quiver-integration/SKILL.md)
- [Robinhood Chain Explorer](https://robinhoodchain.blockscout.com)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)
- [Winr](https://winr.fun)

---

**Built with ❤️ using [Foundry](https://getfoundry.sh/)**