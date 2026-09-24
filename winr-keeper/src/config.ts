import { getAddress, isAddress, type Address, type Hex } from 'viem';
import type { LogLevel } from './logger.ts';

export class ConfigError extends Error {
  readonly problems: readonly string[];

  constructor(problems: readonly string[]) {
    super(`invalid keeper configuration:\n  - ${problems.join('\n  - ')}`);
    this.name = 'ConfigError';
    this.problems = problems;
  }
}

export interface KeeperConfig {
  readonly rpcUrl: string;
  /**
   * Optional separate RPC for the `eth_getLogs` settlement scan. Managed
   * providers cap the block span of one `eth_getLogs` call (Alchemy's free
   * tier allows only 10 blocks), which on a fast chain makes the scan cost
   * ~7.5 compute units per block. Pointing this at a wide-range endpoint keeps
   * the expensive scan off the metered provider while `rpcUrl` still serves
   * reads/writes. Defaults to `rpcUrl`.
   */
  readonly logRpcUrl: string;
  readonly contractAddress: Address;
  readonly chainId?: number;
  readonly resolverPrivateKey?: Hex;
  readonly settlerPrivateKey?: Hex;
  readonly jobs: { readonly resolve: boolean; readonly settle: boolean };
  readonly resolveBatch: bigint;
  readonly resolveIntervalMs: number;
  readonly resolveRetryCooldownMs: number;
  readonly settleIntervalMs: number;
  readonly schedulerJitterMs: number;
  readonly maxScanPasses: number;
  readonly cancelExpiredAfterGrace: boolean;
  readonly settleMaxAttempts: number;
  /** Discover RESOLVED raffles by sweeping on-chain status (getLogs-independent). */
  readonly settleSweepEnabled: boolean;
  /** Max raffle ids read per sweep pass (forward + watch). */
  readonly settleSweepBatch: number;
  readonly logLookbackBlocks: bigint;
  readonly logChunkSize: bigint;
  readonly logChunkSizeExplicit: boolean;
  readonly logMaxRequestsPerCycle: number;
  readonly startBlock?: bigint;
  readonly feeFundThresholdWei?: bigint;
  readonly feeFundTargetWei?: bigint;
  readonly minWalletBalanceWei: bigint;
  readonly maxFeePerGasWei?: bigint;
  readonly maxPriorityFeePerGasWei?: bigint;
  readonly confirmations: number;
  readonly txRetries: number;
  readonly txRetryBaseMs: number;
  readonly txTimeoutMs: number;
  readonly dryRun: boolean;
  readonly runOnce: boolean;
  readonly stateFile: string;
  readonly logLevel: LogLevel;
  readonly logPretty: boolean;
  readonly alertWebhookUrl?: string;
}

const LOG_LEVELS: readonly LogLevel[] = ['debug', 'info', 'warn', 'error'];
const PRIVATE_KEY_RE = /^0x[0-9a-fA-F]{64}$/;
const DECIMAL_RE = /^\d+$/;
const GWEI_RE = /^\d+(\.\d{1,9})?$/;

function parsePrivateKey(value: string): Hex | undefined {
  return PRIVATE_KEY_RE.test(value) ? (value as Hex) : undefined;
}

