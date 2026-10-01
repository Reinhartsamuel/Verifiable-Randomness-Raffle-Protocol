import type { Account, Address, Abi, Chain, Hex, PublicClient, TransactionReceipt, WalletClient } from 'viem';
import { lotteryCoreAbi } from './abi.ts';
import type { KeeperConfig } from './config.ts';
import { decodeError, isTransientError, sleep, type DecodedError } from './errors.ts';
import type { Logger } from './logger.ts';

const looseAbi = lotteryCoreAbi as unknown as Abi;

export interface SendRequest {
  functionName: string;
  args?: readonly unknown[];
  value?: bigint;
}

export interface SendContext {
  label: string;
  raffleId?: bigint;
}

export type SendResult =
  | { kind: 'ok'; hash: Hex; receipt: TransactionReceipt }
  | { kind: 'dry-run' }
  | { kind: 'reverted'; error: DecodedError; hash?: Hex }
  | { kind: 'failed'; error: DecodedError };

export interface TxSender {
  readonly address: Address;
  send(request: SendRequest, context: SendContext): Promise<SendResult>;
}

export interface TxSenderDeps {
  publicClient: PublicClient;
  walletClient: WalletClient;
  account: Account;
  contractAddress: Address;
  chain: Chain;
  cfg: KeeperConfig;
  logger: Logger;
}

interface WriteContractArgs {
  abi: Abi;
  address: Address;
  account: Account;
  chain: Chain;
  functionName: string;
  args?: readonly unknown[];
  value?: bigint;
  maxFeePerGas?: bigint;
  maxPriorityFeePerGas?: bigint;
}

/**
 * Sends one contract call per invocation, sequentially (callers await the
 * receipt before the next raffle). Handles:
 *  - dry-run: simulate only, send nothing
 *  - transient RPC/nonce errors: bounded exponential backoff + retry
 *  - mined-but-reverted receipts: re-simulated at that block to decode the
 *    custom error (viem's writeContract does not throw for mined reverts)
 *  - receipt-wait timeouts: single getTransactionReceipt re-check before
 *    treating the attempt as transient (a landed tx then yields a benign
 *    race revert on the next attempt, e.g. RaffleNotOpen / RaffleNotResolved)
 */
export function createTxSender(deps: TxSenderDeps): TxSender {
  const { publicClient, walletClient, account, contractAddress, chain, cfg, logger } = deps;
  const maxAttempts = Math.max(1, cfg.txRetries + 1);

  const simulate = async (request: SendRequest): Promise<{ ok: true } | { ok: false; error: DecodedError }> => {
    try {
      await (publicClient.simulateContract as (args: unknown) => Promise<unknown>)({
        abi: looseAbi,
        address: contractAddress,
        account,
        functionName: request.functionName,
        args: request.args,
        ...(request.value !== undefined ? { value: request.value } : {}),
      });
      return { ok: true };
    } catch (error) {
      return { ok: false, error: decodeError(error) };
    }
  };

  const waitForReceipt = async (hash: Hex): Promise<TransactionReceipt> => {
    try {
      return await publicClient.waitForTransactionReceipt({
        hash,
        confirmations: cfg.confirmations,
        timeout: cfg.txTimeoutMs,
      });
    } catch (error) {
      // Timed out (or transport blip) while waiting — the tx may still have
      // landed. One direct lookup is cheap and decisive.
      const existing = await publicClient.getTransactionReceipt({ hash }).catch(() => null);
      if (existing) return existing;
      throw error;
    }
  };

  const write = async (request: SendRequest): Promise<Hex> => {
    const args: WriteContractArgs = {
      abi: looseAbi,
      address: contractAddress,
      account,
      chain,
      functionName: request.functionName,
      ...(request.args !== undefined ? { args: request.args } : {}),
      ...(request.value !== undefined ? { value: request.value } : {}),
      ...(cfg.maxFeePerGasWei !== undefined ? { maxFeePerGas: cfg.maxFeePerGasWei } : {}),
      ...(cfg.maxPriorityFeePerGasWei !== undefined ? { maxPriorityFeePerGas: cfg.maxPriorityFeePerGasWei } : {}),
    };
    return (walletClient.writeContract as (input: unknown) => Promise<Hex>)(args);
  };

  return {
    address: account.address,
    async send(request, context): Promise<SendResult> {
      if (cfg.dryRun) {
        const result = await simulate(request);
        if (result.ok) {
          logger.info('dry-run: would send transaction', {
            label: context.label,
            functionName: request.functionName,
            raffleId: context.raffleId,
          });
          return { kind: 'dry-run' };
        }
        const looksLikeRevert = result.error.name !== undefined || /revert/i.test(result.error.shortMessage);
        return looksLikeRevert ? { kind: 'reverted', error: result.error } : { kind: 'failed', error: result.error };
      }

      let lastError: DecodedError = { shortMessage: 'unknown transaction error', message: 'unknown transaction error' };
      for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
        try {
          const hash = await write(request);
          const receipt = await waitForReceipt(hash);

          if (receipt.status === 'reverted') {
            const replay = await simulate(request);
            const error = replay.ok
              ? { shortMessage: 'transaction reverted', message: 'transaction reverted' }
              : replay.error;
            return { kind: 'reverted', error, hash };
          }
          return { kind: 'ok', hash, receipt };
        } catch (error) {
          lastError = decodeError(error);
          const transient = isTransientError(error);
          const looksLikeRevert = lastError.name !== undefined || /revert/i.test(lastError.shortMessage);

          if (!transient || looksLikeRevert) {
            return looksLikeRevert
              ? { kind: 'reverted', error: lastError }
              : { kind: 'failed', error: lastError };
          }

          if (attempt < maxAttempts) {
            const delay = cfg.txRetryBaseMs * 2 ** (attempt - 1) + Math.floor(Math.random() * 500);
            logger.warn('transient tx error — retrying', {
              label: context.label,
              raffleId: context.raffleId,
              attempt,
              maxAttempts,
              delayMs: delay,
              error: lastError.shortMessage,
            });
            await sleep(delay);
            continue;
          }
        }
      }
      return { kind: 'failed', error: lastError };
    },
  };
}
