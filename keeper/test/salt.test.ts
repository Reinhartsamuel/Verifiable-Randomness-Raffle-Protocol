import assert from 'node:assert/strict';
import { test } from 'node:test';
import { SaltGenerator, ZERO_SALT, type SaltStorage } from '../src/salt.ts';

class MemoryStorage implements SaltStorage {
  readonly salts = new Map<string, Set<string>>();

  hasSalt(raffleId: string, salt: string): boolean {
    return this.salts.get(raffleId)?.has(salt) ?? false;
  }

  rememberSalt(raffleId: string, salt: string): void {
    const set = this.salts.get(raffleId) ?? new Set<string>();
    set.add(salt);
    this.salts.set(raffleId, set);
  }
}

test('salt is 0x + 64 hex chars (32 bytes, 66 total)', () => {
  const generator = new SaltGenerator(new MemoryStorage());
  const salt = generator.generate(1n);
  assert.match(salt, /^0x[0-9a-f]{64}$/);
  assert.equal(salt.length, 66);
});

test('salts are unique across generations and remembered per raffle', () => {
  const storage = new MemoryStorage();
  const generator = new SaltGenerator(storage);
  const salts = new Set<string>();
  for (let i = 0; i < 1_000; i += 1) {
    const salt = generator.generate(BigInt(1 + (i % 3)));
    assert.equal(salts.has(salt), false, 'CSPRNG produced a duplicate salt');
    salts.add(salt);
  }
  assert.equal(salts.size, 1_000);
  assert.equal(storage.salts.size, 3);
});

test('zero salt from the entropy source is rejected and regenerated', () => {
  let calls = 0;
  const valid = Buffer.from('ab'.repeat(32), 'hex');
  const generator = new SaltGenerator(new MemoryStorage(), {
    entropy: () => {
      calls += 1;
      return calls <= 2 ? Buffer.alloc(32, 0) : valid;
    },
  });

  const salt = generator.generate(7n);
  assert.equal(salt, `0x${valid.toString('hex')}`);
  assert.notEqual(salt, ZERO_SALT);
  assert.equal(calls, 3);
});

test('a salt already known to storage is not reused', () => {
  const storage = new MemoryStorage();
  const first = Buffer.from('01'.repeat(32), 'hex');
  const second = Buffer.from('02'.repeat(32), 'hex');
  storage.rememberSalt('5', `0x${first.toString('hex')}`);

  let calls = 0;
  const generator = new SaltGenerator(storage, {
    entropy: () => {
      calls += 1;
      return calls === 1 ? first : second;
    },
  });

  const salt = generator.generate(5n);
  assert.equal(salt, `0x${second.toString('hex')}`);
  assert.equal(calls, 2);
});
