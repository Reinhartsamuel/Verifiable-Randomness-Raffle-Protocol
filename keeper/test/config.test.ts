import assert from 'node:assert/strict';
import { test } from 'node:test';
import { ConfigError, loadConfig } from '../src/config.ts';

const CONTRACT = '0x95d256cdD7d0B8579538E98DFFc343e725a717Ec';
const KEY = `0x${'11'.repeat(32)}`;

function baseEnv(extra: Record<string, string> = {}): NodeJS.ProcessEnv {
  return {
    RAFFLE_RPC_URL: 'https://rpc.testnet.chain.robinhood.com',
    RAFFLE_CONTRACT_ADDRESS: CONTRACT,
    RAFFLE_RESOLVER_PRIVATE_KEY: KEY,
    ...extra,
  };
}

test('applies documented defaults', () => {
  const cfg = loadConfig(baseEnv(), []);
  assert.equal(cfg.contractAddress, CONTRACT);
  assert.equal(cfg.resolveBatch, 50n);
  assert.equal(cfg.resolveIntervalMs, 300_000);
  assert.equal(cfg.resolveRetryCooldownMs, 300_000);
  assert.equal(cfg.settleIntervalMs, 180_000);
  assert.equal(cfg.cancelExpiredAfterGrace, false);
  assert.equal(cfg.settleMaxAttempts, 5);
  assert.equal(cfg.settleSweepEnabled, true);
  assert.equal(cfg.settleSweepBatch, 200);
  assert.equal(cfg.dryRun, false);
  assert.equal(cfg.jobs.resolve, true);
  assert.equal(cfg.jobs.settle, true);
  assert.equal(cfg.chainId, undefined);
  assert.equal(cfg.logLevel, 'info');
  assert.equal(cfg.stateFile, './data/keeper-state.json');
  assert.equal(cfg.logChunkSize, 5_000n);
  assert.equal(cfg.logChunkSizeExplicit, false);
  assert.equal(cfg.logMaxRequestsPerCycle, 50);
  assert.equal(cfg.logRpcUrl, cfg.rpcUrl);
});

test('an explicit log chunk size is marked as an override', () => {
  const cfg = loadConfig(baseEnv({ RAFFLE_LOG_CHUNK_SIZE: '10', RAFFLE_LOG_MAX_REQUESTS_PER_CYCLE: '250' }), []);
  assert.equal(cfg.logChunkSize, 10n);
  assert.equal(cfg.logChunkSizeExplicit, true);
  assert.equal(cfg.logMaxRequestsPerCycle, 250);
});

test('a separate log-scan RPC can be configured', () => {
  const cfg = loadConfig(baseEnv({ RAFFLE_LOG_RPC_URL: 'https://rpc.testnet.chain.robinhood.com' }), []);
  assert.equal(cfg.logRpcUrl, 'https://rpc.testnet.chain.robinhood.com');
  assert.equal(cfg.rpcUrl, 'https://rpc.testnet.chain.robinhood.com');
});

test('the on-chain settlement sweep can be tuned or disabled', () => {
  const cfg = loadConfig(baseEnv({ RAFFLE_SETTLE_SWEEP_ENABLED: 'false', RAFFLE_SETTLE_SWEEP_BATCH: '25' }), []);
  assert.equal(cfg.settleSweepEnabled, false);
  assert.equal(cfg.settleSweepBatch, 25);
});

test('rejects a malformed log-scan RPC URL', () => {
  assert.throws(
    () => loadConfig(baseEnv({ RAFFLE_LOG_RPC_URL: 'not-a-url' }), []),
    (error: unknown) => {
      assert.ok(error instanceof ConfigError);
      assert.ok(error.problems.some((problem) => problem.includes('RAFFLE_LOG_RPC_URL')));
      return true;
    },
  );
});

test('reports every missing required variable at once', () => {
  assert.throws(
    () => loadConfig({}, []),
    (error: unknown) => {
      assert.ok(error instanceof ConfigError);
      assert.ok(error.problems.some((problem) => problem.includes('RAFFLE_RPC_URL')));
      assert.ok(error.problems.some((problem) => problem.includes('RAFFLE_CONTRACT_ADDRESS')));
      assert.ok(error.problems.some((problem) => problem.includes('RAFFLE_RESOLVER_PRIVATE_KEY is required')));
      return true;
    },
  );
});

test('resolve job requires the resolver key', () => {
  assert.throws(
    () =>
      loadConfig(
        {
          RAFFLE_RPC_URL: 'https://rpc.testnet.chain.robinhood.com',
          RAFFLE_CONTRACT_ADDRESS: CONTRACT,
          RAFFLE_JOBS: 'resolve',
        },
        [],
      ),
    (error: unknown) => {
      assert.ok(error instanceof ConfigError);
      assert.ok(error.problems.some((problem) => problem.includes('RAFFLE_RESOLVER_PRIVATE_KEY is required')));
      return true;
    },
  );
});

test('settle-only mode works with a dedicated settler key', () => {
  const cfg = loadConfig(
    {
      RAFFLE_RPC_URL: 'https://rpc.testnet.chain.robinhood.com',
      RAFFLE_CONTRACT_ADDRESS: CONTRACT,
      RAFFLE_JOBS: 'settle',
      RAFFLE_SETTLER_PRIVATE_KEY: KEY,
    },
    [],
  );
  assert.equal(cfg.jobs.resolve, false);
  assert.equal(cfg.jobs.settle, true);
  assert.equal(cfg.settlerPrivateKey, KEY);
});

test('rejects a malformed address, key and chain id', () => {
  assert.throws(
    () =>
      loadConfig(baseEnv({ RAFFLE_CONTRACT_ADDRESS: '0x1234', RAFFLE_RESOLVER_PRIVATE_KEY: '0xabc', RAFFLE_CHAIN_ID: 'nope' }), []),
    (error: unknown) => {
      assert.ok(error instanceof ConfigError);
      assert.ok(error.problems.some((problem) => problem.includes('RAFFLE_CONTRACT_ADDRESS')));
      assert.ok(error.problems.some((problem) => problem.includes('RAFFLE_RESOLVER_PRIVATE_KEY')));
      assert.ok(error.problems.some((problem) => problem.includes('RAFFLE_CHAIN_ID')));
      return true;
    },
  );
});

test('parses wei, gwei and boolean overrides', () => {
  const cfg = loadConfig(
    baseEnv({
      RAFFLE_FEE_FUND_THRESHOLD: '1000000000000000',
      RAFFLE_MIN_WALLET_BALANCE: '5000000000000000',
      RAFFLE_MAX_FEE_GWEI: '1.5',
      RAFFLE_DRY_RUN: 'true',
      RAFFLE_CANCEL_EXPIRED_AFTER_GRACE: 'yes',
      RAFFLE_JOBS: 'settle',
    }),
    [],
  );
  assert.equal(cfg.feeFundThresholdWei, 1_000_000_000_000_000n);
  assert.equal(cfg.minWalletBalanceWei, 5_000_000_000_000_000n);
  assert.equal(cfg.maxFeePerGasWei, 1_500_000_000n);
  assert.equal(cfg.dryRun, true);
  assert.equal(cfg.cancelExpiredAfterGrace, true);
});

test('--once on the CLI enables run-once mode', () => {
  const cfg = loadConfig(baseEnv(), ['--once']);
  assert.equal(cfg.runOnce, true);
});
