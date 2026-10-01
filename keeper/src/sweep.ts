import type { Logger } from './logger.ts';
import { RaffleStatus } from './types.ts';

/**
 * On-chain settlement discovery — the getLogs-independent path.
 *
 * `eth_getLogs` is the cheapest way to learn that a raffle reached RESOLVED, but
 * it is not always available: metered providers cap the block span, and some
 * public endpoints reject any historical range outright ("archive requests
 * require a token") or Cloudflare-ban the keeper's datacenter IP. When the log
 * scan cannot advance, a fulfilled raffle is never enqueued and `settle()` is
 * never called — the raffle sits in RESOLVED forever even though the resolver
 * and the randomness provider both did their job.
 *
 * This sweep derives the same work from chain state alone, so settlement no
 * longer depends on any provider's `eth_getLogs` support:
 *
 *  1. Forward pass — walk raffle ids we have never looked at (`raffleCount` is
 *     the only view needed to bound the range) and read each one's status.
 *     RESOLVED → enqueue; OPEN/PENDING_VRF → remember in a watchlist;
 *     COMPLETED/CANCELLED → nothing to do.
 *  2. Watch pass — re-check previously-seen non-terminal raffles, because a
 *     raffle is usually OPEN when its id is first swept and only becomes
 *     RESOLVED later. A resolved/terminal id leaves the watchlist.
 *
 * The forward cursor only advances past ids whose status was actually read, so a
 * transient RPC failure resumes at the same id next cycle instead of skipping a
 * raffle. The watchlist is processed in bounded rotating slices so a large
 * backlog cannot turn one cycle into thousands of `eth_call`s.
 */
export interface SweepState {
  /** Highest raffle id already swept in the forward pass (0 = none). */
  readonly sweepCursor: bigint;
  setSweepCursor(raffleId: bigint): void;
  /** Up to `limit` watched raffle ids, oldest first. */
  watchedRaffleIds(limit?: number): bigint[];
  watchRaffle(raffleId: bigint): void;
  unwatchRaffle(raffleId: bigint): void;
  /** Move a still-non-terminal watched id to the back of the rotation. */
  touchWatchedRaffle(raffleId: bigint): void;
}

export interface SweepOptions {
  raffleCount: bigint;
  /** Max raffle ids read in the forward pass this cycle. */
  batchSize: number;
  /** Max watched ids re-checked this cycle (rotating). */
  watchBatchSize: number;
  /**
   * On a cold start (no cursor, empty watchlist) also watch the most recent
   * `recentLookback` ids so a recently-fulfilled raffle is found without waiting
   * for the forward cursor to walk the whole history. Omit/0 disables it.
   */
  recentLookback?: number;
  state: SweepState;
  readStatus: (raffleId: bigint) => Promise<number>;
  onResolved: (raffleId: bigint) => void;
  logger: Logger;
}

export interface SweepResult {
  /** Raffle statuses actually read this cycle. */
  scanned: number;
  /** RESOLVED raffles handed to `onResolved` this cycle. */
  resolved: number;
  /** Raffle ids still watched as non-terminal after this cycle. */
  watching: number;
  /** True when the forward pass did not reach `raffleCount` (batch cap or error). */
  moreToScan: boolean;
}

function minBigint(a: bigint, b: bigint): bigint {
  return a < b ? a : b;
}

export async function sweepForResolvedRaffles(options: SweepOptions): Promise<SweepResult> {
  const { raffleCount, batchSize, watchBatchSize, recentLookback, state, readStatus, onResolved, logger } = options;
  let scanned = 0;
  let resolved = 0;
  /** Ids read in the forward pass, so the watch pass does not re-read them. */
  const handled = new Set<string>();

  // Cold start (no cursor, empty watchlist): a forward walk from id 1 can take
  // many cycles to reach the head on a mature contract, which would delay a
  // recently-fulfilled raffle. Watch the most recent ids first so the tail is
  // checked immediately; the forward pass still backfills the older ids.
  if (
    recentLookback !== undefined &&
    recentLookback > 0 &&
    state.sweepCursor === 0n &&
    state.watchedRaffleIds(1).length === 0 &&
    raffleCount > 0n
  ) {
    const lookback = BigInt(recentLookback);
    const from = raffleCount > lookback ? raffleCount - lookback + 1n : 1n;
    for (let raffleId = from; raffleId <= raffleCount; raffleId += 1n) {
      state.watchRaffle(raffleId);
    }
    logger.info('on-chain sweep: cold start — checking the most recent raffles first', {
      from: from.toString(),
      to: raffleCount.toString(),
    });
  }

  // Snapshot the watchlist before the forward pass so ids read there are not
  // re-read in the same cycle (see `handled`).
  const watchedSnapshot = state.watchedRaffleIds(watchBatchSize);

  // ── Phase 1: forward pass over ids we have never looked at ────────────────
  const cursor = state.sweepCursor;
  let moreToScan = false;
  if (cursor < raffleCount) {
    const last = minBigint(cursor + BigInt(batchSize), raffleCount);
    for (let raffleId = cursor + 1n; raffleId <= last; raffleId += 1n) {
      let status: number;
      try {
        status = await readStatus(raffleId);
      } catch (error) {
        // Never advance past an id we could not read — resume here next cycle.
        logger.warn('on-chain sweep: status read failed — resuming from this id next cycle', {
          raffleId: raffleId.toString(),
          error: error instanceof Error ? error.message : String(error),
        });
        moreToScan = true;
        break;
      }
      scanned += 1;
      handled.add(raffleId.toString());
      state.setSweepCursor(raffleId);

      if (status === RaffleStatus.RESOLVED) {
        onResolved(raffleId);
        resolved += 1;
        state.unwatchRaffle(raffleId);
      } else if (status === RaffleStatus.OPEN || status === RaffleStatus.PENDING_VRF) {
        state.watchRaffle(raffleId);
      } else {
        // COMPLETED / CANCELLED — terminal, nothing to settle or watch.
        state.unwatchRaffle(raffleId);
      }
    }
    if (state.sweepCursor < raffleCount) moreToScan = true;
  }

  // ── Phase 2: re-check previously-seen non-terminal raffles ────────────────
  for (const raffleId of watchedSnapshot) {
    if (handled.has(raffleId.toString())) continue;
    if (raffleId > raffleCount) {
      state.unwatchRaffle(raffleId);
      continue;
    }
    let status: number;
    try {
      status = await readStatus(raffleId);
    } catch (error) {
      logger.warn('on-chain sweep: watched status read failed — will retry next cycle', {
        raffleId: raffleId.toString(),
        error: error instanceof Error ? error.message : String(error),
      });
      state.touchWatchedRaffle(raffleId);
      continue;
    }
    scanned += 1;

    if (status === RaffleStatus.RESOLVED) {
      onResolved(raffleId);
      resolved += 1;
      state.unwatchRaffle(raffleId);
    } else if (status === RaffleStatus.COMPLETED || status === RaffleStatus.CANCELLED) {
      state.unwatchRaffle(raffleId);
    } else {
      // Still OPEN / PENDING_VRF — keep watching, rotate to the back.
      state.touchWatchedRaffle(raffleId);
    }
  }

  return { scanned, resolved, watching: state.watchedRaffleIds().length, moreToScan };
}
