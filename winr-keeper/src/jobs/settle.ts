import type { PublicClient } from 'viem';
import { randomnessFulfilledEvent } from '../abi.ts';
import type { Alerter } from '../alerts.ts';
import type { KeeperConfig } from '../config.ts';
import { getRaffleCount, getRaffleStatus, getRaffleView, summarizeSettlementReceipt } from '../contract.ts';
import type { Logger } from '../logger.ts';
import { scanLogsAdaptive } from '../logs.ts';
import type { StateStore } from '../state.ts';
import { sweepForResolvedRaffles, type SweepResult } from '../sweep.ts';
import type { TxSender } from '../tx.ts';
import { RaffleStatus, raffleStatusName } from '../types.ts';

/**
 * Quota protection for the fulfilled-log scan. When a scan cannot finish
 * within its per-cycle request budget (the keeper is behind), pause the next
 * scan for a growing window instead of re-burning the whole budget on the very
 * next cycle. The window resets as soon as a scan catches up.
 */
const SCAN_BACKOFF_BASE_MS = 60_000;
const SCAN_BACKOFF_MAX_MS = 15 * 60_000;

interface ScanReport {
  logsSeen: number;
  enqueued: number;
  requests: number;
  budgetExhausted: boolean;
}

export interface SettleJobDeps {
  cfg: KeeperConfig;
  logger: Logger;
  publicClient: PublicClient;
  /** Client used only for the `eth_getLogs` scan (may be a wide-range RPC). */
  logPublicClient: PublicClient;
  sender: TxSender;
  state: StateStore;
  alert: Alerter;
}

/**
 * Cron #2 — settlement relayer.
 *
 * There is no on-chain view for "RESOLVED and un-settled", so the queue is
 * derived from two independent discovery paths:
 *   1. on-chain status sweep (authoritative, getLogs-independent): walk raffle
 *      ids forward from a persisted cursor, reading `getRaffle` status, and
 *      enqueue RESOLVED ones; re-check previously-seen non-terminal raffles via
 *      a rotating watchlist so a raffle that was OPEN when first seen is caught
 *      when it later resolves. This is what keeps settlement working when the
 *      RPC's `eth_getLogs` is unusable (archive/403/429).
 *   2. fulfilled-log scan (fast path): chunked `eth_getLogs` from the persisted
 *      cursor for `RandomnessFulfilled`; on first run, look back N blocks. It is
 *      cheap when the log RPC supports the range and harmless when it does not.
 * Both feed the same dedup'd queue. Then, for each due item, read getRaffle():
 * only RESOLVED goes to `settle()` (reorg / already-settled are dropped).
 * Escrowed payouts (PayoutEscrowed / NftEscrowed) are logged and the raffle is
 * marked settled — never retried.
 */
export class SettleJob {
  readonly #cfg: KeeperConfig;
  readonly #logger: Logger;
  readonly #publicClient: PublicClient;
  readonly #logPublicClient: PublicClient;
  readonly #sender: TxSender;
  readonly #state: StateStore;
  readonly #alert: Alerter;

  constructor(deps: SettleJobDeps) {
    this.#cfg = deps.cfg;
    this.#logger = deps.logger;
    this.#publicClient = deps.publicClient;
    this.#logPublicClient = deps.logPublicClient;
    this.#sender = deps.sender;
    this.#state = deps.state;
    this.#alert = deps.alert;
  }

