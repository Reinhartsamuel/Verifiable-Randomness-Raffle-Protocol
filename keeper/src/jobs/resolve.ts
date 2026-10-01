import type { PublicClient } from 'viem';
import { lotteryCoreAbi } from '../abi.ts';
import type { Alerter } from '../alerts.ts';
import type { KeeperConfig } from '../config.ts';
import {
  getRaffleView,
  getResolutionStateView,
  receiptHasContractEvent,
  type ContractConstants,
} from '../contract.ts';
import type { Logger } from '../logger.ts';
import { scanPages } from '../pagination.ts';
import type { SaltGenerator } from '../salt.ts';
import type { StateStore } from '../state.ts';
import type { SendResult, TxSender } from '../tx.ts';
import { nowSeconds, RaffleStatus } from '../types.ts';

interface CycleReport {
  pendingFound: number;
  resolveSent: number;
  resolveSkipped: number;
  resolveFailed: number;
  stalledFound: number;
  retried: number;
  cancelled: number;
}

export interface ResolveJobDeps {
  cfg: KeeperConfig;
  logger: Logger;
  publicClient: PublicClient;
  sender: TxSender;
  state: StateStore;
  salt: SaltGenerator;
  alert: Alerter;
  constants: ContractConstants;
}

/**
 * Cron #1 — the randomness requester that replaces Chainlink Automation.
 *
 * Phase 1: page `pendingResolution(0, batch)` and call `resolveRaffle(id, salt)`
 *          for every OPEN, expired, ticketed raffle (fresh CSPRNG salt each).
 * Phase 2: page `stalledRaffles` and either `retryResolve` (attempts left) or
 *          `cancelStalledRaffle` (attempts exhausted / hard deadline passed).
 *
 * One raffle can never kill the cycle: every send is individually classified.
 */
export class ResolveJob {
  readonly #cfg: KeeperConfig;
  readonly #logger: Logger;
  readonly #publicClient: PublicClient;
  readonly #sender: TxSender;
  readonly #state: StateStore;
  readonly #salt: SaltGenerator;
  readonly #alert: Alerter;
  readonly #constants: ContractConstants;

  constructor(deps: ResolveJobDeps) {
    this.#cfg = deps.cfg;
    this.#logger = deps.logger;
    this.#publicClient = deps.publicClient;
    this.#sender = deps.sender;
    this.#state = deps.state;
    this.#salt = deps.salt;
    this.#alert = deps.alert;
    this.#constants = deps.constants;
  }

  async run(): Promise<void> {
    const startedAt = Date.now();
    const report: CycleReport = {
      pendingFound: 0,
      resolveSent: 0,
      resolveSkipped: 0,
      resolveFailed: 0,
      stalledFound: 0,
      retried: 0,
      cancelled: 0,
    };

    if (!(await this.#hasEnoughGas())) return;
    await this.#maybeFundFeeBalance();
    await this.#sweepPending(report);
    await this.#sweepStalled(report);

    this.#logger.info('resolve cycle complete', {
      ...report,
      durationMs: Date.now() - startedAt,
    });
  }

  // ── Gas / fees ────────────────────────────────────────────────────────────

  async #hasEnoughGas(): Promise<boolean> {
    if (this.#cfg.minWalletBalanceWei === 0n) return true;
    const balance = await this.#publicClient.getBalance({ address: this.#sender.address });
    if (balance >= this.#cfg.minWalletBalanceWei) return true;
    this.#alert.alert(
      'keeper wallet below minimum gas balance — resolution paused',
      {
        wallet: this.#sender.address,
        balanceWei: balance.toString(),
        minimumWei: this.#cfg.minWalletBalanceWei.toString(),
      },
      { key: 'resolve-gas' },
    );
    return false;
  }

