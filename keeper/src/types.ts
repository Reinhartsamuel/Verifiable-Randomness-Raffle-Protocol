/** Enum mirror of `LotteryCore.RaffleStatus` (ABI encodes enums as uint8). */
export const RaffleStatus = {
  OPEN: 0,
  PENDING_VRF: 1,
  COMPLETED: 2,
  CANCELLED: 3,
  RESOLVED: 4,
} as const;

const STATUS_NAMES = ['OPEN', 'PENDING_VRF', 'COMPLETED', 'CANCELLED', 'RESOLVED'] as const;

export function raffleStatusName(status: number | bigint): string {
  const n = Number(status);
  return STATUS_NAMES[n] ?? `UNKNOWN(${n})`;
}

export function nowSeconds(): bigint {
  return BigInt(Math.floor(Date.now() / 1000));
}
