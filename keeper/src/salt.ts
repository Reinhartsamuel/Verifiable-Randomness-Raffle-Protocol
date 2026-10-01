import { randomBytes } from 'node:crypto';
import type { Hex } from 'viem';

export const ZERO_SALT: Hex = `0x${'00'.repeat(32)}`;
const MAX_GENERATION_ATTEMPTS = 16;

export interface SaltStorage {
  hasSalt(raffleId: string, salt: string): boolean;
  rememberSalt(raffleId: string, salt: string): void;
}

export interface SaltGeneratorOptions {
  /** Injectable entropy source for tests; defaults to node:crypto CSPRNG. */
  entropy?: () => Buffer;
}

/**
 * Generates fresh 32-byte CSPRNG salts for resolveRaffle/retryResolve and keeps
 * a per-raffle registry so a value we already handed out is never handed out
 * again. The contract additionally gates replay with `usedSalt` (SaltAlreadyUsed)
 * and rejects the zero salt (SaltZero).
 *
 * Salts are secret until the request tx lands: callers must never log or return
 * them. This module exposes no logging.
 */
export class SaltGenerator {
  readonly #storage: SaltStorage;
  readonly #entropy: () => Buffer;

  constructor(storage: SaltStorage, options?: SaltGeneratorOptions) {
    this.#storage = storage;
    this.#entropy = options?.entropy ?? (() => randomBytes(32));
  }

  generate(raffleId: bigint): Hex {
    const key = raffleId.toString();
    for (let attempt = 0; attempt < MAX_GENERATION_ATTEMPTS; attempt += 1) {
      const bytes = this.#entropy();
      if (bytes.length !== 32) {
        throw new Error(`salt entropy source returned ${bytes.length} bytes, expected 32`);
      }
      const salt = `0x${bytes.toString('hex')}` as Hex;
      if (salt === ZERO_SALT) continue;
      if (this.#storage.hasSalt(key, salt)) continue;
      this.#storage.rememberSalt(key, salt);
      return salt;
    }
    throw new Error(`CSPRNG failed to produce a fresh salt for raffle ${key} after ${MAX_GENERATION_ATTEMPTS} attempts`);
  }
}
