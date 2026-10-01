import type { Logger } from './logger.ts';

export interface Page {
  ids: readonly bigint[];
  nextCursor: bigint;
}

export interface ScanOptions {
  limit: bigint;
  maxPages: number;
  scanName: string;
  logger: Logger;
  onPage: (ids: readonly bigint[], pageNumber: number) => Promise<void>;
}

export interface ScanOutcome {
  pages: number;
  ids: number;
}

/**
 * Drive the contract's cursor pagination
 * (`pendingResolution` / `stalledRaffles`) to completion:
 *  - `nextCursor === 0` means the scan wrapped past raffleCount — done.
 *  - a non-advancing cursor (nextCursor <= cursor) aborts instead of looping.
 *  - `maxPages` bounds a single sweep; the next cron run restarts from 0.
 */
export async function scanPages(
  scan: (cursor: bigint, limit: bigint) => Promise<Page>,
  options: ScanOptions,
): Promise<ScanOutcome> {
  let cursor = 0n;
  let pages = 0;
  let totalIds = 0;

  for (;;) {
    const { ids, nextCursor } = await scan(cursor, options.limit);
    pages += 1;
    totalIds += ids.length;
    if (ids.length > 0) {
      await options.onPage(ids, pages);
    }

    if (nextCursor === 0n) return { pages, ids: totalIds };

    if (nextCursor <= cursor) {
      options.logger.warn(`${options.scanName}: cursor did not advance — aborting sweep`, {
        cursor: cursor.toString(),
        nextCursor: nextCursor.toString(),
      });
      return { pages, ids: totalIds };
    }

    if (pages >= options.maxPages) {
      options.logger.warn(`${options.scanName}: max scan passes reached — remaining raffles handled next cycle`, {
        pages,
        maxPages: options.maxPages,
        nextCursor: nextCursor.toString(),
      });
      return { pages, ids: totalIds };
    }

    cursor = nextCursor;
  }
}
