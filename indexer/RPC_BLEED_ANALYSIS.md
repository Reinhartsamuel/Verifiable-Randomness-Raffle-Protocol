# Raffled Indexer — RPC Bleed & Architecture Analysis

Date: 2026-08-11
Scope: `raffled-indexer/` (Ponder v0.17.4, viem 2.35.0), Base Sepolia (chain 84532), single contract `RaffledCore`.
Note: `.env` / `.env.local` were intentionally **not** read for this analysis, per instructions. Findings below are based on `ponder.config.ts`, `ponder.schema.ts`, `src/RaffledCore.ts`, `.env.example`, `ecosystem.config.cjs`, `.github/workflows/deploy-indexer.yml`, `foundry.toml`, and git history.

---

## TL;DR

The RPC bleed is **not** caused by a missing rate limiter — a rate limiter *is* correctly wired in `ponder.config.ts`. It's caused by **CI/CD triggering a full historical resync on almost every push**, combined with a **per-event extra `eth_call`**, and (unverified without reading `.env`) a possible leftover **multi-provider fallback config on the VPS** from an earlier, abandoned design. In short: the indexer isn't leaking RPC calls while idle — it's re-doing the entire backfill over and over because its own deploy pipeline nukes the database schema whenever `ponder.config.ts` changes, and `ponder.config.ts` gets edited in almost every commit.

---

## 1. Why does it keep bleeding RPC across 3 providers, every run, for "one day"?

### Root cause A — CI/CD forces a full schema wipe + resync on nearly every push

`.github/workflows/deploy-indexer.yml` runs on every push to `main` that touches `raffled-indexer/**`, and does:

```
pm2 delete raffled-indexer || true
pm2 start ecosystem.config.cjs
...
if grep -q "previously used by a different Ponder app" <log>; then
  DROP SCHEMA IF EXISTS "main" CASCADE
  pm2 restart raffled-indexer
fi
```

Ponder derives a "build/app identity" hash from `ponder.config.ts` (and schema). Git history shows **`ponder.config.ts` has been edited in essentially every indexer commit** (10 of ~11 substantive commits: RPC fallback changes, block-range tuning, rate limiter, start block, etc.), while `ponder.schema.ts` has been touched exactly once (initial commit). Every time that config hash changes, Ponder refuses to reuse the existing Postgres tables ("previously used by a different Ponder app"), the workflow detects this and **drops the entire schema**, and the indexer must **backfill from `startBlock` all over again** on the next boot.

This means: during active "testing" (i.e. iterating on `ponder.config.ts` to fix RPC issues — which is exactly what the git log shows happening), **every single push re-triggers a full historical sync**, not just an incremental one. That alone can explain "every time I run the indexer it bleeds RPC for a day" — you're not running it once, you're forcing a from-scratch resync on every deploy while tuning the very file that controls RPC behavior.

### Root cause B — an extra `eth_call` per `RaffleCreated` event, fired during backfill too

`src/RaffledCore.ts`'s `RaffleCreated` handler calls:

```ts
const data = await context.client.readContract({
  address: RAFFLED_CORE_ADDRESS,
  abi: RaffledCoreAbi,
  functionName: "getRaffle",
  args: [raffleId],
});
```

This runs for **every** `RaffleCreated` event, both live and historical. If you're actively testing (creating many raffles manually), each one adds an `eth_call` on top of the `eth_getLogs` traffic. Bounded by event count, but it compounds with root cause A: every forced resync re-issues one `readContract` per historical `RaffleCreated` log, again.

### Root cause C — possible leftover multi-provider fallback, unverified

Git history shows an **abandoned** design (`7ef3df2`, `7de3d2b`) that fanned requests out across the official Base public RPC + publicnode + drpc "to spread backfill load." That is **not** present in the current `ponder.config.ts` — today's config uses exactly one HTTP transport (rate-limited to 4 req/s) plus one WS URL, both derived from a single `PONDER_RPC_URL_84532` value. `.env.example` also documents only one RPC var.

