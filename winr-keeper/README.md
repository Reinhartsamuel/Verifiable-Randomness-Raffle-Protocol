# winr-keeper

Keeper service for **`WinrCore`** (Quiver VRF push/callback flow, Robinhood Chain).
It is the off-chain half of the new flow: nothing resolves by itself on-chain, so this
service runs two cron jobs:

| Cron | Interval (default) | What it does |
| --- | --- | --- |
| **#1 resolve** | 2 min | Pages `pendingResolution()` and calls `resolveRaffle(id, salt)` (resolver-gated). Also sweeps `stalledRaffles()` → `retryResolve(id, freshSalt)` or `cancelStalledRaffle(id)`. Auto-tops-up the contract's native randomness fee balance. |
| **#2 settle** | 45 s | Scans `RandomnessFulfilled` logs into a local queue and calls permissionless `settle(id)` for every raffle in `RESOLVED`. Handles escrowed payouts without retrying. |

The legacy `RaffledCore` backend/indexer is untouched — this is a standalone, self-contained
process with `viem` as its only runtime dependency.

```
                 cron #1 (resolver key)                    cron #2 (any wallet)
  ┌──────────┐   pendingResolution()     ┌──────────────┐   eth_getLogs      ┌───────────────┐
  │ raffles  │ ────────────────────────► │ WinrCore│ ────────────────►  │ local queue   │
  │ OPEN +   │   resolveRaffle(id,salt)  │  PENDING_VRF │  RandomnessFulfilled│ (state.json) │
  │ expired  │ ────────────────────────► │  ───────►    │                    │ settle(id)    │
  └──────────┘   (Quiver push callback)  │  RESOLVED    │ ◄────────────────── │ COMPLETED     │
                                         └──────────────┘   (permissionless)  └───────────────┘
```

---

## 1. Operator checklist — do these ON-CHAIN first

The keeper cannot do any of this for you. Run these before first start (replace
`$RPC`, `$CONTRACT`, `$KEEPER`, `$OWNER_KEY`).

```bash
export RPC=https://rpc.testnet.chain.robinhood.com   # mainnet: https://rpc.mainnet.chain.robinhood.com
export CONTRACT=0x95d256cdD7d0B8579538E98DFFc343e725a717Ec
export KEEPER=$(cast wallet address --private-key "$RAFFLE_RESOLVER_PRIVATE_KEY")  # keeper EOA
```

### 1.1 Allowlist the resolver key — **required**

`resolveRaffle` / `retryResolve` are `onlyResolver` and revert `NotResolver(caller)` otherwise.

```bash
cast send $CONTRACT "setResolver(address,bool)" $KEEPER true \
  --rpc-url $RPC --private-key $OWNER_KEY

# verify:
cast call $CONTRACT "isResolver(address)(bool)" $KEEPER --rpc-url $RPC   # true
```

### 1.2 Fund the contract's native balance — **required**

Every `resolveRaffle` spends `randomnessFee()` wei from the **contract's** balance;
if it is short, the tx reverts `InsufficientFeeBalance(required, available)`.

```bash
cast call $CONTRACT "randomnessFee()(uint128)" --rpc-url $RPC

# top up (any funder; the contract also accepts plain transfers via receive()):
cast send $CONTRACT "fundRandomnessFees()" --value 0.05ether \
  --rpc-url $RPC --private-key $ANY_FUNDED_KEY
```

Set `RAFFLE_FEE_FUND_THRESHOLD` in `.env.local` to have the keeper top it up
automatically (top-up target defaults to `randomnessFee() × RAFFLE_RESOLVE_BATCH`).

### 1.3 Fund the keeper wallet with native gas

`RAFFLE_RESOLVER_PRIVATE_KEY` signs one tx per raffle plus top-ups, so that EOA needs
native ETH (mainnet) / testnet gas token. Optionally set `RAFFLE_MIN_WALLET_BALANCE`
so the keeper pauses and alerts instead of spamming failing transactions.

### 1.4 Optional: rotate active/fallback providers

```bash
cast send $CONTRACT "proposeProviderChange(address,address)" $NEW_ACTIVE $NEW_FALLBACK \
  --rpc-url $RPC --private-key $OWNER_KEY
# wait PROVIDER_TIMELOCK (2 days)
cast send $CONTRACT "applyProviderChange()" --rpc-url $RPC --private-key $OWNER_KEY
```

The fallback (or the active provider when no fallback is set) is used by
`retryResolve` after `STALL_TIMEOUT` (6 h), up to `MAX_RESOLVE_ATTEMPTS` (3).

### 1.5 First start

