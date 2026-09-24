import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import type { Logger } from '../src/logger.ts';
import { StateStore } from '../src/state.ts';

function silentLogger(): Logger {
  const logger: Logger = {
    debug: () => undefined,
    info: () => undefined,
    warn: () => undefined,
    error: () => undefined,
    child: () => logger,
  };
  return logger;
}

// Regression: the chunk size learned from one provider's eth_getLogs cap was
// persisted globally, so after switching to a wide-range RPC the keeper kept
// asking for the old (10-block) range and could never catch up to the head.
test('learned log chunk size is scoped to the RPC it was learned from', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'winr-keeper-state-'));
  const file = join(dir, 'keeper-state.json');

  const first = await StateStore.open(file, silentLogger());
  try {
    assert.equal(first.learnedLogChunkSize('https://metered.example'), null);
    first.setLearnedLogChunkSize('https://metered.example', 10n);
    assert.equal(first.learnedLogChunkSize('https://metered.example'), 10n);
    assert.equal(first.learnedLogChunkSize('https://wide-range.example'), null);
    await first.flush();
  } finally {
    await first.close();
  }

  const reopened = await StateStore.open(file, silentLogger());
  try {
    assert.equal(reopened.learnedLogChunkSize('https://metered.example'), 10n);
    assert.equal(reopened.learnedLogChunkSize('https://wide-range.example'), null);
    reopened.setLearnedLogChunkSize('https://wide-range.example', 5_000n);
    assert.equal(reopened.learnedLogChunkSize('https://wide-range.example'), 5_000n);
    assert.equal(reopened.learnedLogChunkSize('https://metered.example'), null);
  } finally {
    await reopened.close();
    await rm(dir, { recursive: true, force: true });
  }
});

// The on-chain settlement sweep must survive restarts, otherwise a keeper
// redeploy would rescan every raffle from id 1 (or, worse, skip the ids it had
// already walked past).
test('on-chain sweep cursor and watchlist persist across restarts', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'winr-keeper-state-'));
  const file = join(dir, 'keeper-state.json');

  const first = await StateStore.open(file, silentLogger());
  try {
    assert.equal(first.sweepCursor, 0n);
    first.setSweepCursor(7n);
    first.watchRaffle(3n);
    first.watchRaffle(5n);
    first.watchRaffle(3n); // dedup
    first.touchWatchedRaffle(3n); // rotate to back
    await first.flush();
    assert.deepEqual(first.watchedRaffleIds(), [5n, 3n]);
  } finally {
    await first.close();
  }

  const reopened = await StateStore.open(file, silentLogger());
  try {
    assert.equal(reopened.sweepCursor, 7n);
    assert.deepEqual(reopened.watchedRaffleIds(), [5n, 3n]);
    reopened.unwatchRaffle(5n);
    assert.deepEqual(reopened.watchedRaffleIds(), [3n]);
    assert.equal(reopened.stats().watching, 1);
  } finally {
    await reopened.close();
    await rm(dir, { recursive: true, force: true });
  }
});
