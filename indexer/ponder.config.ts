import { createConfig } from "ponder";
import { createTransport, http, type Transport } from "viem";

import { RaffledCoreAbi } from "./abis/RaffledCoreAbi";

const RAW_DATABASE_URL = process.env.DATABASE_URL;

if (!RAW_DATABASE_URL || !RAW_DATABASE_URL.startsWith("postgres")) {
  throw new Error(
    "FATAL: DATABASE_URL is not set or is not a Postgres connection string. " +
      "This indexer requires an external Postgres database (e.g. Aiven) and REFUSES to start with the embedded PGlite database. " +
      "Set DATABASE_URL in .env (e.g. postgres://user:pass@host:port/dbname?sslmode=require) and restart.",
  );
}

const RPC_URL = process.env.PONDER_RPC_URL_84532;

if (!RPC_URL) {
  throw new Error(
    "FATAL: PONDER_RPC_URL_84532 is not set. This indexer requires an API-keyed RPC " +
      "(e.g. Alchemy/QuickNode) because free public RPCs Cloudflare-ban datacenter IPs. " +
      "Set PONDER_RPC_URL_84532 in .env.local and restart.",
  );
}

// Realtime newHeads subscription endpoint. Ponder polls (1s) instead of
// subscribing whenever `ws` is undefined, so derive the wss URL from the
// same API key (https://... -> wss://...). Override with PONDER_WS_URL_84532
// if the provider's ws endpoint differs from the http one.
const WS_URL = process.env.PONDER_WS_URL_84532 ?? RPC_URL.replace(/^http/, "ws");

// viem 2.35.0 has no rateLimit transport export, so wrap http() with a global
// minimum-interval gate instead. ZAN free tier caps throughput at ~270
// credits/s (~20 req/s); Ponder's 10-request concurrency bursts past that
// cap, every burst 429s, and the retries amplify into a storm that burns the
// monthly credit allowance. 4 req/s stays far under the cap, so the backfill
// (~260 requests) finishes in ~1-2 minutes with zero retries and no bleed.
function rateLimitedHttp(url: string, requestsPerSecond: number): Transport {
  const inner = http(url);
  const minIntervalMs = 1000 / requestsPerSecond;
  let nextSlot = 0;

  return ((args: any) => {
    const transport = inner(args);
    const request = transport.request.bind(transport);
    return createTransport(
      {
        key: "rate-limited-http",
        name: "HTTP (rate limited)",
        type: "http",
        // Ponder passes retryCount: 0 and handles retries itself at the
        // bucket level; mirror that so viem's buildRequest doesn't add
        // its own 3-retry layer on top.
        retryCount: args?.retryCount ?? 0,
        async request(body: any) {
          const now = Date.now();
          nextSlot = Math.max(nextSlot, now);
          if (nextSlot > now) {
            await new Promise((resolve) => setTimeout(resolve, nextSlot - now));
          }
          nextSlot += minIntervalMs;
          return request(body);
        },
      },
      transport.value,
    );
  }) as unknown as Transport;
}

// pg-connection-string >= 2.x treats sslmode=require/prefer/verify-ca as
// aliases for verify-full, i.e. it validates the server certificate against
// the system trust store. Aiven uses a private CA, so that fails with
// "Connection terminated unexpectedly". Opting into libpq compatibility
// keeps the connection encrypted but skips CA verification, which is the
// correct behavior for Aiven-style private-CA endpoints.
const DATABASE_URL =
  /[?&]sslmode=(require|prefer|verify-ca)(&|$)/.test(RAW_DATABASE_URL) &&
  !/[?&]uselibpqcompat/.test(RAW_DATABASE_URL)
    ? `${RAW_DATABASE_URL}${RAW_DATABASE_URL.includes("?") ? "&" : "?"}uselibpqcompat=true`
    : RAW_DATABASE_URL;

export default createConfig({
  database: {
    kind: "postgres",
    connectionString: DATABASE_URL,
  },
  chains: {
    baseSepolia: {
      id: 84532,
      // API-keyed RPC only. The public endpoints (sepolia.base.org,
      // publicnode, drpc) Cloudflare-ban the VPS's datacenter IP (HTTP 403
      // error code 1010), so as "failover" they only add retry spam.
      rpc: rateLimitedHttp(RPC_URL, 4),
      // Real-time newHeads via WebSocket (eth_subscribe). Without this,
      // Ponder polls eth_getBlockByNumber every 1s, which is what burns CU
      // even when idle. With ws, idle blocks arrive via subscription for
      // free; eth_getLogs only fires when a block's bloom filter matches
      // a RaffledCore event (i.e. actual raffle activity).
      ws: WS_URL,
      // Pin the eth_getLogs chunk size. Without this, Ponder's adaptive
      // range logic collapses the chunk to 1 block on RPC errors, turning
      // the ~2.6M-block backfill into millions of per-block requests that
      // exhaust free-tier CU quotas and drown PM2 logs in retry WARNs.
      ethGetLogsBlockRange: 1000,
    },
  },
  contracts: {
    RaffledCore: {
      chain: "baseSepolia",
      abi: RaffledCoreAbi,
      address:
        (process.env.RAFFLED_CORE_ADDRESS as `0x${string}` | undefined) ??
        "0xc17eee20B4990021bE9cc8eCB7833706465bb8b9",
      startBlock: 45269179,
    },
  },
});
