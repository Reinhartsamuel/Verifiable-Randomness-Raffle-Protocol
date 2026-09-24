import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { Logger } from '../src/logger.ts';
import { sweepForResolvedRaffles, type SweepState } from '../src/sweep.ts';
import { RaffleStatus } from '../src/types.ts';

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

class FakeState implements SweepState {
  cursor = 0n;
  watch: string[] = [];

  constructor(cursor = 0n, watch: string[] = []) {
    this.cursor = cursor;
    this.watch = [...watch];
  }

  get sweepCursor(): bigint {
    return this.cursor;
  }

  setSweepCursor(raffleId: bigint): void {
    this.cursor = raffleId;
  }

  watchedRaffleIds(limit?: number): bigint[] {
    const ids = limit === undefined ? this.watch : this.watch.slice(0, Math.max(0, limit));
    return ids.map((id) => BigInt(id));
  }

  watchRaffle(raffleId: bigint): void {
    const key = raffleId.toString();
    if (!this.watch.includes(key)) this.watch.push(key);
  }

  unwatchRaffle(raffleId: bigint): void {
    this.watch = this.watch.filter((id) => id !== raffleId.toString());
  }

  touchWatchedRaffle(raffleId: bigint): void {
    const key = raffleId.toString();
    const index = this.watch.indexOf(key);
    if (index === -1 || index === this.watch.length - 1) return;
    this.watch.splice(index, 1);
    this.watch.push(key);
  }
}

function statusReader(statuses: Record<string, number>, calls: string[] = []): (raffleId: bigint) => Promise<number> {
  return async (raffleId: bigint) => {
    const key = raffleId.toString();
    calls.push(key);
    const status = statuses[key];
    if (status === undefined) throw new Error(`no status for ${key}`);
    return status;
  };
}

test('forward pass enqueues RESOLVED, watches non-terminal and skips terminal raffles', async () => {
  const state = new FakeState();
  const statuses = {
    '1': RaffleStatus.OPEN,
    '2': RaffleStatus.PENDING_VRF,
    '3': RaffleStatus.RESOLVED,
    '4': RaffleStatus.COMPLETED,
    '5': RaffleStatus.CANCELLED,
  };
  const resolved: string[] = [];

  const result = await sweepForResolvedRaffles({
    raffleCount: 5n,
    batchSize: 10,
    watchBatchSize: 10,
    state,
    readStatus: statusReader(statuses),
    onResolved: (id) => resolved.push(id.toString()),
    logger: silentLogger(),
  });

  assert.deepEqual(resolved, ['3']);
  assert.equal(result.scanned, 5);
  assert.equal(result.resolved, 1);
  assert.equal(result.watching, 2);
  assert.equal(result.moreToScan, false);
  assert.equal(state.sweepCursor, 5n);
  assert.deepEqual(state.watch, ['1', '2']);
});

test('watch pass enqueues a raffle that resolved after it was first seen', async () => {
  const state = new FakeState(2n, ['1', '2']);
  const statuses = { '1': RaffleStatus.RESOLVED, '2': RaffleStatus.OPEN };
  const resolved: string[] = [];

  const result = await sweepForResolvedRaffles({
    raffleCount: 2n,
    batchSize: 10,
    watchBatchSize: 10,
    state,
    readStatus: statusReader(statuses),
    onResolved: (id) => resolved.push(id.toString()),
    logger: silentLogger(),
  });

  assert.deepEqual(resolved, ['1']);
  assert.deepEqual(state.watch, ['2']);
  assert.equal(result.resolved, 1);
  assert.equal(result.watching, 1);
  // No forward ids left, so only the two watched ids were read.
  assert.equal(result.scanned, 2);
});

