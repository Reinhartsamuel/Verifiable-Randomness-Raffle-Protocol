import { ponder } from "ponder:registry";

import { raffle, participant, event as raffleEvent } from "../ponder.schema";
import { RaffledCoreAbi } from "../abis/RaffledCoreAbi";

async function upsertRaffle(
  context: any,
  raffleId: bigint,
  update: Record<string, unknown>,
) {
  const existing = await context.db.find(raffle, { id: raffleId });
  if (existing) {
    await context.db.update(raffle, { id: raffleId }).set(update);
  } else {
    await context.db.insert(raffle).values({ id: raffleId, ...update });
  }
}

function serializeData(
  args: Record<string, unknown>,
): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(args)) {
    out[key] = typeof value === "bigint" ? value.toString() : value;
  }
  return out;
}

function eventId(event: {
  transaction: { hash: string };
  log: { logIndex: number };
}) {
  return `${event.transaction.hash}-${event.log.logIndex}`;
}

// The deployed RaffledCore emits the pre-A0 RaffleCreated event (8 params —
// no ticketPrice/maxCap). Supplement them with one on-chain read.
const RAFFLED_CORE_ADDRESS = process.env.RAFFLED_CORE_ADDRESS ?? "0xc17eee20B4990021bE9cc8eCB7833706465bb8b9";

async function readTicketPriceAndMaxCap(context: any, raffleId: bigint) {
  try {
    const data: any = await context.client.readContract({
      address: RAFFLED_CORE_ADDRESS as `0x${string}`,
      abi: RaffledCoreAbi,
      functionName: "getRaffle",
      args: [raffleId],
    });
    return {
      ticketPrice: data.ticketPrice ?? data[8] ?? 0n,
      maxCap: data.maxCap ?? data[9] ?? 0n,
    };
  } catch (err) {
    console.warn(`[indexer] getRaffle(${raffleId}) read failed:`, err);
    return { ticketPrice: 0n, maxCap: 0n };
  }
}

async function insertEvent(
  context: any,
  event: any,
  values: {
    raffleId: bigint;
    eventName: string;
    from?: `0x${string}` | null;
    data: Record<string, unknown>;
  },
) {
  await context.db.insert(raffleEvent).values({
    id: eventId(event),
    raffleId: values.raffleId,
    eventName: values.eventName,
    from: values.from ?? null,
    data: values.data,
    txHash: event.transaction.hash,
    blockNumber: BigInt(event.block.number),
    blockTimestamp: BigInt(event.block.timestamp),
  });
}

ponder.on("RaffledCore:RaffleCreated", async ({ event, context }) => {
  const {
    raffleId,
    host,
    prizeAsset,
    prizeType,
    prizeAmountOrTokenId,
    expiry,
    prizeSymbol,
    decimals,
  } = event.args;

  const { ticketPrice, maxCap } = await readTicketPriceAndMaxCap(context, raffleId);

  await context.db.insert(raffle).values({
    id: raffleId,
    host,
    prizeAsset,
    prizeType: prizeType === 1 ? "ERC721" : "ERC20",
    prizeAmountOrTokenId,
    prizeSymbol,
    prizeDecimals: Number(decimals),
    ticketPrice,
    maxCap,
    totalTickets: 0n,
    expiry: BigInt(expiry),
    status: "OPEN",
    underfilled: false,
    createdAt: BigInt(event.block.timestamp),
  });

  await insertEvent(context, event, {
    raffleId,
    eventName: "RaffleCreated",
    from: host,
    data: {
      raffleId: raffleId.toString(),
      host,
      prizeAsset,
      prizeType: prizeType === 1 ? "ERC721" : "ERC20",
      prizeSymbol,
      ticketPrice: ticketPrice.toString(),
      maxCap: maxCap.toString(),
    },
  });
});

ponder.on("RaffledCore:TicketPurchased", async ({ event, context }) => {
  const { raffleId, buyer, ticketCount } = event.args;
  const participantId = `${raffleId}-${buyer}`;

  const existing = await context.db.find(participant, { id: participantId });
  if (existing) {
    await context.db.update(participant, { id: participantId }).set({
      ticketCount: existing.ticketCount + ticketCount,
    });
  } else {
    // amountPaid is 0: free entries are indistinguishable from paid entries
    // via this event alone. Requires an off-chain supplement if needed.
    await context.db.insert(participant).values({
      id: participantId,
      raffleId,
      user: buyer,
      ticketCount,
      amountPaid: 0n,
      isWinner: false,
      hasRefunded: false,
    });
  }

  const r = await context.db.find(raffle, { id: raffleId });
  if (r) {
    await context.db.update(raffle, { id: raffleId }).set({
      totalTickets: r.totalTickets + ticketCount,
    });
  }

  await insertEvent(context, event, {
    raffleId,
    eventName: "TicketPurchased",
    from: buyer,
    data: {
      raffleId: raffleId.toString(),
      buyer,
      ticketCount: ticketCount.toString(),
    },
  });
});

