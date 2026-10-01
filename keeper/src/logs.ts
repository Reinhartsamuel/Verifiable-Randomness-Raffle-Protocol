import type { Logger } from './logger.ts';

/**
 * Adaptive `eth_getLogs` range scanner.
 *
 * Managed RPC providers cap the block span of a single `eth_getLogs` call
 * (Alchemy's free tier, for example, allows only 10 blocks). A fixed chunk size
 * configured for one provider therefore makes every scan fail on another, and
 * because a failed first chunk never advances the cursor the keeper retries the
 * same oversized request forever — burning the daily compute-unit quota without
 * ever making progress.
 *
 * This scanner reacts to the provider's own error message: it reads the allowed
 * range (or the suggested range the provider echoes back), shrinks the chunk and
 * retries the same span. It checkpoints after every successful chunk so a crash
 * or a per-cycle budget cap resumes exactly where it stopped, and it persists
 * the learned chunk size so the probe only has to happen once.
 */

const BRACKET_RANGE_RE = /\[\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*\]/;
const RANGE_LENGTH_PATTERNS: readonly RegExp[] = [
  /up to (?:a |an )?(\d+)[ -]?block range/i,
  /maximum (?:allowed )?(?:block )?range[^0-9]*(\d+)/i,
  /(?:block )?range (?:limit|max(?:imum)?)[^0-9]*(\d+)/i,
];

const RANGE_OR_CAP_ERROR_RE =
  /block range|range (?:is )?(?:too (?:large|wide|broad)|exceeds?)|query returned more than|more than \d+ (?:results|logs)|response size exceeded|too many logs|exceeds? the (?:maximum|allowed)/i;

function errorText(error: unknown): string {
  if (error instanceof Error) return `${error.name}: ${error.message}`;
  return String(error);
}

/**
 * Parse the maximum number of blocks a provider allows in one `eth_getLogs`
 * call. Prefers the concrete `[from, to]` suggestion some providers (Alchemy)
 * include, then falls back to prose like "up to a 10 block range".
 */
export function parseMaxBlockRange(message: string): bigint | undefined {
  const bracket = BRACKET_RANGE_RE.exec(message);
  if (bracket?.[1] !== undefined && bracket[2] !== undefined) {
    const from = BigInt(bracket[1]);
    const to = BigInt(bracket[2]);
    if (to >= from) return to - from + 1n;
  }

  for (const pattern of RANGE_LENGTH_PATTERNS) {
    const match = pattern.exec(message);
    const captured = match?.[1];
    if (captured !== undefined) {
      const value = BigInt(captured);
      if (value >= 1n) return value;
    }
  }
  return undefined;
}

/** True when the error is the provider refusing the requested block span / log volume. */
export function isBlockRangeOrCapError(error: unknown): boolean {
  return RANGE_OR_CAP_ERROR_RE.test(errorText(error));
}

function shrinkChunk(
  error: unknown,
  chunk: bigint,
  minChunk: bigint,
  fromBlock: bigint,
  toBlock: bigint,
): bigint | undefined {
  if (!isBlockRangeOrCapError(error)) return undefined;

  const span = toBlock - fromBlock + 1n;
  const suggested = parseMaxBlockRange(errorText(error));
  let next = suggested !== undefined && suggested >= 1n && suggested < span ? suggested : chunk / 2n;
  if (next >= chunk) next = chunk / 2n;
  if (next < minChunk) next = minChunk;
  // Cannot make progress: the error is not a range cap (or the provider rejects
  // even a single block), so let the caller surface it instead of looping.
  if (next >= chunk) return undefined;
  return next;
}

export interface AdaptiveLogScanOptions<TLog> {
  fromBlock: bigint;
  toBlock: bigint;
  /** Starting span. Must be > 0. */
  chunkSize: bigint;
  /** Hard cap on RPC calls per scan; protects the daily quota. Default 1000. */
  maxRequests?: number;
  /** Smallest span the scanner may fall back to. Default 1. */
  minChunkSize?: bigint;
  logger: Logger;
  fetchChunk: (fromBlock: bigint, toBlock: bigint) => Promise<readonly TLog[]>;
  onLogs: (logs: readonly TLog[], fromBlock: bigint, toBlock: bigint) => Promise<void>;
  /** Persist progress (and the effective chunk size) after each successful chunk. */
  onCheckpoint: (lastScannedBlock: bigint, chunkSize: bigint) => Promise<void>;
}

export interface AdaptiveLogScanResult {
  logsSeen: number;
  requests: number;
  /** Effective chunk size after any provider-driven shrinking. */
  chunkSize: bigint;
  /** Highest block successfully scanned, or null when nothing was scanned. */
  lastScannedBlock: bigint | null;
  /** True when the per-cycle request budget stopped the scan early. */
  budgetExhausted: boolean;
}

export async function scanLogsAdaptive<TLog>(
  options: AdaptiveLogScanOptions<TLog>,
): Promise<AdaptiveLogScanResult> {
  const minChunk = options.minChunkSize !== undefined && options.minChunkSize > 0n ? options.minChunkSize : 1n;
  const maxRequests = options.maxRequests ?? 1_000;
  let chunk = options.chunkSize > 0n ? options.chunkSize : minChunk;
  let cursor = options.fromBlock;
  let requests = 0;
  let logsSeen = 0;
  let lastScannedBlock: bigint | null = null;
  let budgetExhausted = false;

  while (cursor <= options.toBlock) {
    if (requests >= maxRequests) {
      budgetExhausted = true;
      break;
    }

    const end = cursor + chunk - 1n > options.toBlock ? options.toBlock : cursor + chunk - 1n;
    requests += 1;

    let logs: readonly TLog[];
    try {
      logs = await options.fetchChunk(cursor, end);
    } catch (error) {
      const narrowed = shrinkChunk(error, chunk, minChunk, cursor, end);
      if (narrowed === undefined) throw error;
      options.logger.warn('eth_getLogs span rejected by RPC — shrinking chunk and retrying', {
        fromBlock: cursor.toString(),
        toBlock: end.toString(),
        previousChunkSize: chunk.toString(),
        chunkSize: narrowed.toString(),
      });
      chunk = narrowed;
      continue;
    }

    logsSeen += logs.length;
    if (logs.length > 0) await options.onLogs(logs, cursor, end);
    lastScannedBlock = end;
    await options.onCheckpoint(end, chunk);
    cursor = end + 1n;
  }

  return { logsSeen, requests, chunkSize: chunk, lastScannedBlock, budgetExhausted };
}
