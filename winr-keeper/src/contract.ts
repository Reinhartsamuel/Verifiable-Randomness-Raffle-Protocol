import { decodeEventLog, type Address, type Hex, type PublicClient, type TransactionReceipt } from 'viem';
import { winrCoreAbi } from './abi.ts';
import type { Logger } from './logger.ts';

export interface ContractConstants {
  maxResolveAttempts: number;
  stallTimeout: bigint;
  hardDeadline: bigint;
  resolveGrace: bigint;
}

export interface RaffleView {
  host: Address;
  expiry: bigint;
  status: number;
  underfilled: boolean;
  prizeType: number;
  prizeAsset: Address;
  ticketsSold: bigint;
  prizeAmountOrTokenId: bigint;
  ticketPrice: bigint;
  maxCap: bigint;
}

export interface ResolutionStateView {
  status: number;
  attempts: number;
  activeProviderAddr: Address;
  activeSequence: bigint;
  lastRequestedAt: bigint;
  underfilled: boolean;
  prizeDisposedFlag: boolean;
}

export interface SettleSummary {
  winner?: Address;
  eventNames: string[];
  escrows: Record<string, unknown>[];
}

const DAY = 86_400n;
const HOUR = 3_600n;

/**
 * viem decodes ABI integers narrower than 128 bits as JS `number`, not `bigint`
 * (`uint8`, `uint48`, `uint64`, `uint96`). The view interfaces below declare
 * those fields as `bigint` because callers do bigint arithmetic on them
 * (`expiry + HARD_DEADLINE`), so coerce at the decode boundary — mixing a
 * `number` into bigint arithmetic throws "Cannot mix BigInt and other types".
 */
function toBigint(value: bigint | number): bigint {
  return typeof value === 'bigint' ? value : BigInt(value);
}

/**
 * The contract exposes MAX_RESOLVE_ATTEMPTS / STALL_TIMEOUT / HARD_DEADLINE /
 * RESOLVE_GRACE as public constants. Read them once at startup (with safe
 * fallbacks) so the keeper tracks the deployed values, not hardcoded ones.
 */
export async function readContractConstants(
  publicClient: PublicClient,
  contractAddress: Address,
  logger?: Logger,
): Promise<ContractConstants> {
  const read = async (functionName: 'MAX_RESOLVE_ATTEMPTS' | 'STALL_TIMEOUT' | 'HARD_DEADLINE' | 'RESOLVE_GRACE') => {
    try {
      return (await publicClient.readContract({
        address: contractAddress,
        abi: winrCoreAbi,
        functionName,
      })) as bigint | number;
    } catch (error) {
      logger?.warn('could not read contract constant — using fallback', {
        functionName,
        error: error instanceof Error ? error.message : String(error),
      });
      return undefined;
    }
  };

  const [attempts, stall, hard, grace] = await Promise.all([
    read('MAX_RESOLVE_ATTEMPTS'),
    read('STALL_TIMEOUT'),
    read('HARD_DEADLINE'),
    read('RESOLVE_GRACE'),
  ]);

  return {
    maxResolveAttempts: attempts !== undefined ? Number(attempts) : 3,
    stallTimeout: stall !== undefined ? BigInt(stall) : 6n * HOUR,
    hardDeadline: hard !== undefined ? BigInt(hard) : 7n * DAY,
    resolveGrace: grace !== undefined ? BigInt(grace) : 72n * HOUR,
  };
}

export async function getRaffleCount(publicClient: PublicClient, contractAddress: Address): Promise<bigint> {
  return (await publicClient.readContract({
    address: contractAddress,
    abi: winrCoreAbi,
    functionName: 'raffleCount',
  })) as bigint;
}

export async function getRaffleView(
  publicClient: PublicClient,
  contractAddress: Address,
  raffleId: bigint,
): Promise<RaffleView> {
  const raffle = (await publicClient.readContract({
    address: contractAddress,
    abi: winrCoreAbi,
    functionName: 'getRaffle',
    args: [raffleId],
  })) as unknown as RaffleView;
  // `expiry` (uint48) and `ticketsSold` (uint96) decode as numbers.
  return { ...raffle, expiry: toBigint(raffle.expiry), ticketsSold: toBigint(raffle.ticketsSold) };
}

/**
 * Status-only read used by the on-chain settlement sweep. It decodes the same
 * `getRaffle` struct as {getRaffleView} but returns just the status byte, which
 * is all the sweep needs to decide enqueue / watch / skip.
 */
export async function getRaffleStatus(
  publicClient: PublicClient,
  contractAddress: Address,
  raffleId: bigint,
): Promise<number> {
  const raffle = (await publicClient.readContract({
    address: contractAddress,
    abi: winrCoreAbi,
    functionName: 'getRaffle',
    args: [raffleId],
  })) as unknown as RaffleView;
  return Number(raffle.status);
}

export async function getResolutionStateView(
  publicClient: PublicClient,
  contractAddress: Address,
  raffleId: bigint,
): Promise<ResolutionStateView> {
  const state = (await publicClient.readContract({
    address: contractAddress,
    abi: winrCoreAbi,
    functionName: 'getResolutionState',
    args: [raffleId],
  })) as unknown as ResolutionStateView;
  // `activeSequence` (uint64) and `lastRequestedAt` (uint48) decode as numbers.
  return {
    ...state,
    activeSequence: toBigint(state.activeSequence),
    lastRequestedAt: toBigint(state.lastRequestedAt),
  };
}

/** True when the receipt contains the given WinrCore event. */
export function receiptHasContractEvent(receipt: TransactionReceipt, eventName: string): boolean {
  return decodeReceiptEvents(receipt).some((decoded) => decoded.eventName === eventName);
}

interface DecodedLog {
  eventName: string;
  args: Record<string, unknown>;
}

function decodeReceiptEvents(receipt: TransactionReceipt): DecodedLog[] {
  const decodedLogs: DecodedLog[] = [];
  for (const log of receipt.logs) {
    if (log.address.toLowerCase() !== receipt.to?.toLowerCase()) continue;
    try {
      const decoded = decodeEventLog({
        abi: winrCoreAbi,
        data: log.data as Hex,
        topics: log.topics as [Hex, ...Hex[]],
      });
      decodedLogs.push({
        eventName: decoded.eventName,
        args: (decoded.args ?? {}) as Record<string, unknown>,
      });
    } catch {
      // Not one of ours / undecodable — ignore.
    }
  }
  return decodedLogs;
}

/**
 * Post-settle receipt audit: winner, distribution events and any push-with-
 * escrow fallbacks (PayoutEscrowed / NftEscrowed) that require the recipient to
 * pull-claim. A raffle with escrows is still COMPLETED on-chain — never retry.
 */
export function summarizeSettlementReceipt(receipt: TransactionReceipt): SettleSummary {
  const summary: SettleSummary = { eventNames: [], escrows: [] };
  for (const { eventName, args } of decodeReceiptEvents(receipt)) {
    summary.eventNames.push(eventName);
    if (eventName === 'WinnerPicked' && typeof args.winner === 'string') {
      summary.winner = args.winner as Address;
    }
    if (eventName === 'PayoutEscrowed' || eventName === 'NftEscrowed') {
      summary.escrows.push(args);
    }
  }
  return summary;
}