ponder.on("RaffledCore:WinnerPicked", async ({ event, context }) => {
  const { raffleId, winner } = event.args;

  await upsertRaffle(context, raffleId, {
    status: "COMPLETED",
    winner,
    resolvedAt: BigInt(event.block.timestamp),
  });

  const existing = await context.db.find(participant, {
    id: `${raffleId}-${winner}`,
  });
  if (existing) {
    await context.db.update(participant, { id: `${raffleId}-${winner}` }).set({
      isWinner: true,
    });
  }

  await insertEvent(context, event, {
    raffleId,
    eventName: "WinnerPicked",
    from: winner,
    data: { raffleId: raffleId.toString(), winner },
  });
});

ponder.on("RaffledCore:VRFRequested", async ({ event, context }) => {
  const { raffleId, requestId } = event.args;

  await upsertRaffle(context, raffleId, {
    status: "PENDING_VRF",
    vrfRequestId: requestId,
    vrfRequestedAt: BigInt(event.block.timestamp),
  });

  await insertEvent(context, event, {
    raffleId,
    eventName: "VRFRequested",
    data: {
      raffleId: raffleId.toString(),
      requestId: requestId.toString(),
    },
  });
});

ponder.on("RaffledCore:RaffleExpired", async ({ event, context }) => {
  const { raffleId } = event.args;

  // Expired with zero participants — contract already set COMPLETED.
  await upsertRaffle(context, raffleId, {
    status: "COMPLETED",
    underfilled: true,
    resolvedAt: BigInt(event.block.timestamp),
  });

  await insertEvent(context, event, {
    raffleId,
    eventName: "RaffleExpired",
    data: { raffleId: raffleId.toString() },
  });
});

ponder.on("RaffledCore:RaffleEmergencyFinalized", async ({ event, context }) => {
  const { raffleId } = event.args;

  await upsertRaffle(context, raffleId, {
    status: "CANCELLED",
    resolvedAt: BigInt(event.block.timestamp),
  });

  await insertEvent(context, event, {
    raffleId,
    eventName: "RaffleEmergencyFinalized",
    data: { raffleId: raffleId.toString() },
  });
});

ponder.on("RaffledCore:RaffleExpiredCancelled", async ({ event, context }) => {
  const { raffleId } = event.args;

  await upsertRaffle(context, raffleId, {
    status: "CANCELLED",
    resolvedAt: BigInt(event.block.timestamp),
  });

  await insertEvent(context, event, {
    raffleId,
    eventName: "RaffleExpiredCancelled",
    data: { raffleId: raffleId.toString() },
  });
});

ponder.on("RaffledCore:UnderfilledPrizeReturned", async ({ event, context }) => {
  const { raffleId, host, prizeAmountOrTokenId } = event.args;

  await upsertRaffle(context, raffleId, { underfilled: true });

  await insertEvent(context, event, {
    raffleId,
    eventName: "UnderfilledPrizeReturned",
    from: host,
    data: {
      raffleId: raffleId.toString(),
      host,
      prizeAmountOrTokenId: prizeAmountOrTokenId.toString(),
    },
  });
});

ponder.on("RaffledCore:PlatformFeeCollected", async ({ event, context }) => {
  const { raffleId, amount } = event.args;

  await insertEvent(context, event, {
    raffleId,
    eventName: "PlatformFeeCollected",
    data: { raffleId: raffleId.toString(), amount: amount.toString() },
  });
});

ponder.on("RaffledCore:UnderfilledPayout", async ({ event, context }) => {
  const { raffleId, winner } = event.args;

  await insertEvent(context, event, {
    raffleId,
    eventName: "UnderfilledPayout",
    from: winner,
    data: serializeData(event.args as Record<string, unknown>),
  });
});

ponder.on("RaffledCore:NFTPrizeAwarded", async ({ event, context }) => {
  const { raffleId, winner } = event.args;

  await insertEvent(context, event, {
    raffleId,
    eventName: "NFTPrizeAwarded",
    from: winner,
    data: serializeData(event.args as Record<string, unknown>),
  });
});

ponder.on("RaffledCore:TokenPrizeAwarded", async ({ event, context }) => {
  const { raffleId, winner } = event.args;

  await insertEvent(context, event, {
    raffleId,
    eventName: "TokenPrizeAwarded",
    from: winner,
    data: serializeData(event.args as Record<string, unknown>),
  });
});

ponder.on("RaffledCore:RefundClaimed", async ({ event, context }) => {
  const { raffleId, user, amount } = event.args;

  const existing = await context.db.find(participant, {
    id: `${raffleId}-${user}`,
  });
  if (existing) {
    await context.db.update(participant, { id: `${raffleId}-${user}` }).set({
      hasRefunded: true,
    });
  }

  await insertEvent(context, event, {
    raffleId,
    eventName: "RefundClaimed",
    from: user,
    data: {
      raffleId: raffleId.toString(),
      user,
      amount: amount.toString(),
    },
  });
});
