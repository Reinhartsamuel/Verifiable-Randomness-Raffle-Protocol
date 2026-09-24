import { mkdir, open as openFile, readFile, rename, unlink, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import type { Logger } from './logger.ts';
import type { SaltStorage } from './salt.ts';

const STATE_VERSION = 1;
const MAX_SETTLED_CACHE = 2_000;
const MAX_SALTS_PER_RAFFLE = 64;
const MAX_ABANDONED = 1_000;
const MAX_RESOLVE_COOLDOWNS = 1_000;
const MAX_WATCHED_RAFFLES = 5_000;
const FLUSH_DEBOUNCE_MS = 250;

export interface QueueItem {
  raffleId: string;
  enqueuedAt: number;
  attempts: number;
  nextAttemptAt: number;
  lastError?: string;
}

export interface AbandonedItem {
  raffleId: string;
  reason: string;
  at: number;
}

interface PersistedState {
  version: number;
  lastScannedBlock: string | null;
  /** Effective eth_getLogs chunk size learned from the provider's range cap. */
  logChunkSize: string | null;
  /** RPC URL the learned chunk size belongs to (the cap is provider-specific). */
  logChunkRpcUrl: string | null;
  /** Epoch ms until which the fulfilled-log scan is paused (quota protection). */
  scanBackoffUntil: number;
  /** Current scan backoff window in ms (doubles while the scan stays behind). */
  scanBackoffMs: number;
  /** Highest raffle id read by the on-chain settlement sweep (0 = none yet). */
  sweepCursor: string;
  /** Raffle ids seen non-terminal (OPEN/PENDING_VRF) that may still become RESOLVED. */
  watchlist: string[];
  queue: QueueItem[];
  settled: string[];
  abandoned: AbandonedItem[];
  salts: Record<string, string[]>;
  /** raffleId -> epoch ms before which a failed resolve must not be retried. */
  resolveCooldowns: Record<string, number>;
}

function emptyState(): PersistedState {
  return {
    version: STATE_VERSION,
    lastScannedBlock: null,
    logChunkSize: null,
    logChunkRpcUrl: null,
    scanBackoffUntil: 0,
    scanBackoffMs: 0,
    sweepCursor: '0',
    watchlist: [],
    queue: [],
    settled: [],
    abandoned: [],
    salts: {},
    resolveCooldowns: {},
  };
}

/**
 * JSON-file state store with atomic writes (tmp + rename), a debounced flush
 * and a pid lock so two keeper processes cannot share one state file (which
 * would double-spend salts and double-send settles).
 *
 * Holds the settlement queue, the on-chain sweep cursor + watchlist, the log
 * scan cursor, the settled ring and the per-raffle salt registry.
 */
export class StateStore implements SaltStorage {
  readonly #file: string;
  readonly #lockFile: string;
  readonly #logger: Logger;
  #data: PersistedState;
  #flushTimer?: NodeJS.Timeout;
  #writeChain: Promise<void> = Promise.resolve();
  #closed = false;

  private constructor(file: string, lockFile: string, logger: Logger, data: PersistedState) {
    this.#file = file;
    this.#lockFile = lockFile;
    this.#logger = logger;
    this.#data = data;
  }

  static async open(file: string, logger: Logger): Promise<StateStore> {
    const absolute = resolve(file);
    await mkdir(dirname(absolute), { recursive: true });
    const lockFile = `${absolute}.lock`;
    await acquireLock(lockFile, logger);

    let data = emptyState();
    try {
      const raw = await readFile(absolute, 'utf8');
      const parsed = JSON.parse(raw) as Partial<PersistedState>;
      if (parsed.version === STATE_VERSION) {
        data = {
          version: STATE_VERSION,
          lastScannedBlock: parsed.lastScannedBlock ?? null,
          logChunkSize: typeof parsed.logChunkSize === 'string' ? parsed.logChunkSize : null,
          logChunkRpcUrl: typeof parsed.logChunkRpcUrl === 'string' ? parsed.logChunkRpcUrl : null,
          scanBackoffUntil: typeof parsed.scanBackoffUntil === 'number' ? parsed.scanBackoffUntil : 0,
          scanBackoffMs: typeof parsed.scanBackoffMs === 'number' ? parsed.scanBackoffMs : 0,
          sweepCursor: typeof parsed.sweepCursor === 'string' ? parsed.sweepCursor : '0',
          watchlist: Array.isArray(parsed.watchlist) ? parsed.watchlist.filter((id): id is string => typeof id === 'string') : [],
          queue: Array.isArray(parsed.queue) ? parsed.queue : [],
          settled: Array.isArray(parsed.settled) ? parsed.settled : [],
          abandoned: Array.isArray(parsed.abandoned) ? parsed.abandoned : [],
          salts: parsed.salts && typeof parsed.salts === 'object' ? parsed.salts : {},
          resolveCooldowns:
            parsed.resolveCooldowns && typeof parsed.resolveCooldowns === 'object' ? parsed.resolveCooldowns : {},
        };
      } else {
        logger.warn('state file version mismatch — starting fresh', { file: absolute, found: parsed.version });
      }
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (code !== 'ENOENT') {
        const backup = `${absolute}.corrupt-${Date.now()}`;
        await rename(absolute, backup).catch(() => undefined);
        logger.warn('state file unreadable — starting fresh (corrupt file preserved)', {
          file: absolute,
          backup,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }

    return new StateStore(absolute, lockFile, logger, data);
  }

  // ── Settlement queue ──────────────────────────────────────────────────────

  /** Returns false when the raffle is already queued or already settled. */
  enqueue(raffleId: bigint): boolean {
    const key = raffleId.toString();
    if (this.#data.settled.includes(key)) return false;
    if (this.#data.queue.some((item) => item.raffleId === key)) return false;
    this.#data.queue.push({ raffleId: key, enqueuedAt: Date.now(), attempts: 0, nextAttemptAt: 0 });
    this.#scheduleFlush();
    return true;
  }

  dueQueue(now: number = Date.now()): QueueItem[] {
    return this.#data.queue.filter((item) => item.nextAttemptAt <= now);
  }

  queueSize(): number {
    return this.#data.queue.length;
  }

  attemptsFor(raffleId: bigint): number {
    return this.#data.queue.find((item) => item.raffleId === raffleId.toString())?.attempts ?? 0;
  }

  dequeue(raffleId: bigint): void {
    const key = raffleId.toString();
    this.#data.queue = this.#data.queue.filter((item) => item.raffleId !== key);
    this.#scheduleFlush();
  }

  /** Record a failed settle attempt; returns the new attempt count. */
  bumpAttempt(raffleId: bigint, error: string, delayMs: number): number {
    const key = raffleId.toString();
    const item = this.#data.queue.find((entry) => entry.raffleId === key);
    if (!item) return 0;
    item.attempts += 1;
    item.lastError = error.slice(0, 300);
    item.nextAttemptAt = Date.now() + delayMs;
    this.#scheduleFlush();
    return item.attempts;
  }

  /** Move a permanently-failing raffle out of the active queue (kept for audit). */
  abandon(raffleId: bigint, reason: string): void {
    const key = raffleId.toString();
    this.dequeue(raffleId);
    this.#data.abandoned.push({ raffleId: key, reason: reason.slice(0, 300), at: Date.now() });
    if (this.#data.abandoned.length > MAX_ABANDONED) {
      this.#data.abandoned.splice(0, this.#data.abandoned.length - MAX_ABANDONED);
    }
    this.#scheduleFlush();
  }

  abandonedCount(): number {
    return this.#data.abandoned.length;
  }

  markSettled(raffleId: bigint): void {
    const key = raffleId.toString();
    this.#data.queue = this.#data.queue.filter((item) => item.raffleId !== key);
    if (!this.#data.settled.includes(key)) {
      this.#data.settled.push(key);
      if (this.#data.settled.length > MAX_SETTLED_CACHE) {
        this.#data.settled.splice(0, this.#data.settled.length - MAX_SETTLED_CACHE);
      }
    }
    this.#scheduleFlush();
  }

  // ── Log scan cursor ───────────────────────────────────────────────────────

  get lastScannedBlock(): bigint | null {
    return this.#data.lastScannedBlock === null ? null : BigInt(this.#data.lastScannedBlock);
  }

  setScannedBlock(block: bigint): void {
    this.#data.lastScannedBlock = block.toString();
    this.#scheduleFlush();
  }

  /**
   * Effective chunk size learned from the RPC provider's eth_getLogs range cap.
   * Persisted so the keeper does not have to rediscover (and burn requests on)
   * the cap after every restart. Null until the first successful scan.
   *
   * Scoped to the RPC URL: a cap learned from one provider is meaningless on
   * another. After a provider switch (say, from a 10-block metered key to a
   * wide-range RPC) the old value must be discarded, or the scan keeps asking
   * for the narrow range and can never catch up to the chain head.
   */
  learnedLogChunkSize(logRpcUrl: string): bigint | null {
    if (this.#data.logChunkRpcUrl !== logRpcUrl) return null;
    return this.#data.logChunkSize === null ? null : BigInt(this.#data.logChunkSize);
  }

  setLearnedLogChunkSize(logRpcUrl: string, size: bigint): void {
    if (this.#data.logChunkRpcUrl === logRpcUrl && this.#data.logChunkSize === size.toString()) return;
    this.#data.logChunkRpcUrl = logRpcUrl;
    this.#data.logChunkSize = size.toString();
    this.#scheduleFlush();
  }

  // ── Log-scan backoff (quota protection) ───────────────────────────────────

  /**
   * Epoch ms until which the fulfilled-log scan is paused. Set when a scan
   * exhausts its per-cycle request budget (i.e. the keeper is behind), so a
   * backlog cannot re-burn the full budget on every single cycle.
   */
  get scanBackoffUntil(): number {
    return this.#data.scanBackoffUntil;
  }

  get scanBackoffMs(): number {
    return this.#data.scanBackoffMs;
  }

  setScanBackoff(delayMs: number): void {
    this.#data.scanBackoffMs = delayMs;
    this.#data.scanBackoffUntil = Date.now() + delayMs;
    this.#scheduleFlush();
  }

  clearScanBackoff(): void {
    if (this.#data.scanBackoffUntil === 0 && this.#data.scanBackoffMs === 0) return;
    this.#data.scanBackoffUntil = 0;
    this.#data.scanBackoffMs = 0;
    this.#scheduleFlush();
  }

  // ── On-chain settlement sweep ─────────────────────────────────────────────

  /** Highest raffle id the forward sweep has read (0 before the first pass). */
  get sweepCursor(): bigint {
    return BigInt(this.#data.sweepCursor);
  }

  setSweepCursor(raffleId: bigint): void {
    if (this.#data.sweepCursor === raffleId.toString()) return;
    this.#data.sweepCursor = raffleId.toString();
    this.#scheduleFlush();
  }

  /**
   * Up to `limit` watched raffle ids (all of them when `limit` is omitted),
   * oldest first. The watchlist holds ids last seen OPEN/PENDING_VRF — they are
   * re-checked by the sweep because they can still transition to RESOLVED.
   */
  watchedRaffleIds(limit?: number): bigint[] {
    const ids = limit === undefined ? this.#data.watchlist : this.#data.watchlist.slice(0, Math.max(0, limit));
    return ids.map((id) => BigInt(id));
  }

  watchRaffle(raffleId: bigint): void {
    const key = raffleId.toString();
    if (this.#data.watchlist.includes(key)) return;
    this.#data.watchlist.push(key);
    if (this.#data.watchlist.length > MAX_WATCHED_RAFFLES) {
      const dropped = this.#data.watchlist.splice(0, this.#data.watchlist.length - MAX_WATCHED_RAFFLES);
      this.#logger.warn('settlement watchlist full — dropping oldest watched raffles', {
        max: MAX_WATCHED_RAFFLES,
        dropped: dropped.length,
      });
    }
    this.#scheduleFlush();
  }

  unwatchRaffle(raffleId: bigint): void {
    const key = raffleId.toString();
    const index = this.#data.watchlist.indexOf(key);
    if (index === -1) return;
    this.#data.watchlist.splice(index, 1);
    this.#scheduleFlush();
  }

  /** Rotate a still-non-terminal watched id to the back of the watchlist. */
  touchWatchedRaffle(raffleId: bigint): void {
    const key = raffleId.toString();
    const index = this.#data.watchlist.indexOf(key);
    if (index === -1 || index === this.#data.watchlist.length - 1) return;
    this.#data.watchlist.splice(index, 1);
    this.#data.watchlist.push(key);
    this.#scheduleFlush();
  }

  // ── Resolve retry cooldown ────────────────────────────────────────────────

  resolveCooldownUntil(raffleId: bigint): number {
    return this.#data.resolveCooldowns[raffleId.toString()] ?? 0;
  }

  setResolveCooldown(raffleId: bigint, delayMs: number): void {
    this.#pruneResolveCooldowns();
    this.#data.resolveCooldowns[raffleId.toString()] = Date.now() + delayMs;
    this.#scheduleFlush();
  }

  clearResolveCooldown(raffleId: bigint): void {
    const key = raffleId.toString();
    if (this.#data.resolveCooldowns[key] === undefined) return;
    delete this.#data.resolveCooldowns[key];
    this.#scheduleFlush();
  }

  #pruneResolveCooldowns(): void {
    const keys = Object.keys(this.#data.resolveCooldowns);
    if (keys.length < MAX_RESOLVE_COOLDOWNS) return;
    const now = Date.now();
    for (const key of keys) {
      if ((this.#data.resolveCooldowns[key] ?? 0) <= now) delete this.#data.resolveCooldowns[key];
    }
  }

  // ── Salt registry (SaltStorage) ───────────────────────────────────────────

  hasSalt(raffleId: string, salt: string): boolean {
    return this.#data.salts[raffleId]?.includes(salt) ?? false;
  }

  rememberSalt(raffleId: string, salt: string): void {
    const existing = this.#data.salts[raffleId] ?? [];
    existing.push(salt);
    if (existing.length > MAX_SALTS_PER_RAFFLE) {
      existing.splice(0, existing.length - MAX_SALTS_PER_RAFFLE);
    }
    this.#data.salts[raffleId] = existing;
    this.#scheduleFlush();
  }

  // ── Stats / persistence ───────────────────────────────────────────────────

  stats(): Record<string, number> {
    return {
      queue: this.#data.queue.length,
      settledCache: this.#data.settled.length,
      abandoned: this.#data.abandoned.length,
      watching: this.#data.watchlist.length,
      trackedRafflesWithSalts: Object.keys(this.#data.salts).length,
    };
  }

  #scheduleFlush(): void {
    if (this.#closed || this.#flushTimer !== undefined) return;
    this.#flushTimer = setTimeout(() => {
      this.#flushTimer = undefined;
      void this.flush().catch((error) => {
        this.#logger.error('state flush failed', { error: error instanceof Error ? error.message : String(error) });
      });
    }, FLUSH_DEBOUNCE_MS);
  }

  async flush(): Promise<void> {
    if (this.#flushTimer !== undefined) {
      clearTimeout(this.#flushTimer);
      this.#flushTimer = undefined;
    }
    const snapshot = JSON.stringify(this.#data);
    this.#writeChain = this.#writeChain.then(async () => {
      const tmp = `${this.#file}.tmp`;
      await writeFile(tmp, snapshot, 'utf8');
      await rename(tmp, this.#file);
    });
    return this.#writeChain;
  }

  async close(): Promise<void> {
    this.#closed = true;
    if (this.#flushTimer !== undefined) {
      clearTimeout(this.#flushTimer);
      this.#flushTimer = undefined;
    }
    await this.flush().catch(() => undefined);
    await unlink(this.#lockFile).catch(() => undefined);
  }
}

async function acquireLock(lockFile: string, logger: Logger): Promise<void> {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const handle = await openFile(lockFile, 'wx');
      await handle.writeFile(JSON.stringify({ pid: process.pid, startedAt: new Date().toISOString() }));
      await handle.close();
      return;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error;
      if (await isStaleLock(lockFile)) {
        logger.warn('removing stale state lock', { lockFile });
        await unlink(lockFile).catch(() => undefined);
        continue;
      }
      throw new Error(
        `another keeper instance holds the state lock (${lockFile}); ` +
          'run a single instance per state file or remove the lock if the previous process died',
      );
    }
  }
  throw new Error(`could not acquire state lock ${lockFile}`);
}

async function isStaleLock(lockFile: string): Promise<boolean> {
  try {
    const raw = await readFile(lockFile, 'utf8');
    const pid = Number((JSON.parse(raw) as { pid?: number }).pid);
    if (!Number.isInteger(pid) || pid <= 0) return true;
    try {
      process.kill(pid, 0);
      return false;
    } catch (error) {
      // EPERM = process exists but is owned by someone else -> still alive.
      return (error as NodeJS.ErrnoException).code !== 'EPERM';
    }
  } catch {
    return true;
  }
}