```bash
cp .env.example .env.local     # fill in RPC, contract, resolver key
npm install
RAFFLE_DRY_RUN=true npm run once    # read-only rehearsal: simulates, sends nothing
npm start                            # run the two cron jobs
```

`RAFFLE_DRY_RUN=true` still reads real chain state and simulates every write, so it is a
safe way to verify the resolver allowlist and fee balance before arming it. `npm run once`
runs both jobs a single time and exits (for external cron/systemd timers).

---

## 2. Configuration

All config is env-driven; see `.env.example` for the full annotated list.

| Variable | Required | Default | Purpose |
| --- | --- | --- | --- |
| `RAFFLE_RPC_URL` | yes | — | Robinhood Chain RPC (mainnet 4663 / testnet 46630). |
| `RAFFLE_CONTRACT_ADDRESS` | yes | — | The new `WinrCore` address. |
| `RAFFLE_RESOLVER_PRIVATE_KEY` | for cron #1 | — | Resolver key, allowlisted via `setResolver`. Never logged. |
| `RAFFLE_SETTLER_PRIVATE_KEY` | no | resolver key | Signer for permissionless `settle()`. |
| `RAFFLE_CHAIN_ID` | no | auto-detect | Enforce chain id; mismatches abort startup. |
| `RAFFLE_RESOLVE_BATCH` | no | `50` | `pendingResolution` / `stalledRaffles` page size. |
| `RAFFLE_RESOLVE_INTERVAL_MS` | no | `300000` | Cron #1 cadence. |
| `RAFFLE_RESOLVE_RETRY_COOLDOWN_MS` | no | `300000` | Skip a raffle for this long after a failed resolve (stops per-cycle retry loops). |
| `RAFFLE_SETTLE_INTERVAL_MS` | no | `180000` | Cron #2 cadence. |
| `RAFFLE_MAX_SCAN_PASSES` | no | `200` | Runaway guard for cursor loops. |
| `RAFFLE_CANCEL_EXPIRED_AFTER_GRACE` | no | `false` | After `expiry + RESOLVE_GRACE` (72 h), cancel OPEN raffles whose on-chain request keeps failing (`RandomnessRequestFailed`) so entrants can `claimRefund`. |
| `RAFFLE_LOG_LOOKBACK_BLOCKS` | no | `10000` | First-run lookback for `RandomnessFulfilled`. |
| `RAFFLE_START_BLOCK` | no | — | Absolute first block to scan (deploy block). |
| `RAFFLE_LOG_RPC_URL` | no | `RAFFLE_RPC_URL` | Separate RPC for the `eth_getLogs` scan only. Point it at a wide-range endpoint so a metered provider with a narrow range cap is not drained by the scan. |
| `RAFFLE_LOG_CHUNK_SIZE` | no | `5000` | `eth_getLogs` chunking. Auto-shrinks to the provider's cap and is remembered per RPC URL (changing `RAFFLE_LOG_RPC_URL` re-probes); set explicitly to reset the learned size. |
| `RAFFLE_LOG_MAX_REQUESTS_PER_CYCLE` | no | `50` | Cap on `eth_getLogs` calls per settle cycle; the cursor resumes next cycle. When exhausted, the scan backs off (60 s doubling to 15 min). |
| `RAFFLE_SETTLE_MAX_ATTEMPTS` | no | `5` | Drop + alert after this many failed settles. |
| `RAFFLE_SETTLE_SWEEP_ENABLED` | no | `true` | On-chain, `eth_getLogs`-independent discovery of `RESOLVED` raffles (walk `raffleCount` + status + rotating watchlist). |
| `RAFFLE_SETTLE_SWEEP_BATCH` | no | `200` | Max raffle ids read per sweep pass (forward pass + watchlist slice). |
| `RAFFLE_FEE_FUND_THRESHOLD` | no | disabled | Auto top-up the contract balance below this (wei). |
| `RAFFLE_FEE_FUND_TARGET` | no | `fee × batch` | Top-up target (wei). |
| `RAFFLE_MIN_WALLET_BALANCE` | no | `0` | Pause + alert below this keeper balance (wei). |
| `RAFFLE_CONFIRMATIONS` / `RAFFLE_TX_RETRIES` / `RAFFLE_TX_RETRY_BASE_MS` / `RAFFLE_TX_TIMEOUT_MS` | no | `1` / `3` / `2500` / `90000` | Tx handling. |
| `RAFFLE_MAX_FEE_GWEI` / `RAFFLE_MAX_PRIORITY_FEE_GWEI` | no | RPC estimate | EIP-1559 overrides. |
| `RAFFLE_JOBS` | no | `resolve,settle` | Run one job only. |
| `RAFFLE_DRY_RUN` | no | `false` | Simulate every write, send nothing. |
| `RAFFLE_RUN_ONCE` / `--once` | no | `false` | Run each enabled job once, exit. |
| `RAFFLE_STATE_FILE` | no | `./data/keeper-state.json` | Persistent queue/scan/salts. |
| `RAFFLE_LOG_LEVEL` / `RAFFLE_LOG_PRETTY` | no | `info` / TTY | Structured JSON logs (TS, level, job, fields). |
| `RAFFLE_ALERT_WEBHOOK_URL` | no | — | Discord/Slack-style JSON webhook for loud alerts. |

