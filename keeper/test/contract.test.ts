import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { PublicClient } from 'viem';
import { getRaffleView, getResolutionStateView } from '../src/contract.ts';

const CONTRACT = '0x8706B510B2E1FbfCF3B0Bcb0681A62d37724E37B';

function clientReturning(value: unknown): PublicClient {
  return { readContract: async () => value } as unknown as PublicClient;
}

// Regression: viem decodes ABI integers narrower than 128 bits as JS numbers,
// but the view interfaces declare them as bigint. Adding such a field to a
// bigint constant (e.g. `expiry + HARD_DEADLINE`) throws
// "Cannot mix BigInt and other types, use explicit conversions" and crashed
// every resolve cycle that saw a stalled raffle.

test('getRaffleView coerces uint48 expiry and uint96 ticketsSold to bigint', async () => {
  const client = clientReturning({
    host: CONTRACT,
    expiry: 1_700_000_000,
    status: 4,
    underfilled: false,
    prizeType: 0,
    prizeAsset: CONTRACT,
    ticketsSold: 1_000,
    prizeAmountOrTokenId: 5n,
    ticketPrice: 1n,
    maxCap: 10n,
  });

  const raffle = await getRaffleView(client, CONTRACT, 1n);

  assert.equal(typeof raffle.expiry, 'bigint');
  assert.equal(typeof raffle.ticketsSold, 'bigint');
  assert.equal(raffle.expiry, 1_700_000_000n);
  assert.equal(raffle.ticketsSold, 1_000n);
  assert.equal(raffle.expiry + 86_400n, 1_700_086_400n);
});

test('getResolutionStateView coerces uint64 and uint48 fields to bigint', async () => {
  const client = clientReturning({
    status: 1,
    attempts: 2,
    activeProviderAddr: CONTRACT,
    activeSequence: 7,
    lastRequestedAt: 1_700_000_000,
    underfilled: false,
    prizeDisposedFlag: false,
  });

  const state = await getResolutionStateView(client, CONTRACT, 1n);

  assert.equal(typeof state.activeSequence, 'bigint');
  assert.equal(typeof state.lastRequestedAt, 'bigint');
  assert.equal(state.activeSequence, 7n);
  assert.equal(state.lastRequestedAt + 60n, 1_700_000_060n);
});