  async #readRandomnessFee(): Promise<bigint> {
    return (await this.#publicClient.readContract({
      address: this.#cfg.contractAddress,
      abi: lotteryCoreAbi,
      functionName: 'randomnessFee',
    })) as bigint;
  }

  /**
   * Optional auto top-up of the contract's native balance (each Quiver request
   * spends `randomnessFee()` from it). Runs before the sweep when configured,
   * and again on InsufficientFeeBalance.
   */
  async #maybeFundFeeBalance(force = false): Promise<boolean> {
    const threshold = this.#cfg.feeFundThresholdWei;
    if (threshold === undefined && !force) return false;

    const [contractBalance, fee] = await Promise.all([
      this.#publicClient.getBalance({ address: this.#cfg.contractAddress }),
      this.#readRandomnessFee(),
    ]);
    const target = this.#cfg.feeFundTargetWei ?? fee * this.#cfg.resolveBatch;

    if (!force) {
      if (contractBalance >= target || contractBalance >= threshold!) return false;
    }
    if (contractBalance >= target) return true;

    const topUp = target - contractBalance;
    const walletBalance = await this.#publicClient.getBalance({ address: this.#sender.address });
    if (walletBalance < topUp + this.#cfg.minWalletBalanceWei) {
      this.#alert.alert(
        'cannot top up contract randomness fee balance — keeper wallet too low',
        {
          wallet: this.#sender.address,
          walletBalanceWei: walletBalance.toString(),
          topUpWei: topUp.toString(),
        },
        { key: 'fee-topup-wallet' },
      );
      return false;
    }

    const result = await this.#sender.send(
      { functionName: 'fundRandomnessFees', value: topUp },
      { label: 'fundRandomnessFees' },
    );
    if (result.kind === 'ok') {
      this.#logger.info('contract randomness fee balance topped up', {
        topUpWei: topUp.toString(),
        targetWei: target.toString(),
        tx: result.hash,
      });
      return true;
    }
    if (result.kind === 'dry-run') {
      this.#logger.info('dry-run: would top up contract randomness fee balance', { topUpWei: topUp.toString() });
      return true;
    }
    this.#alert.alert(
      'randomness fee top-up failed',
      { topUpWei: topUp.toString(), error: result.error.shortMessage },
      { key: 'fee-topup-failed' },
    );
    return false;
  }

  // ── Phase 1: OPEN + expired + ticketed ────────────────────────────────────

  async #sweepPending(report: CycleReport): Promise<void> {
    await scanPages(
      async (cursor, limit) => {
        const [ids, nextCursor] = (await this.#publicClient.readContract({
          address: this.#cfg.contractAddress,
          abi: lotteryCoreAbi,
          functionName: 'pendingResolution',
          args: [cursor, limit],
        })) as readonly [readonly bigint[], bigint];
        return { ids, nextCursor };
      },
      {
        limit: this.#cfg.resolveBatch,
        maxPages: this.#cfg.maxScanPasses,
        scanName: 'pendingResolution',
        logger: this.#logger,
        onPage: async (ids) => {
          report.pendingFound += ids.length;
          for (const raffleId of ids) {
            await this.#resolveOne(raffleId, report);
            await this.#state.flush();
          }
        },
      },
    );
  }

  async #resolveOne(raffleId: bigint, report: CycleReport): Promise<void> {
    // A raffle that keeps failing stays in `pendingResolution` and would
    // otherwise be re-simulated and re-sent on every single cycle. Back off per
    // raffle after a failure so a stuck raffle cannot drain the RPC quota.
    const cooldownUntil = this.#state.resolveCooldownUntil(raffleId);
    if (cooldownUntil > Date.now()) {
      report.resolveSkipped += 1;
      this.#logger.debug('resolve in cooldown after a recent failure — skipping', {
        raffleId,
        retryInMs: cooldownUntil - Date.now(),
      });
      return;
    }

    // At most two attempts: one fresh salt, plus one recovery attempt when the
    // contract rejects the salt or the fee balance (both recoverable).
    for (let attempt = 1; attempt <= 2; attempt += 1) {
      const salt = this.#salt.generate(raffleId);
      const result = await this.#sender.send(
        { functionName: 'resolveRaffle', args: [raffleId, salt] },
        { label: 'resolveRaffle', raffleId },
      );

      if (result.kind === 'ok') {
        report.resolveSent += 1;
        if (receiptHasContractEvent(result.receipt, 'RandomnessRequestFailed')) {
          // The tx landed but LotteryCore's try/catch around QUIVER.getFee
          // swallowed a provider-side failure: the raffle is still OPEN and
          // will be retried next cycle (or cancelled once grace elapsed).
          this.#logger.warn('resolve tx mined but the Quiver request failed on-chain — will retry', {
            raffleId,
            tx: result.hash,
          });
          this.#state.setResolveCooldown(raffleId, this.#cfg.resolveRetryCooldownMs);
          await this.#maybeCancelExpiredAfterGrace(raffleId);
        } else {
          this.#state.clearResolveCooldown(raffleId);
          this.#logger.info('randomness requested', { raffleId, tx: result.hash });
        }
        return;
      }

      if (result.kind === 'dry-run') {
        report.resolveSent += 1;
        return;
      }

      if (result.kind === 'failed') {
        report.resolveFailed += 1;
        this.#state.setResolveCooldown(raffleId, this.#cfg.resolveRetryCooldownMs);
        this.#alert.alert(
          'resolveRaffle transaction failed',
          { raffleId, error: result.error.shortMessage },
          { key: 'resolve-tx-failed' },
        );
        return;
      }

      // Reverted (simulated or mined).
      const name = result.error.name;
      switch (name) {
        case 'RaffleNotOpen':
        case 'RaffleNotExpired':
        case 'RaffleNoTickets':
          report.resolveSkipped += 1;
          this.#logger.debug('raffle no longer resolvable (race) — skipping', { raffleId, reason: name });
          return;

        case 'SaltAlreadyUsed':
        case 'SaltZero':
          if (attempt === 1) {
            this.#logger.warn('salt rejected by contract — retrying with a fresh salt', { raffleId, reason: name });
            continue;
          }
          report.resolveFailed += 1;
          this.#state.setResolveCooldown(raffleId, this.#cfg.resolveRetryCooldownMs);
          this.#logger.error('fresh salt rejected twice — giving up on this raffle for now', { raffleId, reason: name });
          return;

        case 'InsufficientFeeBalance': {
          const [required, available] = (result.error.args ?? []) as readonly bigint[];
          this.#alert.alert(
            'contract randomness fee balance insufficient',
            {
              raffleId,
              requiredWei: required?.toString(),
              availableWei: available?.toString(),
            },
            { key: 'fee-balance' },
          );
          const funded = await this.#maybeFundFeeBalance(true);
          if (attempt === 1 && funded) continue;
          report.resolveFailed += 1;
          this.#state.setResolveCooldown(raffleId, this.#cfg.resolveRetryCooldownMs);
          return;
        }

        case 'NotResolver':
          report.resolveFailed += 1;
          this.#state.setResolveCooldown(raffleId, this.#cfg.resolveRetryCooldownMs);
          this.#alert.alert(
            'resolveRaffle reverted NotResolver — the keeper key is not allowlisted',
            {
              raffleId,
              resolver: this.#sender.address,
              fix: `setResolver(${this.#sender.address}, true)`,
            },
            { key: 'not-resolver' },
          );
          return;

        default:
          report.resolveFailed += 1;
          this.#state.setResolveCooldown(raffleId, this.#cfg.resolveRetryCooldownMs);
          this.#logger.error('resolveRaffle reverted', {
            raffleId,
            reason: name ?? result.error.shortMessage,
            args: result.error.args,
            tx: result.hash,
          });
          return;
      }
    }
  }

  /**
   * Optional (RAFFLE_CANCEL_EXPIRED_AFTER_GRACE): when a request could not be
   * made at all (provider getFee reverting, detected via RandomnessRequestFailed)
   * and the raffle is past expiry + RESOLVE_GRACE, cancel it so entrants can
   * claimRefund instead of the raffle staying OPEN forever.
   */
  async #maybeCancelExpiredAfterGrace(raffleId: bigint): Promise<void> {
    if (!this.#cfg.cancelExpiredAfterGrace) return;
    try {
      const raffle = await getRaffleView(this.#publicClient, this.#cfg.contractAddress, raffleId);
      if (Number(raffle.status) !== RaffleStatus.OPEN) return;
      if (nowSeconds() < raffle.expiry + this.#constants.resolveGrace) return;
      const result = await this.#sender.send(
        { functionName: 'cancelExpiredRaffle', args: [raffleId] },
        { label: 'cancelExpiredRaffle', raffleId },
      );
      this.#handleCancelResult(raffleId, result, 'cancelExpiredRaffle');
    } catch (error) {
      this.#logger.warn('expired-raffle cancel check failed', {
        raffleId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  // ── Phase 2: stalled PENDING_VRF ──────────────────────────────────────────

  async #sweepStalled(report: CycleReport): Promise<void> {
    await scanPages(
      async (cursor, limit) => {
        const [ids, nextCursor] = (await this.#publicClient.readContract({
          address: this.#cfg.contractAddress,
          abi: lotteryCoreAbi,
          functionName: 'stalledRaffles',
          args: [cursor, limit],
        })) as readonly [readonly bigint[], bigint];
        return { ids, nextCursor };
      },
      {
        limit: this.#cfg.resolveBatch,
        maxPages: this.#cfg.maxScanPasses,
        scanName: 'stalledRaffles',
        logger: this.#logger,
        onPage: async (ids) => {
          report.stalledFound += ids.length;
          for (const raffleId of ids) {
            await this.#handleStalled(raffleId, report);
          }
        },
      },
    );
  }

  async #handleStalled(raffleId: bigint, report: CycleReport): Promise<void> {
    let state;
    let raffle;
    try {
      [state, raffle] = await Promise.all([
        getResolutionStateView(this.#publicClient, this.#cfg.contractAddress, raffleId),
        getRaffleView(this.#publicClient, this.#cfg.contractAddress, raffleId),
      ]);
    } catch (error) {
      this.#logger.warn('stalled raffle read failed — skipping', {
        raffleId,
        error: error instanceof Error ? error.message : String(error),
      });
      return;
    }

    if (Number(state.status) !== RaffleStatus.PENDING_VRF) {
      this.#logger.debug('stalled raffle no longer PENDING_VRF — skipping', { raffleId });
      return;
    }

    const hardDeadlinePassed = nowSeconds() >= raffle.expiry + this.#constants.hardDeadline;
    if (state.attempts >= this.#constants.maxResolveAttempts || hardDeadlinePassed) {
      const result = await this.#sender.send(
        { functionName: 'cancelStalledRaffle', args: [raffleId] },
        { label: 'cancelStalledRaffle', raffleId },
      );
      this.#handleCancelResult(raffleId, result, 'cancelStalledRaffle');
      if (result.kind === 'ok' || result.kind === 'dry-run') report.cancelled += 1;
      return;
    }

    const salt = this.#salt.generate(raffleId);
    const result = await this.#sender.send(
      { functionName: 'retryResolve', args: [raffleId, salt] },
      { label: 'retryResolve', raffleId },
    );

    if (result.kind === 'ok') {
      report.retried += 1;
      if (receiptHasContractEvent(result.receipt, 'RandomnessRequestFailed')) {
        this.#logger.warn('retry tx mined but the Quiver request failed on-chain — will retry next cycle', {
          raffleId,
          tx: result.hash,
        });
      } else {
        this.#logger.info('stalled raffle retried with a fresh salt', { raffleId, tx: result.hash });
      }
      return;
    }
    if (result.kind === 'dry-run') {
      report.retried += 1;
      return;
    }
    if (result.kind === 'failed') {
      this.#alert.alert(
        'retryResolve transaction failed',
        { raffleId, error: result.error.shortMessage },
        { key: 'retry-tx-failed' },
      );
      return;
    }

    switch (result.error.name) {
      case 'FailedCallbackPending': {
        // The coordinator buffered a failed callback; retryResolve refuses to
        // issue a duplicate while that buffer exists. Poking is permissionless
        // and redelivers it — the raffle should flip to RESOLVED shortly.
        const poke = await this.#sender.send(
          { functionName: 'pokeFailedCallback', args: [raffleId] },
          { label: 'pokeFailedCallback', raffleId },
        );
        if (poke.kind === 'ok') {
          this.#logger.info('coordinator had a buffered callback — poked retryCallback', {
            raffleId,
            tx: poke.hash,
          });
        } else if (poke.kind === 'dry-run') {
          this.#logger.info('dry-run: would poke buffered callback', { raffleId });
        } else {
          this.#logger.warn('failed to poke buffered callback — will retry next cycle', {
            raffleId,
            error: poke.error.shortMessage,
          });
        }
        return;
      }
      case 'StallTimeoutNotReached':
      case 'MaxAttemptsReached':
      case 'RaffleNotPendingVrf':
        this.#logger.debug('stalled raffle no longer eligible — skipping', { raffleId, reason: result.error.name });
        return;
      case 'NotResolver':
        this.#alert.alert(
          'retryResolve reverted NotResolver — the keeper key is not allowlisted',
          { raffleId, resolver: this.#sender.address, fix: `setResolver(${this.#sender.address}, true)` },
          { key: 'not-resolver' },
        );
        return;
      default:
        this.#logger.error('retryResolve reverted', {
          raffleId,
          reason: result.error.name ?? result.error.shortMessage,
          args: result.error.args,
          tx: result.hash,
        });
    }
  }

  #handleCancelResult(raffleId: bigint, result: SendResult, label: string): void {
    if (result.kind === 'ok' || result.kind === 'dry-run') {
      this.#logger.warn('stalled raffle cancelled — entrants can claimRefund', { raffleId, label });
      return;
    }
    if (result.kind === 'failed') {
      this.#alert.alert(
        `${label} transaction failed`,
        { raffleId, error: result.error.shortMessage },
        { key: 'cancel-tx-failed' },
      );
      return;
    }
    switch (result.error.name) {
      case 'RaffleNotPendingVrf':
      case 'RaffleNotOpen':
      case 'StalledConditionNotMet':
      case 'GraceNotElapsed':
        this.#logger.debug('cancel skipped (state moved on)', { raffleId, reason: result.error.name });
        return;
      default:
        this.#logger.error(`${label} reverted`, {
          raffleId,
          reason: result.error.name ?? result.error.shortMessage,
          args: result.error.args,
          tx: result.hash,
        });
    }
  }
}