---

## 3. How it works

### Cron #1 — resolution (`src/jobs/resolve.ts`)

1. **Pending sweep** — `scanPages` calls `pendingResolution(cursor, batch)`, feeds each
   id to `resolveRaffle(id, salt)`, and follows `nextCursor` until `0` (wrapped past
   `raffleCount`). A non-advancing cursor or `RAFFLE_MAX_SCAN_PASSES` aborts the sweep
   instead of looping; the next run restarts at cursor `0`.
2. **Salt** — `src/salt.ts` generates 32 CSPRNG bytes (`randomBytes`) → `0x…` (66 chars),
   rejects zero and any value already used for that raffle, and remembers it in the
   state file. A fresh salt is generated for **every** request, retry and recovery
   attempt, and it is never logged or exposed. The contract enforces its own replay
   guard (`SaltAlreadyUsed`) and `SaltZero`.
3. **Stalled sweep** — `stalledRaffles(cursor, batch)` returns `PENDING_VRF` raffles past
   `STALL_TIMEOUT`. For each: `getResolutionState` + `getRaffle` decide between
   `retryResolve(id, freshSalt)` (attempts < `MAX_RESOLVE_ATTEMPTS` and before
   `expiry + HARD_DEADLINE`) and `cancelStalledRaffle(id)`. A `FailedCallbackPending`
   revert is followed by permissionless `pokeFailedCallback(id)` (the coordinator had
   buffered the reveal) instead of hammering `retryResolve`.
4. **Fees/gas** — pre-flight top-up when `RAFFLE_FEE_FUND_THRESHOLD` is set, plus a
   top-up-and-retry on `InsufficientFeeBalance`.

### Cron #2 — settlement (`src/jobs/settle.ts`)

There is no on-chain view for “RESOLVED and un-settled”, so the queue is derived
from **two independent discovery paths** that both feed the same dedup'd queue.
Either path alone is enough; running both means a broken log RPC can no longer
strand a fulfilled raffle.

1. **On-chain status sweep (authoritative, `getLogs`-independent)** —
   `src/sweep.ts` walks raffle ids forward from a persisted cursor
   (`RAFFLE_SETTLE_SWEEP_BATCH` ids per cycle), reads `getRaffle(id).status`, and
   enqueues every `RESOLVED` id. `OPEN` / `PENDING_VRF` ids are remembered in a
   rotating watchlist and re-checked on later cycles (a raffle is usually still
   `OPEN` when its id is first swept and only becomes `RESOLVED` later);
   `COMPLETED` / `CANCELLED` ids are dropped. The cursor only advances past ids
   whose status was actually read, so a transient RPC failure resumes at the same
   id instead of skipping a raffle. Disable with `RAFFLE_SETTLE_SWEEP_ENABLED=false`.
   This is what keeps settlement alive when the log RPC rejects historical
   `eth_getLogs` (archive-only / Cloudflare 403) or the metered provider is
   rate-limited — the exact failure that left raffle #1 `RESOLVED` and unsettled
   on mainnet.