  async run(): Promise<void> {
    const startedAt = Date.now();

    // Path 1 (authoritative, getLogs-independent): sweep on-chain status. This
    // is what guarantees a RESOLVED raffle is never missed when the RPC's
    // eth_getLogs is unavailable (archive/403/429) and the log scan below
    // cannot advance.
    let swept: SweepResult = { scanned: 0, resolved: 0, watching: 0, moreToScan: false };
    try {
      swept = await this.#sweepOnChain();
    } catch (error) {
      this.#logger.error('on-chain settlement sweep failed — will retry next cycle', {
        error: error instanceof Error ? error.message : String(error),
      });
    }

    // Path 2 (fast path): the fulfilled-log scan. Kept because it is cheap when
    // the log RPC supports the range; failures are tolerated — the sweep above
    // still discovers everything.
    let scanned: ScanReport = { logsSeen: 0, enqueued: 0, requests: 0, budgetExhausted: false };
    try {
      scanned = await this.#scanFulfilledLogs();
    } catch (error) {
      // A failed scan (RPC down, unsupported range, quota error) must not stop
      // the queue from draining. The cursor is checkpointed per chunk, so the
      // next cycle resumes where this one stopped instead of replaying the
      // whole window.
      this.#logger.error('fulfilled-log scan failed — relying on the on-chain sweep', {
        error: error instanceof Error ? error.message : String(error),
      });
    }

    const settled = await this.#processQueue();
    this.#logger.info('settle cycle complete', {
      ...swept,
      ...scanned,
      ...settled,
      queue: this.#state.queueSize(),
      durationMs: Date.now() - startedAt,
    });
  }

  // ── Step 0: on-chain status sweep (getLogs-independent) ───────────────────

  async #sweepOnChain(): Promise<SweepResult> {
    if (!this.#cfg.settleSweepEnabled) {
      return { scanned: 0, resolved: 0, watching: 0, moreToScan: false };
    }
    const raffleCount = await getRaffleCount(this.#publicClient, this.#cfg.contractAddress);
    return sweepForResolvedRaffles({
      raffleCount,
      batchSize: this.#cfg.settleSweepBatch,
      watchBatchSize: this.#cfg.settleSweepBatch,
      recentLookback: this.#cfg.settleSweepBatch,
      state: this.#state,
      readStatus: (raffleId) => getRaffleStatus(this.#publicClient, this.#cfg.contractAddress, raffleId),
      onResolved: (raffleId) => {
        if (this.#state.enqueue(raffleId)) {
          this.#logger.info('on-chain sweep enqueued RESOLVED raffle for settlement', {
            raffleId: raffleId.toString(),
          });
        }
      },
      logger: this.#logger,
    });
  }

  // ── Step 1: RandomnessFulfilled -> queue ──────────────────────────────────

  async #scanFulfilledLogs(): Promise<ScanReport> {
    const backoffUntil = this.#state.scanBackoffUntil;
    if (backoffUntil > Date.now()) {
      this.#logger.debug('fulfilled-log scan in backoff — skipping this cycle', {
        retryInMs: backoffUntil - Date.now(),
      });
      return { logsSeen: 0, enqueued: 0, requests: 0, budgetExhausted: false };
    }

    const latest = await this.#logPublicClient.getBlockNumber();
    let from: bigint;

    if (this.#state.lastScannedBlock !== null) {
      from = this.#state.lastScannedBlock + 1n;
    } else if (this.#cfg.startBlock !== undefined) {
      from = this.#cfg.startBlock;
      this.#logger.info('first run: scanning from RAFFLE_START_BLOCK', { fromBlock: from.toString() });
    } else {
      // On a fresh deployment there is nothing to settle until the contract has
      // at least one raffle; skip the (large, costly) empty lookback scan and
      // start at head.
      const raffleCount = await getRaffleCount(this.#publicClient, this.#cfg.contractAddress).catch(() => undefined);
      if (raffleCount === 0n) {
        this.#state.setScannedBlock(latest);
        await this.#state.flush();
        this.#logger.info('first run: contract has no raffles yet — scan cursor starts at head', {
          block: latest.toString(),
        });
        return { logsSeen: 0, enqueued: 0, requests: 0, budgetExhausted: false };
      }

      from = latest > this.#cfg.logLookbackBlocks ? latest - this.#cfg.logLookbackBlocks : 0n;
      this.#logger.info('first run: scanning recent blocks for fulfilled-but-unsettled raffles', {
        fromBlock: from.toString(),
        lookbackBlocks: this.#cfg.logLookbackBlocks.toString(),
      });
    }

    if (from > latest) return { logsSeen: 0, enqueued: 0, requests: 0, budgetExhausted: false };

    // Prefer the smallest learned chunk size so a provider with a narrow
    // eth_getLogs cap is never asked for an oversized range again. The learned
    // value is scoped to the RPC URL it came from, so switching providers
    // re-probes instead of reusing the old provider's cap. An explicit
    // RAFFLE_LOG_CHUNK_SIZE always wins (reset after switching providers).
    const configured = this.#cfg.logChunkSize;
    const learned = this.#state.learnedLogChunkSize(this.#cfg.logRpcUrl);
    const chunkSize =
      this.#cfg.logChunkSizeExplicit || learned === null ? configured : learned < configured ? learned : configured;

    let enqueued = 0;
    const result = await scanLogsAdaptive({
      fromBlock: from,
      toBlock: latest,
      chunkSize,
      maxRequests: this.#cfg.logMaxRequestsPerCycle,
      logger: this.#logger,
      fetchChunk: (fromBlock, toBlock) =>
        this.#logPublicClient.getLogs({
          address: this.#cfg.contractAddress,
          event: randomnessFulfilledEvent,
          fromBlock,
          toBlock,
        }),
      onLogs: async (logs) => {
        for (const log of logs) {
          if (log.args.raffleId === undefined) continue;
          if (this.#state.enqueue(log.args.raffleId)) {
            enqueued += 1;
            this.#logger.info('enqueued fulfilled raffle for settlement', { raffleId: log.args.raffleId.toString() });
          }
        }
      },
      // Persist per chunk: a crash (or the per-cycle budget) resumes after the
      // last successful chunk instead of replaying the whole window.
      onCheckpoint: async (lastScannedBlock, effectiveChunkSize) => {
        this.#state.setScannedBlock(lastScannedBlock);
        this.#state.setLearnedLogChunkSize(this.#cfg.logRpcUrl, effectiveChunkSize);
        await this.#state.flush();
      },
    });

    if (result.budgetExhausted) {
      const nextBackoff = Math.min(
        this.#state.scanBackoffMs > 0 ? this.#state.scanBackoffMs * 2 : SCAN_BACKOFF_BASE_MS,
        SCAN_BACKOFF_MAX_MS,
      );
      this.#state.setScanBackoff(nextBackoff);
      this.#logger.info('fulfilled-log scan request budget reached — backing off before resuming', {
        requests: result.requests,
        lastScannedBlock: result.lastScannedBlock?.toString() ?? null,
        latestBlock: latest.toString(),
        retryInMs: nextBackoff,
      });
    } else {
      this.#state.clearScanBackoff();
    }

    return {
      logsSeen: result.logsSeen,
      enqueued,
      requests: result.requests,
      budgetExhausted: result.budgetExhausted,
    };
  }

  // ── Step 2: queue -> settle() ─────────────────────────────────────────────

  async #processQueue(): Promise<{ tried: number; settled: number; requeued: number; abandoned: number }> {
    const due = this.#state.dueQueue();
    const outcome = { tried: 0, settled: 0, requeued: 0, abandoned: 0 };

    for (const item of due) {
      const raffleId = BigInt(item.raffleId);
      outcome.tried += 1;

      let status: number;
      try {
        const raffle = await getRaffleView(this.#publicClient, this.#cfg.contractAddress, raffleId);
        status = Number(raffle.status);
      } catch (error) {
        // Read failure: leave the item due so the next cycle retries.
        this.#logger.warn('could not read raffle status — will retry next cycle', {
          raffleId,
          error: error instanceof Error ? error.message : String(error),
        });
        continue;
      }

      if (status !== RaffleStatus.RESOLVED) {
        this.#state.dequeue(raffleId);
        if (status === RaffleStatus.PENDING_VRF) {
          // The RandomnessFulfilled log was reorged away (or has not taken
          // effect); the raffle will emit again when re-fulfilled, and the
          // resolve sweep handles a PENDING_VRF stall.
          this.#logger.debug('fulfilled log not effective — dropped from queue', { raffleId });
        } else {
          this.#logger.debug('raffle no longer RESOLVED — dropped from queue', {
            raffleId,
            status: raffleStatusName(status),
          });
        }
        continue;
      }

      const result = await this.#settleOne(raffleId);
      if (result === 'settled') {
        outcome.settled += 1;
      } else if (result === 'requeued') {
        outcome.requeued += 1;
      } else {
        outcome.abandoned += 1;
      }
    }

    return outcome;
  }

  async #settleOne(raffleId: bigint): Promise<'settled' | 'requeued' | 'abandoned'> {
    const result = await this.#sender.send(
      { functionName: 'settle', args: [raffleId] },
      { label: 'settle', raffleId },
    );

    if (result.kind === 'dry-run') {
      this.#logger.info('dry-run: would settle raffle', { raffleId });
      return 'settled';
    }

    if (result.kind === 'ok') {
      const summary = summarizeSettlementReceipt(result.receipt);
      if (summary.escrows.length > 0) {
        // Push-with-escrow fallback: the payout transfer failed and the
        // recipient must pull-claim. The raffle is COMPLETED — do not retry.
        this.#alert.alert(
          'settle completed but some payouts were escrowed — recipients must pull-claim (claim/claimNft)',
          { raffleId, tx: result.hash, escrows: summary.escrows },
          { key: `escrow-${raffleId}` },
        );
      }
      this.#logger.info('raffle settled', {
        raffleId,
        tx: result.hash,
        winner: summary.winner,
        events: summary.eventNames,
      });
      this.#state.markSettled(raffleId);
      return 'settled';
    }

    if (result.kind === 'reverted' && result.error.name === 'RaffleNotResolved') {
      // Permissionless: someone else got there first (or it was cancelled).
      this.#logger.info('raffle no longer RESOLVED on-chain — marking settled', { raffleId });
      this.#state.markSettled(raffleId);
      return 'settled';
    }

    // Failure path: bounded cross-cycle retry with exponential backoff.
    const errorText = result.kind === 'reverted' ? (result.error.name ?? result.error.shortMessage) : result.error.shortMessage;
    const nextAttempt = this.#state.attemptsFor(raffleId) + 1;
    const delayMs = Math.min(this.#cfg.txRetryBaseMs * 2 ** (nextAttempt - 1), 5 * 60_000);
    const attempts = this.#state.bumpAttempt(raffleId, errorText, delayMs);

    if (attempts >= this.#cfg.settleMaxAttempts) {
      this.#state.abandon(raffleId, errorText);
      this.#alert.alert(
        'settle abandoned after repeated failures — manual intervention required',
        { raffleId, attempts, lastError: errorText },
        { key: `settle-abandoned-${raffleId}` },
      );
      return 'abandoned';
    }

    this.#logger.warn('settle failed — retrying with backoff', {
      raffleId,
      attempt: attempts,
      maxAttempts: this.#cfg.settleMaxAttempts,
      retryInMs: delayMs,
      error: errorText,
    });
    return 'requeued';
  }
}
