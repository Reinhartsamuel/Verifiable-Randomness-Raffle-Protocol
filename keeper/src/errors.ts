import { BaseError, ContractFunctionRevertedError, decodeErrorResult } from 'viem';
import { lotteryCoreAbi } from './abi.ts';

export interface DecodedError {
  /** Custom error name when the revert decoded against the LotteryCore ABI. */
  name?: string;
  /** Decoded error args (e.g. [required, available] for InsufficientFeeBalance). */
  args?: readonly unknown[];
  /** viem's one-line message. */
  shortMessage: string;
  message: string;
}

interface RevertData {
  errorName?: string;
  args?: readonly unknown[];
}

/**
 * Extract a contract custom-error name/args from a viem error tree, falling
 * back to raw revert decoding and finally to the plain message.
 */
export function decodeError(error: unknown): DecodedError {
  if (error instanceof BaseError) {
    const revert = error.walk((entry) => entry instanceof ContractFunctionRevertedError) as
      | ContractFunctionRevertedError
      | undefined;
    if (revert) {
      const data = (revert as unknown as { data?: RevertData }).data;
      if (data?.errorName) {
        return { name: data.errorName, args: data.args, shortMessage: error.shortMessage, message: error.message };
      }
      const raw = (revert as unknown as { raw?: `0x${string}` }).raw;
      if (raw) {
        try {
          const decoded = decodeErrorResult({ abi: lotteryCoreAbi, data: raw });
          return {
            name: decoded.errorName,
            args: decoded.args as readonly unknown[] | undefined,
            shortMessage: error.shortMessage,
            message: error.message,
          };
        } catch {
          // fall through
        }
      }
      return { shortMessage: error.shortMessage, message: error.message };
    }
    return { shortMessage: error.shortMessage, message: error.message };
  }
  const message = error instanceof Error ? error.message : String(error);
  return { shortMessage: message, message };
}

const TRANSIENT_PATTERNS = [
  /timeout/i,
  /timed out/i,
  /fetch failed/i,
  /network error/i,
  /socket hang up/i,
  /ECONNRESET/i,
  /ECONNREFUSED/i,
  /ETIMEDOUT/i,
  /ESOCKETTIMEDOUT/i,
  /EAI_AGAIN/i,
  /ENOTFOUND/i,
  /429/,
  /too many requests/i,
  /rate limit/i,
  /request limit/i,
  /compute unit/i,
  /capacity/i,
  /quota/i,
  /usage limit/i,
  /daily (?:request|compute) limit/i,
  /monthly (?:request|compute) limit/i,
  /50[234]\b/,
  /bad gateway/i,
  /service unavailable/i,
  /gateway timeout/i,
  /nonce too low/i,
  /already known/i,
  /replacement transaction underpriced/i,
  /transaction underpriced/i,
  /underpriced/i,
  /header not found/i,
  /missing response/i,
  /could not coalesce/i,
  /block is out of range/i,
  /no backend is currently healthy/i,
];

/** Transient = retrying the same operation with a fresh nonce/request may succeed. */
export function isTransientError(error: unknown): boolean {
  const text = error instanceof BaseError ? `${error.shortMessage} ${error.message}` : String(error);
  return TRANSIENT_PATTERNS.some((pattern) => pattern.test(text));
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