test('drops watched raffles that reached a terminal state', async () => {
  const state = new FakeState(2n, ['1', '2']);
  const statuses = { '1': RaffleStatus.COMPLETED, '2': RaffleStatus.CANCELLED };
  const resolved: string[] = [];

  const result = await sweepForResolvedRaffles({
    raffleCount: 2n,
    batchSize: 10,
    watchBatchSize: 10,
    state,
    readStatus: statusReader(statuses),
    onResolved: (id) => resolved.push(id.toString()),
    logger: silentLogger(),
  });

  assert.deepEqual(resolved, []);
  assert.deepEqual(state.watch, []);
  assert.equal(result.watching, 0);
});

test('does not advance the cursor past an unreadable raffle and resumes next cycle', async () => {
  const state = new FakeState();
  const statuses: Record<string, number> = { '1': RaffleStatus.OPEN, '3': RaffleStatus.RESOLVED };
  const resolved: string[] = [];

  const first = await sweepForResolvedRaffles({
    raffleCount: 3n,
    batchSize: 10,
    watchBatchSize: 10,
    state,
    readStatus: statusReader(statuses),
    onResolved: (id) => resolved.push(id.toString()),
    logger: silentLogger(),
  });

  assert.equal(first.scanned, 1);
  assert.equal(state.sweepCursor, 1n);
  assert.equal(first.moreToScan, true);

  // The RPC recovers; the same cycle resumes exactly at id 2 (now readable).
  statuses['2'] = RaffleStatus.RESOLVED;
  const second = await sweepForResolvedRaffles({
    raffleCount: 3n,
    batchSize: 10,
    watchBatchSize: 10,
    state,
    readStatus: statusReader(statuses),
    onResolved: (id) => resolved.push(id.toString()),
    logger: silentLogger(),
  });

  assert.equal(second.moreToScan, false);
  assert.equal(state.sweepCursor, 3n);
  assert.deepEqual(resolved, ['2', '3']);
});

test('bounds the forward pass by the batch size', async () => {
  const state = new FakeState();
  const statuses: Record<string, number> = Object.fromEntries(
    Array.from({ length: 10 }, (_, i) => [String(i + 1), RaffleStatus.OPEN]),
  );

  const result = await sweepForResolvedRaffles({
    raffleCount: 10n,
    batchSize: 3,
    watchBatchSize: 3,
    state,
    readStatus: statusReader(statuses),
    onResolved: () => undefined,
    logger: silentLogger(),
  });

  assert.equal(result.scanned, 3);
  assert.equal(state.sweepCursor, 3n);
  assert.equal(result.moreToScan, true);
});

test('cold start checks the most recent raffles before backfilling older ids', async () => {
  const state = new FakeState();
  const statuses = { '1': RaffleStatus.OPEN, '2': RaffleStatus.OPEN, '4': RaffleStatus.RESOLVED, '5': RaffleStatus.OPEN };
  const resolved: string[] = [];

  const result = await sweepForResolvedRaffles({
    raffleCount: 5n,
    batchSize: 2,
    watchBatchSize: 2,
    recentLookback: 2,
    state,
    readStatus: statusReader(statuses),
    onResolved: (id) => resolved.push(id.toString()),
    logger: silentLogger(),
  });

  // The seeded tail (4,5) is checked even though the forward cursor only reached 2.
  assert.deepEqual(resolved, ['4']);
  assert.equal(state.sweepCursor, 2n);
  assert.deepEqual(state.watch, ['1', '2', '5']);
  assert.equal(result.moreToScan, true);
});

test('rotates the watchlist so a large backlog is checked in bounded slices', async () => {
  const state = new FakeState(3n, ['1', '2', '3']);
  const statuses = { '1': RaffleStatus.OPEN, '2': RaffleStatus.OPEN, '3': RaffleStatus.OPEN };
  const calls: string[] = [];

  await sweepForResolvedRaffles({
    raffleCount: 3n,
    batchSize: 10,
    watchBatchSize: 1,
    state,
    readStatus: statusReader(statuses, calls),
    onResolved: () => undefined,
    logger: silentLogger(),
  });

  assert.deepEqual(calls, ['1']);
  assert.deepEqual(state.watch, ['2', '3', '1']);
});
