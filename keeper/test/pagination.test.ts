import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { Logger } from '../src/logger.ts';
import { scanPages, type Page } from '../src/pagination.ts';

interface RecordedWarn {
  message: string;
  fields?: Record<string, unknown>;
}

function stubLogger(warnings: RecordedWarn[]): Logger {
  const logger: Logger = {
    debug: () => undefined,
    info: () => undefined,
    warn: (message, fields) => {
      warnings.push({ message, fields: fields as Record<string, unknown> | undefined });
    },
    error: () => undefined,
    child: () => logger,
  };
  return logger;
}

test('walks pages until a zero nextCursor and gathers all ids', async () => {
  const pages: Page[] = [
    { ids: [1n, 2n], nextCursor: 2n },
    { ids: [3n], nextCursor: 0n },
  ];
  const seen: bigint[] = [];
  const warnings: RecordedWarn[] = [];
  let calls = 0;

  const outcome = await scanPages(
    async () => {
      const page = pages[calls];
      calls += 1;
      assert.ok(page, 'scan called more times than expected');
      return page;
    },
    {
      limit: 2n,
      maxPages: 10,
      scanName: 'pendingResolution',
      logger: stubLogger(warnings),
      onPage: async (ids) => {
        seen.push(...ids);
      },
    },
  );

  assert.deepEqual(seen, [1n, 2n, 3n]);
  assert.deepEqual(outcome, { pages: 2, ids: 3 });
  assert.equal(calls, 2);
  assert.equal(warnings.length, 0);
});

test('an empty first page terminates without calling onPage', async () => {
  let called = false;
  const outcome = await scanPages(
    async () => ({ ids: [], nextCursor: 0n }),
    {
      limit: 50n,
      maxPages: 10,
      scanName: 'pendingResolution',
      logger: stubLogger([]),
      onPage: async () => {
        called = true;
      },
    },
  );

  assert.equal(called, false);
  assert.deepEqual(outcome, { pages: 1, ids: 0 });
});

test('a non-advancing cursor aborts the sweep instead of looping forever', async () => {
  const warnings: RecordedWarn[] = [];
  let calls = 0;
  const outcome = await scanPages(
    async () => {
      calls += 1;
      // First call advances 0 -> 5, second call returns the same cursor.
      return calls === 1 ? { ids: [1n], nextCursor: 5n } : { ids: [2n], nextCursor: 5n };
    },
    {
      limit: 1n,
      maxPages: 100,
      scanName: 'stalledRaffles',
      logger: stubLogger(warnings),
      onPage: async () => undefined,
    },
  );

  assert.equal(calls, 2);
  assert.deepEqual(outcome, { pages: 2, ids: 2 });
  assert.equal(warnings.length, 1);
  assert.match(warnings[0]!.message, /cursor did not advance/);
});

test('maxPages bounds a single sweep when the cursor keeps advancing', async () => {
  const warnings: RecordedWarn[] = [];
  const outcome = await scanPages(
    async (scanCursor) => ({ ids: [scanCursor], nextCursor: scanCursor + 1n }),
    {
      limit: 1n,
      maxPages: 3,
      scanName: 'pendingResolution',
      logger: stubLogger(warnings),
      onPage: async () => undefined,
    },
  );

  assert.equal(outcome.pages, 3);
  assert.equal(outcome.ids, 3);
  assert.equal(warnings.length, 1);
  assert.match(warnings[0]!.message, /max scan passes/);
});