function gweiToWei(value: string): bigint | undefined {
  if (!GWEI_RE.test(value)) return undefined;
  const [whole = '0', fraction = ''] = value.split('.');
  return BigInt(whole) * 1_000_000_000n + BigInt(fraction.padEnd(9, '0'));
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env, argv: readonly string[] = process.argv.slice(2)): KeeperConfig {
  const problems: string[] = [];

  const raw = (name: string): string | undefined => {
    const value = env[name];
    return value === undefined || value.trim() === '' ? undefined : value.trim();
  };

  const required = (name: string): string | undefined => {
    const value = raw(name);
    if (value === undefined) problems.push(`${name} is required`);
    return value;
  };

  const int = (name: string, fallback: number, min: number, max: number): number => {
    const value = raw(name);
    if (value === undefined) return fallback;
    if (!DECIMAL_RE.test(value)) {
      problems.push(`${name} must be a non-negative integer (got "${value}")`);
      return fallback;
    }
    const parsed = Number(value);
    if (!Number.isSafeInteger(parsed) || parsed < min || parsed > max) {
      problems.push(`${name} must be between ${min} and ${max} (got "${value}")`);
      return fallback;
    }
    return parsed;
  };

  const bigint = (name: string, fallback: bigint, min: bigint): bigint => {
    const value = raw(name);
    if (value === undefined) return fallback;
    if (!DECIMAL_RE.test(value)) {
      problems.push(`${name} must be a non-negative integer in wei (got "${value}")`);
      return fallback;
    }
    const parsed = BigInt(value);
    if (parsed < min) {
      problems.push(`${name} must be >= ${min} (got "${value}")`);
      return fallback;
    }
    return parsed;
  };

  const optionalBigint = (name: string, min: bigint): bigint | undefined => {
    const value = raw(name);
    if (value === undefined) return undefined;
    if (!DECIMAL_RE.test(value)) {
      problems.push(`${name} must be a non-negative integer in wei (got "${value}")`);
      return undefined;
    }
    const parsed = BigInt(value);
    if (parsed < min) {
      problems.push(`${name} must be >= ${min} (got "${value}")`);
      return undefined;
    }
    return parsed;
  };

  const bool = (name: string, fallback: boolean): boolean => {
    const value = raw(name)?.toLowerCase();
    if (value === undefined) return fallback;
    if (['1', 'true', 'yes', 'on'].includes(value)) return true;
    if (['0', 'false', 'no', 'off'].includes(value)) return false;
    problems.push(`${name} must be a boolean (true/false, got "${value}")`);
    return fallback;
  };

  // Required ────────────────────────────────────────────────────────────────
  const rpcUrl = required('RAFFLE_RPC_URL');
  if (rpcUrl !== undefined && !/^https?:\/\//.test(rpcUrl)) {
    problems.push(`RAFFLE_RPC_URL must be an http(s) URL (got "${rpcUrl}")`);
  }

  const logRpcRaw = raw('RAFFLE_LOG_RPC_URL');
  if (logRpcRaw !== undefined && !/^https?:\/\//.test(logRpcRaw)) {
    problems.push(`RAFFLE_LOG_RPC_URL must be an http(s) URL (got "${logRpcRaw}")`);
  }
  const logRpcUrl = logRpcRaw ?? rpcUrl;

  const contractRaw = required('RAFFLE_CONTRACT_ADDRESS');
  let contractAddress: Address | undefined;
  if (contractRaw !== undefined) {
    if (isAddress(contractRaw)) {
      contractAddress = getAddress(contractRaw);
    } else {
      problems.push(`RAFFLE_CONTRACT_ADDRESS is not a valid address (got "${contractRaw}")`);
    }
  }

  // Keys ────────────────────────────────────────────────────────────────────
  const resolverKeyRaw = raw('RAFFLE_RESOLVER_PRIVATE_KEY');
  let resolverPrivateKey: Hex | undefined;
  if (resolverKeyRaw !== undefined) {
    resolverPrivateKey = parsePrivateKey(resolverKeyRaw);
    if (resolverPrivateKey === undefined) {
      problems.push('RAFFLE_RESOLVER_PRIVATE_KEY must be a 32-byte hex private key (0x + 64 hex chars)');
    }
  }

  const settlerKeyRaw = raw('RAFFLE_SETTLER_PRIVATE_KEY');
  let settlerPrivateKey: Hex | undefined;
  if (settlerKeyRaw !== undefined) {
    settlerPrivateKey = parsePrivateKey(settlerKeyRaw);
    if (settlerPrivateKey === undefined) {
      problems.push('RAFFLE_SETTLER_PRIVATE_KEY must be a 32-byte hex private key (0x + 64 hex chars)');
    }
  }

  // Jobs ────────────────────────────────────────────────────────────────────
  const jobsRaw = raw('RAFFLE_JOBS') ?? 'resolve,settle';
  const jobNames = jobsRaw.split(',').map((entry) => entry.trim().toLowerCase()).filter((entry) => entry.length > 0);
  for (const name of jobNames) {
    if (name !== 'resolve' && name !== 'settle') {
      problems.push(`RAFFLE_JOBS contains unknown job "${name}" (expected resolve and/or settle)`);
    }
  }
  const jobs = { resolve: jobNames.includes('resolve'), settle: jobNames.includes('settle') };
  if (!jobs.resolve && !jobs.settle) problems.push('RAFFLE_JOBS enables no jobs (expected resolve and/or settle)');
  if (jobs.resolve && resolverPrivateKey === undefined) {
    problems.push('RAFFLE_RESOLVER_PRIVATE_KEY is required when the resolve job is enabled');
  }
  if (jobs.settle && settlerPrivateKey === undefined && resolverPrivateKey === undefined) {
    problems.push('RAFFLE_RESOLVER_PRIVATE_KEY (or RAFFLE_SETTLER_PRIVATE_KEY) is required when the settle job is enabled');
  }

  // Chain ───────────────────────────────────────────────────────────────────
  const chainIdRaw = raw('RAFFLE_CHAIN_ID');
  let chainId: number | undefined;
  if (chainIdRaw !== undefined) {
    if (!DECIMAL_RE.test(chainIdRaw)) {
      problems.push(`RAFFLE_CHAIN_ID must be an integer (got "${chainIdRaw}")`);
    } else {
      chainId = Number(chainIdRaw);
    }
  }

  // Gas overrides ───────────────────────────────────────────────────────────
  const maxFeeRaw = raw('RAFFLE_MAX_FEE_GWEI');
  let maxFeePerGasWei: bigint | undefined;
  if (maxFeeRaw !== undefined) {
    maxFeePerGasWei = gweiToWei(maxFeeRaw);
    if (maxFeePerGasWei === undefined) problems.push(`RAFFLE_MAX_FEE_GWEI must be a number (got "${maxFeeRaw}")`);
  }
  const maxPriorityRaw = raw('RAFFLE_MAX_PRIORITY_FEE_GWEI');
  let maxPriorityFeePerGasWei: bigint | undefined;
  if (maxPriorityRaw !== undefined) {
    maxPriorityFeePerGasWei = gweiToWei(maxPriorityRaw);
    if (maxPriorityFeePerGasWei === undefined) {
      problems.push(`RAFFLE_MAX_PRIORITY_FEE_GWEI must be a number (got "${maxPriorityRaw}")`);
    }
  }

  // Observability ───────────────────────────────────────────────────────────
  const logLevelRaw = raw('RAFFLE_LOG_LEVEL') ?? 'info';
  if (!LOG_LEVELS.includes(logLevelRaw as LogLevel)) {
    problems.push(`RAFFLE_LOG_LEVEL must be one of ${LOG_LEVELS.join(', ')} (got "${logLevelRaw}")`);
  }
  const logPretty = bool('RAFFLE_LOG_PRETTY', process.stdout.isTTY === true);

  if (problems.length > 0) throw new ConfigError(problems);

  return Object.freeze({
    rpcUrl: rpcUrl!,
    logRpcUrl: logRpcUrl!,
    contractAddress: contractAddress!,
    chainId,
    resolverPrivateKey,
    settlerPrivateKey,
    jobs,
    resolveBatch: bigint('RAFFLE_RESOLVE_BATCH', 50n, 1n),
    resolveIntervalMs: int('RAFFLE_RESOLVE_INTERVAL_MS', 300_000, 5_000, 86_400_000),
    resolveRetryCooldownMs: int('RAFFLE_RESOLVE_RETRY_COOLDOWN_MS', 300_000, 0, 86_400_000),
    settleIntervalMs: int('RAFFLE_SETTLE_INTERVAL_MS', 180_000, 5_000, 86_400_000),
    schedulerJitterMs: int('RAFFLE_SCHEDULER_JITTER_MS', 15_000, 0, 600_000),
    maxScanPasses: int('RAFFLE_MAX_SCAN_PASSES', 200, 1, 1_000_000),
    cancelExpiredAfterGrace: bool('RAFFLE_CANCEL_EXPIRED_AFTER_GRACE', false),
    settleMaxAttempts: int('RAFFLE_SETTLE_MAX_ATTEMPTS', 5, 1, 100),
    settleSweepEnabled: bool('RAFFLE_SETTLE_SWEEP_ENABLED', true),
    settleSweepBatch: int('RAFFLE_SETTLE_SWEEP_BATCH', 200, 1, 10_000),
    logLookbackBlocks: bigint('RAFFLE_LOG_LOOKBACK_BLOCKS', 10_000n, 0n),
    logChunkSize: bigint('RAFFLE_LOG_CHUNK_SIZE', 5_000n, 1n),
    logChunkSizeExplicit: raw('RAFFLE_LOG_CHUNK_SIZE') !== undefined,
    logMaxRequestsPerCycle: int('RAFFLE_LOG_MAX_REQUESTS_PER_CYCLE', 50, 1, 1_000_000),
    startBlock: optionalBigint('RAFFLE_START_BLOCK', 0n),
    feeFundThresholdWei: optionalBigint('RAFFLE_FEE_FUND_THRESHOLD', 0n),
    feeFundTargetWei: optionalBigint('RAFFLE_FEE_FUND_TARGET', 0n),
    minWalletBalanceWei: bigint('RAFFLE_MIN_WALLET_BALANCE', 0n, 0n),
    maxFeePerGasWei,
    maxPriorityFeePerGasWei,
    confirmations: int('RAFFLE_CONFIRMATIONS', 1, 1, 1_000),
    txRetries: int('RAFFLE_TX_RETRIES', 3, 0, 100),
    txRetryBaseMs: int('RAFFLE_TX_RETRY_BASE_MS', 2_500, 100, 600_000),
    txTimeoutMs: int('RAFFLE_TX_TIMEOUT_MS', 90_000, 5_000, 3_600_000),
    dryRun: bool('RAFFLE_DRY_RUN', false),
    runOnce: bool('RAFFLE_RUN_ONCE', false) || argv.includes('--once'),
    stateFile: raw('RAFFLE_STATE_FILE') ?? './data/keeper-state.json',
    logLevel: logLevelRaw as LogLevel,
    logPretty,
    alertWebhookUrl: raw('RAFFLE_ALERT_WEBHOOK_URL'),
  });
}
