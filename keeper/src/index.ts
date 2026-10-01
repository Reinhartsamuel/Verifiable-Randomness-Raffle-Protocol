import { lotteryCoreAbi } from './abi.ts';
import { createAlerter } from './alerts.ts';
import { createPublicContext, createRpcClient, createWalletContext } from './chain.ts';
import { ConfigError, loadConfig, type KeeperConfig } from './config.ts';
import { readContractConstants } from './contract.ts';
import { isTransientError, sleep } from './errors.ts';
import { ResolveJob } from './jobs/resolve.ts';
import { SettleJob } from './jobs/settle.ts';
import { createLogger, type Logger } from './logger.ts';
import { SaltGenerator } from './salt.ts';
import { Scheduler, type JobDefinition } from './scheduler.ts';
import { StateStore } from './state.ts';
import { createTxSender } from './tx.ts';

/**
 * Block startup until the RPC answers. When the provider is over its usage /
 * quota (429, compute-unit capacity) or momentarily unreachable, restarting the
 * process immediately would only burn more of the quota, so retry with
 * exponential backoff in-process instead of exiting for PM2 to restart.
 * Non-transient errors (bad URL, wrong contract) still fail fast.
 */
async function waitForRpc(cfg: KeeperConfig, logger: Logger): Promise<void> {
  let delayMs = 5_000;
  for (let attempt = 1; ; attempt += 1) {
    try {
      const { publicClient, chainId } = await createPublicContext(cfg);
      await publicClient.getBlockNumber();
      if (attempt > 1) logger.info('RPC reachable again — continuing keeper startup', { attempt, chainId });
      return;
    } catch (error) {
      if (!isTransientError(error)) throw error;
      logger.warn('RPC unavailable (quota/rate limit/network) — waiting before startup retry', {
        attempt,
        retryInMs: delayMs,
        error: error instanceof Error ? error.message : String(error),
      });
      await sleep(delayMs);
      delayMs = Math.min(delayMs * 2, 5 * 60_000);
    }
  }
}