However: you mentioned bleeding **Zan, QuickNode, and Alchemy specifically** (three distinct providers) — the current code doesn't reference Zan or QuickNode by name at all except in a comment about Zan's credit cap. This strongly suggests that **whatever is actually in your `.env`/`.env.local` on the VPS (or locally) may still be pointing `PONDER_RPC_URL_84532`/`PONDER_WS_URL_84532` at different providers across different runs/redeploys** — e.g. you swapped providers between test runs without ever letting the old backfill finish, so each provider individually ate one full (or partial) resync's worth of credits. Combined with root cause A (schema gets wiped whenever config changes — and swapping the RPC URL env var doesn't even need to change `ponder.config.ts` to force a resync if you also deleted `.ponder/` or the Postgres schema manually while debugging), this adds up to 3 separate full/partial backfills, one per provider you tried.

I did not read `.env`/`.env.local` to confirm which provider(s) are currently wired in — worth checking manually.

### Root cause D — `.ponder/` local cache is never persisted across a clean checkout

`.ponder/` (Ponder's local sync/checkpoint cache) is gitignored, which is correct, but the deploy script does `git fetch && git reset --hard` (not `git clean`), so `.ponder/` *should* survive redeploys on the same VPS path — meaning root cause A's schema-hash mismatch (a Postgres-level identity, not a filesystem one) is the actual forcing function, not cache loss. If you've ever manually `rm -rf .ponder` while debugging, or pointed the DB at a fresh Postgres instance, that's an equivalent trigger.

---

## 2. Does it already use WS instead of expensive polling?

**Partially — realtime yes, historical/backfill no (by design, that's normal).**

- `ponder.config.ts` sets `ws: WS_URL` for the `baseSepolia` chain. This makes Ponder subscribe to `eth_subscribe("newHeads")` over WebSocket for **realtime/live tip-following**, instead of polling `eth_getBlockByNumber` every 1s (Ponder's default when no `ws` is configured). This part is correctly implemented and is a real, meaningful cost saver **once the indexer is caught up and idle**.
- `eth_getLogs` still only fires against a block when Ponder's realtime pipeline for a matched block's bloom filter (or during historical backfill) actually needs it — this is normal and not "polling" in the wasteful sense.
- **Historical backfill (from `startBlock: 45269179` to current tip) always uses HTTP `eth_getLogs`/`eth_getBlockByNumber` in bounded chunks (`ethGetLogsBlockRange: 1000`) regardless of WS** — there's no way to do a backfill over a websocket subscription; that part is inherently a burst of HTTP requests. That's expected and is what the 4 req/s rate limiter is throttling.
- **Conclusion:** WS is correctly used for idle/live traffic. The "bleed" you're seeing is almost certainly from repeated backfills (root causes A–C above), not from idle-state polling — the idle-state polling problem was already solved.

---

## 3. What's wrong overall, and what can be fixed?

### Critical
1. **CI/CD drops the whole schema and forces a full resync on nearly every push that edits `ponder.config.ts`.** During active tuning of exactly that file (which is what's been happening per git log), this guarantees repeated full backfills. Fix direction: stop iterating on production RPC/backfill config via push-to-main+auto-redeploy; iterate locally against a throwaway Postgres schema/db first, and only push to `main` once the config is stable. Alternatively, decouple "config changed" from "must wipe schema" — e.g. keep `startBlock` and contract address stable across tuning cycles so only cosmetic transport code changes, though Ponder's app-id hash may still consider any config diff a new app; the safer fix is to not deploy-to-VPS while iterating.

2. **Verify what's actually in `.env`/`.env.local` on the VPS/local machine right now.** The current code only supports and expects a single `PONDER_RPC_URL_84532` (+ optional `PONDER_WS_URL_84532`). If Zan, QuickNode, and Alchemy keys have all been pasted into that single var across different test sessions without letting the previous backfill finish or without resetting the DB schema in between, each one absorbs a resync. Standardize on **one provider, one key**, and don't rotate providers mid-backfill.

### High
3. **`getRaffle` extra `readContract` per `RaffleCreated` event** (`src/RaffledCore.ts`) adds an `eth_call` per raffle-creation event during both backfill and realtime. Since it's a workaround for a pre-upgrade event shape missing `ticketPrice`/`maxCap`, consider: (a) if the currently deployed contract can be redeployed with the fixed event (fresh testnet, no real users, no mainnet — this is the easiest window to do it), remove the extra call entirely; or (b) if not, batch these reads via multicall instead of one `readContract` per event.

4. **The rate limiter is hand-rolled instead of using `@ponder/utils`'s built-in `rateLimit()` helper**, which is already a transitive dependency (`node_modules/@ponder/utils/src/rateLimit.ts`) but isn't imported. The custom version works, but re-implementing throttling by hand (with manual `nextSlot` bookkeeping and a hand-set `retryCount: 0`) is more failure-prone than using the maintained helper, and makes it harder to reason about whether Ponder's own retry/backoff and the custom gate interact correctly under real 429s. Recommend switching to the official helper if it fits the same interface, or at minimum adding tests around the throttle math.

5. **No `maxHistoricalTaskConcurrency` / `maxRealtimeTaskConcurrency` override.** The code comments explicitly diagnose "Ponder's 10-request concurrency bursts past that cap" as the original cause of 429 storms, then work around it entirely inside the custom transport (serializing all requests to 4 req/s) rather than also turning down Ponder's own concurrency setting. Both together would be more robust — right now, 10 concurrent historical tasks all queue up behind the same single 4 req/s gate, which works but means 10x the in-flight requests are parked waiting at once; tune `maxHistoricalTaskConcurrency` down (e.g. 2-4) so the concurrency ceiling and the rate limiter are aligned by design, not just accidentally compatible.

### Medium
6. **`ethGetLogsBlockRange: 1000` is a fixed, non-adaptive chunk size.** This was intentionally pinned to stop Ponder's adaptive logic from collapsing to 1-block requests on errors (a real past problem per commit `ee4b7fd`), but a fixed value that's too large can itself trigger provider-side `eth_getLogs` result-size limits (many free tiers cap at ~10k logs or ~2-10MB per response), causing errors → retries → more requests. Worth confirming 1000 blocks never produces oversized responses for `RaffledCore`'s current event volume; if raffle activity increases during testing, consider scaling this down or reintroducing adaptive chunking with a sane floor instead of disabling it outright.

7. **No dedicated "test"/staging deployment.** There are only two run modes: local `ponder dev` (which hot-reloads and can resync aggressively on file changes) and the VPS `ponder start` behind PM2, redeployed via CI on every push. There's no throwaway environment to validate RPC/backfill config changes without touching the "real" (already-provisioned) Postgres DB and provider keys — every config experiment happens directly against production credit-metered infrastructure. Recommend a local `.env.local` + local/ephemeral Postgres (or PGlite for pure dev iteration, even though the config currently hard-refuses PGlite) for tuning cycles, promoting to the VPS only once settled.

8. **`.env.example` is out of sync with the code comments.** Comments in `ponder.config.ts` reference "ZAN free tier" by name and past commits show publicnode/drpc fallbacks, but `.env.example` documents only Alchemy/QuickNode-style single-URL usage. Low risk technically, but worth cleaning up so whoever edits this next doesn't reintroduce the abandoned multi-provider fallback thinking it's still the intended design.

### Low / non-issues (confirmed fine)
- Single-chain (`baseSepolia` only) — no accidental multi-chain fan-out.
- `startBlock: 45269179` is recent (roughly weeks behind tip at time of writing on Base Sepolia), not a multi-year deep backfill — the "very old start block" failure mode does not apply here.
- WS realtime subscription for idle-state block following is correctly configured — already addressed the "expensive polling while idle" concern.
- PM2 is pinned to `instances: 1` / `fork` mode (a prior cluster-mode bug was already fixed), so no duplicate concurrent indexer processes from PM2 itself.
- Foundry side (`foundry.toml`) has no RPC endpoints configured and isn't a background source of RPC traffic — it only fires when scripts/tests are run manually.

---

## Recommended fix order

1. Stop pushing `ponder.config.ts` tuning changes straight to `main` while the CI auto-redeploys and drops the schema on every app-id mismatch — iterate locally first.
2. Confirm/normalize `.env`/`.env.local` to a single provider + key (pick one of Zan/QuickNode/Alchemy) and stop swapping providers mid-test.
3. Remove or multicall-batch the per-`RaffleCreated` `getRaffle` extra read.
4. Align `maxHistoricalTaskConcurrency` with the transport's 4 req/s gate instead of relying solely on the transport to absorb 10x concurrency.
5. Optionally swap the hand-rolled limiter for `@ponder/utils`'s `rateLimit()`.
6. Add a lightweight local/staging Postgres so config experiments don't hit the same DB/schema/provider credits as the "real" deployment.
