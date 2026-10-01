import { onchainEnum, onchainTable } from "ponder";

export const prizeType = onchainEnum("prizeType", ["ERC20", "ERC721"]);
export const raffleStatus = onchainEnum("raffleStatus", [
  "OPEN",
  "PENDING_VRF",
  "COMPLETED",
  "CANCELLED",
]);

export const raffle = onchainTable("raffle", (t) => ({
  id: t.bigint().primaryKey(),
  host: t.hex().notNull(),
  prizeAsset: t.hex().notNull(),
  prizeType: prizeType("prizeType").notNull(),
  prizeAmountOrTokenId: t.bigint().notNull(),
  prizeSymbol: t.text().notNull(),
  prizeDecimals: t.integer().notNull(),
  ticketPrice: t.bigint().notNull(),
  maxCap: t.bigint().notNull(),
  totalTickets: t.bigint().notNull().default(0n),
  expiry: t.bigint().notNull(),
  status: raffleStatus("status").notNull().default("OPEN"),
  underfilled: t.boolean().notNull().default(false),
  winner: t.hex(),
  vrfRequestId: t.bigint(),
  vrfRequestedAt: t.bigint(),
  createdAt: t.bigint().notNull(),
  resolvedAt: t.bigint(),
}));

export const participant = onchainTable("participant", (t) => ({
  id: t.text().primaryKey(), // "{raffleId}-{userAddress}"
  raffleId: t.bigint().notNull(),
  user: t.hex().notNull(),
  ticketCount: t.bigint().notNull(),
  amountPaid: t.bigint().notNull(),
  isWinner: t.boolean().notNull().default(false),
  hasRefunded: t.boolean().notNull().default(false),
}));

export const event = onchainTable("event", (t) => ({
  id: t.text().primaryKey(), // "{txHash}-{logIndex}"
  raffleId: t.bigint().notNull(),
  eventName: t.text().notNull(),
  from: t.hex(),
  data: t.jsonb().notNull(),
  txHash: t.hex().notNull(),
  blockNumber: t.bigint().notNull(),
  blockTimestamp: t.bigint().notNull(),
}));