2. **Fulfilled-log scan (fast path)** — `eth_getLogs` for `RandomnessFulfilled`
   from the persisted cursor
   (`RAFFLE_START_BLOCK` or a `RAFFLE_LOG_LOOKBACK_BLOCKS` lookback on first run),
   chunked by `RAFFLE_LOG_CHUNK_SIZE`. Managed RPCs cap the block span of one
   `eth_getLogs` call (Alchemy's free tier allows only 10 blocks), so the scanner
   reads the provider's error, shrinks the chunk to the allowed range and retries
   the same span instead of failing the whole scan; the working size is persisted
   in the state file, keyed to the RPC URL it was learned from, and reused on
   later cycles/restarts. Switching `RAFFLE_LOG_RPC_URL` therefore re-probes with
   `RAFFLE_LOG_CHUNK_SIZE` instead of inheriting the previous provider's cap — a
   10-block cap learned from a metered key must never be applied to a wide-range
   endpoint, or the scan can never catch up to head. Each chunk is
   checkpointed, so a crash or the `RAFFLE_LOG_MAX_REQUESTS_PER_CYCLE` budget
   resumes where it stopped rather than replaying the window. When the budget is
   exhausted the scan backs off (60 s, doubling to 15 min) instead of re-burning
   the budget every cycle. On a contract that has no raffles yet, the first run
   skips the lookback and starts at head. A scan that fails outright (archive /
   403 / 429) is logged and ignored — the on-chain sweep above still discovers
   everything.

   > **Compute-unit note.** A narrow `eth_getLogs` cap is expensive on a fast
   > chain: 10-block chunks cost ~7.5 CU per block scanned, so a chain producing
   > ~9 blocks/s burns ~5.6 M CU/day just keeping the cursor at head. Set
   > `RAFFLE_LOG_RPC_URL` to a wide-range endpoint (the chain's public RPC
   > handles 100 k-block ranges) so the scan does not drain a metered provider.
   > Stretching `RAFFLE_SETTLE_INTERVAL_MS` does **not** reduce this cost — the
   > same blocks still have to be scanned. If no such endpoint is available, the
   > on-chain sweep makes the log scan optional.
3. **Settle** — for each due queue item, `getRaffle(id)` is the source of truth:
   - `RESOLVED` → `settle(id)` (permissionless; any relayer could do it)
   - `PENDING_VRF` → the log was reorged away; drop (the resolve sweep handles the stall)
   - `COMPLETED` / `CANCELLED` → already settled elsewhere; drop
4. **Escrow** — if the settle receipt contains `PayoutEscrowed` / `NftEscrowed`, the
   transfer failed and the recipient must pull-claim (`claim` / `claimNft`). The raffle
   is marked settled and **never retried**; a loud alert includes the escrowed entries.

### State file (single instance)

`data/keeper-state.json` (atomic tmp+rename writes, debounced, pid-locked) holds the
settle queue (with attempts/backoff), the on-chain sweep cursor + watchlist, the log
scan cursor, a settled-id ring and the per-raffle salt registry. A second process
pointed at the same file refuses to start. Deleting it is safe: the settle queue
rebuilds from the on-chain sweep and the lookback window, and status checks drop
already-completed raffles.

---

## 4. Error handling summary

| Condition | Behaviour |
| --- | --- |
| `RaffleNotOpen` / `RaffleNotExpired` / `RaffleNoTickets` | race — skip silently (`debug`) |
| `RaffleNotPendingVrf` / `StallTimeoutNotReached` / `MaxAttemptsReached` / `StalledConditionNotMet` | state moved on — skip |
| `NotResolver` | loud alert (key not allowlisted) + fix hint |
| `InsufficientFeeBalance(fee, balance)` | alert + auto top-up + one retry when enabled |
| `SaltAlreadyUsed` / `SaltZero` | regenerate salt, retry once, then log |
| `RandomnessRequestFailed` event in a mined resolve/retry tx | warn (provider `getFee` failed); raffle stays OPEN and is retried; optionally cancelled after grace |
| `FailedCallbackPending` | `pokeFailedCallback(id)` (permissionless) instead of retrying |
| `RaffleNotResolved` on `settle` | someone else settled; mark settled and move on |
| `PayoutEscrowed` / `NftEscrowed` on `settle` | alert, mark settled, do **not** retry |
| Nonce / RPC / timeout errors | exponential backoff retry per tx, then cross-cycle backoff; dropped after `RAFFLE_SETTLE_MAX_ATTEMPTS` + alert |
| One raffle throws | caught, logged, the sweep continues with the next raffle |
| `eth_getLogs` span rejected by RPC | chunk auto-shrinks to the provider's cap and is remembered in the state file; the same span is retried |
| Fulfilled-log scan fails | logged; the existing queue still drains and the next cycle resumes from the persisted cursor |
| First run, contract has no raffles | skip the lookback scan and start the cursor at head |
| RPC over quota / rate-limited at startup | keeper waits with exponential backoff in-process instead of exiting, so PM2 does not crash-loop and the deploy does not fail |
| RPC over quota during a cycle | logged; the next cycle retries, and the scan cursor resumes where it stopped |

Loud alerts (log + optional webhook, rate-limited per key): not-allowlisted key,
insufficient fee balance, failed top-up, low keeper gas, escrowed payouts, abandoned
settlements, failed cancel/retry transactions.

---

## 5. Running it

### systemd (recommended)

```ini
# /etc/systemd/system/winr-keeper.service
[Unit]
Description=WinrCore keeper (resolve + settle)
After=network-online.target

[Service]
Type=simple
User=winr
WorkingDirectory=/opt/winr-keeper
EnvironmentFile=/etc/winr-keeper.env
ExecStart=/usr/bin/node dist/index.js
Restart=always
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

```bash
npm run build                  # produces dist/
systemctl enable --now winr-keeper
journalctl -u winr-keeper -f
```

### External cron / timers

`RAFFLE_RUN_ONCE=true` (or `--once`) runs each enabled job once and exits. Guard
against overlap with `flock`; for different cadences run two entries with
`RAFFLE_JOBS` and separate state files:

```cron
*/2 * * * * flock -n /tmp/winr-resolve.lock env RAFFLE_JOBS=resolve RAFFLE_RUN_ONCE=true RAFFLE_STATE_FILE=/var/lib/winr/resolve.json node /opt/winr-keeper/dist/index.js >> /var/log/winr-resolve.log 2>&1
* * * * *   flock -n /tmp/winr-settle.lock  env RAFFLE_JOBS=settle  RAFFLE_RUN_ONCE=true RAFFLE_STATE_FILE=/var/lib/winr/settle.json  node /opt/winr-keeper/dist/index.js >> /var/log/winr-settle.log 2>&1
```

### Recovering an abandoned settlement

Dropped raffles are kept in the state file's `abandoned` array with the last error.
After fixing the root cause (RPC/gas), stop the keeper, remove the entry from
`abandoned`, and start it again — or settle it manually:

```bash
cast send $CONTRACT "settle(uint256)" <raffleId> --rpc-url $RPC --private-key $ANY_KEY
```

---

## 6. Old `checkUpkeep` / `performUpkeep` / `VRFRequested` flow — audit

**This service contains zero references to the legacy Chainlink Automation / VRF flow.**
Verify with:

```bash
grep -rniE 'checkUpkeep|performUpkeep|VRFRequested|KeeperCompatible|subscriptionId|fulfillRandomWords|upkeep' src/ test/   # no matches
```

Nothing forced a reuse of the old shapes; the new contract exposes first-class keeper
views and a separate settlement step, so the mapping is direct:

| Legacy `RaffledCore` (Base, Chainlink) | This keeper (WinrCore, Quiver) |
| --- | --- |
| Chainlink Automation calls `checkUpkeep` every block | keeper cron #1 calls `pendingResolution(cursor, limit)` on its own schedule |
| `performUpkeep(performData)` requests VRF | `resolveRaffle(id, salt)` with a fresh secret CSPRNG salt (resolver-gated) |
| wait for `VRFRequested` → `RandomWordsFulfilled` callback | no wait: `RandomnessRequested` is fire-and-forget; the Quiver push callback flips status to `RESOLVED` |
| prize paid out inside the VRF callback | separate, permissionless `settle(id)` (cron #2) |
| upkeep funding / VRF subscription balance | keeper wallet gas + contract native balance via `fundRandomnessFees()` |
| no recovery path for a stuck request | `stalledRaffles` → `retryResolve` (fresh salt, bounded attempts) or `cancelStalledRaffle` + `claimRefund` |

`checkUpkeep` / `performUpkeep` / `VRFRequested` still exist in the repository only in the
**legacy, untouched** artifacts: `src/RaffledCore.sol`, `src/RaffleManager{3,4,5,6}.sol`,
their tests, old scripts, and the root `README.md`. Neither this keeper nor
`src/WinrCore.sol` uses them.

---

## 7. File map

```
winr-keeper/
├── src/
│   ├── index.ts             # config load, preflight checks, scheduler, shutdown
│   ├── config.ts            # env parsing + validation (ConfigError lists all problems)
│   ├── logger.ts            # structured JSON logs, salt/key redaction
│   ├── alerts.ts            # rate-limited loud alerts + optional webhook
│   ├── abi.ts               # trimmed WinrCore ABI (+ errors for revert decoding)
│   ├── chain.ts             # Robinhood chain defs (4663/46630), viem clients
│   ├── errors.ts            # custom-error decoding, transient classification
│   ├── tx.ts                # send + confirm + retry/backoff + receipt-revert decoding
│   ├── salt.ts              # 32-byte CSPRNG salt generator, per-raffle uniqueness
│   ├── state.ts             # pid-locked JSON state: queue, cursor, salts, settled ring
│   ├── logs.ts              # adaptive/resumable eth_getLogs range scanner
│   ├── pagination.ts        # cursor-loop driver with runaway guards
│   ├── contract.ts          # views, constants, receipt event summary
│   └── jobs/
│       ├── resolve.ts       # cron #1
│       └── settle.ts        # cron #2
└── test/                    # node:test unit tests (salt, pagination, config, errors)
```
