import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { Logger } from '../src/logger.ts';
import { isBlockRangeOrCapError, parseMaxBlockRange, scanLogsAdaptive } from '../src/logs.ts';

const ALCHEMY_RANGE_ERROR =
  'JSON is not a valid request object.\n\nURL: https://robinhood-testnet.g.alchemy.com/v2/***\n' +
  'Request body: {"method":"eth_getLogs","params":[{"address":"0x95d2","topics":["0x82"],"fromBlock":"0x70237a6","toBlock":"0x7024b2d"}]}\n\n' +
  'Details: Under the Free tier plan, you can make eth_getLogs requests with up to a 10 block range. ' +
  'Based on your parameters, this block range should work: [0x70237a6, 0x70237af]. ' +
  'Upgrade to PAYG for expanded block range.\nVersion: viem@2.56.3';

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

test('parseMaxBlockRange reads the Alchemy suggestion from the echoed bracket range', () => {
  assert.equal(parseMaxBlockRange(ALCHEMY_RANGE_ERROR), 10n);
});

test('parseMaxBlockRange falls back to the prose block-range limit', () => {
  assert.equal(parseMaxBlockRange('you can make eth_getLogs requests with up to a 5 block range'), 5n);
  assert.equal(parseMaxBlockRange('maximum block range: 1000'), 1000n);
  assert.equal(parseMaxBlockRange('no range info here'), undefined);
});

test('isBlockRangeOrCapError classifies range caps but not contract reverts', () => {
  assert.equal(isBlockRangeOrCapError(new Error(ALCHEMY_RANGE_ERROR)), true);
  assert.equal(isBlockRangeOrCapError(new Error('query returned more than 10000 results')), true);
  assert.equal(isBlockRangeOrCapError(new Error('execution reverted: RaffleNotResolved')), false);
});

test('adaptive scan shrinks the chunk to the provider cap and completes the range', async () => {
  const calls: Array<{ from: bigint; to: bigint }> = [];
  const checkpoints: bigint[] = [];

  const result = await scanLogsAdaptive<number>({
    fromBlock: 0n,
    toBlock: 24n,
    chunkSize: 100n,
    maxRequests: 100,
    logger: silentLogger(),
    fetchChunk: async (from, to) => {
      calls.push({ from, to });
      if (to - from + 1n > 10n) throw new Error(ALCHEMY_RANGE_ERROR);
      return [1];
    },
    onLogs: async () => undefined,
    onCheckpoint: async (block) => {
      checkpoints.push(block);
    },
  });

  assert.equal(result.chunkSize, 10n);
  assert.equal(result.lastScannedBlock, 24n);
  assert.equal(result.logsSeen, 3);
  assert.equal(result.budgetExhausted, false);
  // First call is the rejected 0..24 probe, then 10-block chunks: 0-9, 10-19, 20-24.
  assert.deepEqual(calls, [
    { from: 0n, to: 24n },
    { from: 0n, to: 9n },
    { from: 10n, to: 19n },
    { from: 20n, to: 24n },
  ]);
  assert.deepEqual(checkpoints, [9n, 19n, 24n]);
});

test('adaptive scan stops at the per-cycle request budget and resumes later', async () => {
  const result = await scanLogsAdaptive<number>({
    fromBlock: 0n,
    toBlock: 99n,
    chunkSize: 10n,
    maxRequests: 2,
    logger: silentLogger(),
    fetchChunk: async () => [1],
    onLogs: async () => undefined,
    onCheckpoint: async () => undefined,
  });

  assert.equal(result.requests, 2);
  assert.equal(result.lastScannedBlock, 19n);
  assert.equal(result.budgetExhausted, true);
});

test('adaptive scan surfaces an error it cannot shrink away from', async () => {
  await assert.rejects(
    () =>
      scanLogsAdaptive<number>({
        fromBlock: 0n,
        toBlock: 10n,
        chunkSize: 1n,
        maxRequests: 100,
        logger: silentLogger(),
        fetchChunk: async () => {
          throw new Error(ALCHEMY_RANGE_ERROR);
        },
        onLogs: async () => undefined,
        onCheckpoint: async () => undefined,
      }),
    /eth_getLogs/,
  );
});

test('adaptive scan does not swallow non-range errors', async () => {
  await assert.rejects(
    () =>
      scanLogsAdaptive<number>({
        fromBlock: 0n,
        toBlock: 10n,
        chunkSize: 100n,
        maxRequests: 100,
        logger: silentLogger(),
        fetchChunk: async () => {
          throw new Error('socket hang up');
        },
        onLogs: async () => undefined,
        onCheckpoint: async () => undefined,
      }),
    /socket hang up/,
  );
});