async function main(): Promise<void> {
  let cfg;
  try {
    cfg = loadConfig();
  } catch (error) {
    if (error instanceof ConfigError) {
      console.error(`keeper cannot start: ${error.message}`);
      process.exit(2);
    }
    throw error;
  }

  const logger = createLogger({ level: cfg.logLevel, pretty: cfg.logPretty });
  const alert = createAlerter(logger, cfg.alertWebhookUrl);
  const state = await StateStore.open(cfg.stateFile, logger);
  let closed = false;
  let scheduler: Scheduler | undefined;

  try {
    await waitForRpc(cfg, logger);
    const { chain, chainId, publicClient } = await createPublicContext(cfg);
    if (cfg.chainId !== undefined && cfg.chainId !== chainId) {
      throw new Error(
        `RAFFLE_CHAIN_ID=${cfg.chainId} does not match the RPC chain id ${chainId} (${cfg.rpcUrl}) — refusing to run`,
      );
    }

    const code = await publicClient.getCode({ address: cfg.contractAddress });
    if (code === undefined || code === '0x') {
      throw new Error(
        `no contract code at ${cfg.contractAddress} on chain ${chainId} — check RAFFLE_CONTRACT_ADDRESS and RAFFLE_RPC_URL`,
      );
    }

    const constants = await readContractConstants(publicClient, cfg.contractAddress, logger);

    // Route the expensive eth_getLogs scan to a separate RPC when configured,
    // so a metered provider with a narrow range cap is not drained by it.
    const logPublicClient =
      cfg.logRpcUrl === cfg.rpcUrl ? publicClient : createRpcClient(cfg.logRpcUrl, chain);
    if (logPublicClient !== publicClient) {
      logger.info('settlement log scan uses a separate RPC', { logRpcUrl: cfg.logRpcUrl });
    }

    const jobs: JobDefinition[] = [];

    if (cfg.jobs.resolve) {
      const resolverKey = cfg.resolverPrivateKey;
      if (resolverKey === undefined) throw new Error('resolve job enabled without RAFFLE_RESOLVER_PRIVATE_KEY');
      const { account, walletClient } = createWalletContext(cfg, resolverKey, chain);
      const isResolver = (await publicClient
        .readContract({
          address: cfg.contractAddress,
          abi: lotteryCoreAbi,
          functionName: 'isResolver',
          args: [account.address],
        })
        .catch(() => false)) as boolean;

      if (!isResolver) {
        alert.alert(
          'resolver key is NOT allowlisted — resolveRaffle will revert NotResolver',
          {
            resolver: account.address,
            contract: cfg.contractAddress,
            fix: `setResolver(${account.address}, true)`,
          },
          { key: 'not-resolver-startup' },
        );
      }

      const jobLogger = logger.child({ job: 'resolve' });
      const resolveJob = new ResolveJob({
        cfg,
        logger: jobLogger,
        publicClient,
        sender: createTxSender({
          publicClient,
          walletClient,
          account,
          contractAddress: cfg.contractAddress,
          chain,
          cfg,
          logger: jobLogger,
        }),
        state,
        salt: new SaltGenerator(state),
        alert,
        constants,
      });
      jobs.push({
        name: 'resolve',
        everyMs: cfg.resolveIntervalMs,
        jitterMs: cfg.schedulerJitterMs,
        runOnStart: true,
        run: () => resolveJob.run(),
      });
      logger.info('resolution keeper armed', {
        resolver: account.address,
        allowlisted: isResolver,
        intervalMs: cfg.resolveIntervalMs,
        batch: cfg.resolveBatch.toString(),
      });
    }

    if (cfg.jobs.settle) {
      const settlerKey = cfg.settlerPrivateKey ?? cfg.resolverPrivateKey;
      if (settlerKey === undefined) throw new Error('settle job enabled without a settler or resolver key');
      const { account, walletClient } = createWalletContext(cfg, settlerKey, chain);
      const jobLogger = logger.child({ job: 'settle' });
      const settleJob = new SettleJob({
        cfg,
        logger: jobLogger,
        publicClient,
        logPublicClient,
        sender: createTxSender({
          publicClient,
          walletClient,
          account,
          contractAddress: cfg.contractAddress,
          chain,
          cfg,
          logger: jobLogger,
        }),
        state,
        alert,
      });
      jobs.push({
        name: 'settle',
        everyMs: cfg.settleIntervalMs,
        jitterMs: Math.min(cfg.schedulerJitterMs, 5_000),
        runOnStart: true,
        run: () => settleJob.run(),
      });
      logger.info('settlement relayer armed', {
        settler: account.address,
        resolverKeyShared: cfg.settlerPrivateKey === undefined,
        intervalMs: cfg.settleIntervalMs,
      });
    }

    const [raffleCount, contractBalance, randomnessFee, walletBalance] = await Promise.all([
      publicClient.readContract({ address: cfg.contractAddress, abi: lotteryCoreAbi, functionName: 'raffleCount' }),
      publicClient.getBalance({ address: cfg.contractAddress }),
      publicClient
        .readContract({ address: cfg.contractAddress, abi: lotteryCoreAbi, functionName: 'randomnessFee' })
        .catch(() => 0n),
      cfg.jobs.resolve || cfg.jobs.settle
        ? publicClient.getBalance({
            address: createWalletContext(cfg, cfg.settlerPrivateKey ?? cfg.resolverPrivateKey!, chain).account.address,
          })
        : Promise.resolve(0n),
    ]);

    logger.info('keeper started', {
      contract: cfg.contractAddress,
      chainId,
      jobs: jobs.map((job) => job.name),
      dryRun: cfg.dryRun,
      runOnce: cfg.runOnce,
      raffleCount: String(raffleCount),
      contractBalanceWei: contractBalance.toString(),
      randomnessFeeWei: String(randomnessFee),
      keeperWalletBalanceWei: walletBalance.toString(),
      constants: {
        maxResolveAttempts: constants.maxResolveAttempts,
        stallTimeoutSec: constants.stallTimeout.toString(),
        hardDeadlineSec: constants.hardDeadline.toString(),
        resolveGraceSec: constants.resolveGrace.toString(),
      },
      state: { file: cfg.stateFile, ...state.stats() },
    });

    if (cfg.runOnce) {
      for (const job of jobs) {
        await job.run();
      }
      await state.close();
      closed = true;
      return;
    }

    scheduler = new Scheduler(logger);
    scheduler.start(jobs);

    const shutdown = async (signal: string): Promise<void> => {
      if (closed) return;
      closed = true;
      logger.info('shutting down', { signal });
      await scheduler?.stop();
      await state.close();
      process.exit(0);
    };
    process.on('SIGINT', () => void shutdown('SIGINT'));
    process.on('SIGTERM', () => void shutdown('SIGTERM'));

    process.on('uncaughtException', (error) => {
      logger.error('uncaught exception — exiting for a clean restart', { error: error.message, stack: error.stack });
      void shutdown('uncaughtException');
    });
    process.on('unhandledRejection', (reason) => {
      logger.error('unhandled rejection', { error: reason instanceof Error ? reason.message : String(reason) });
    });
  } catch (error) {
    if (!closed) {
      closed = true;
      await state.close().catch(() => undefined);
    }
    throw error;
  }
}

main().catch((error) => {
  console.error(`keeper fatal: ${error instanceof Error ? (error.stack ?? error.message) : String(error)}`);
  process.exit(1);
});
