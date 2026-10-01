import assert from 'node:assert/strict';
import { test } from 'node:test';
import { decodeError, isTransientError } from '../src/errors.ts';

test('classifies common transient RPC / nonce failures', () => {
  assert.equal(isTransientError(new Error('HTTP request failed. Status: 429')), true);
  assert.equal(isTransientError(new Error('nonce too low: next nonce 5, current nonce 6')), true);
  assert.equal(isTransientError(new Error('replacement transaction underpriced')), true);
  assert.equal(isTransientError(new Error('fetch failed')), true);
  assert.equal(isTransientError(new Error('connect ETIMEDOUT 1.2.3.4:443')), true);
});

test('does not classify contract reverts or funding failures as transient', () => {
  assert.equal(isTransientError(new Error('execution reverted: NotResolver(0xabc)')), false);
  assert.equal(isTransientError(new Error('insufficient funds for gas * price + value')), false);
});

test('decodeError falls back to the message for non-viem errors', () => {
  const decoded = decodeError(new Error('boom'));
  assert.equal(decoded.name, undefined);
  assert.equal(decoded.shortMessage, 'boom');
  assert.equal(decoded.message, 'boom');
});

test('decodeError handles non-Error throwables', () => {
  const decoded = decodeError('plain string failure');
  assert.equal(decoded.shortMessage, 'plain string failure');
});
