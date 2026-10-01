import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  type Chain,
  type PublicClient,
  type WalletClient,
} from 'viem';
import { privateKeyToAccount, type PrivateKeyAccount } from 'viem/accounts';
import type { Hex } from 'viem';
import type { KeeperConfig } from './config.ts';

export const robinhoodMainnet = defineChain({
  id: 4663,
  name: 'Robinhood Chain',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.mainnet.chain.robinhood.com'] } },
});

export const robinhoodTestnet = defineChain({
  id: 46630,
  name: 'Robinhood Chain Testnet',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.testnet.chain.robinhood.com'] } },
  testnet: true,
});

const KNOWN_CHAINS: readonly Chain[] = [robinhoodMainnet, robinhoodTestnet];

export function chainForId(id: number): Chain {
  const known = KNOWN_CHAINS.find((chain) => chain.id === id);
  if (known) return known;
  return defineChain({
    id,
    name: `chain-${id}`,
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [] } },
  });
}

export interface PublicContext {
  chain: Chain;
  chainId: number;
  publicClient: PublicClient;
}

/** Public client for an explicit RPC URL (used for the separate log-scan RPC). */
export function createRpcClient(url: string, chain: Chain): PublicClient {
  return createPublicClient({ chain, transport: http(url, { retryCount: 2, timeout: 30_000 }) });
}

export async function createPublicContext(cfg: KeeperConfig): Promise<PublicContext> {
  const transport = http(cfg.rpcUrl, { retryCount: 2, timeout: 30_000 });
  const probe = createPublicClient({ transport });
  const detected = await probe.getChainId();
  const chain = chainForId(detected);
  const publicClient = createPublicClient({ chain, transport });
  return { chain, chainId: detected, publicClient };
}

export interface WalletContext {
  account: PrivateKeyAccount;
  walletClient: WalletClient;
}

export function createWalletContext(cfg: KeeperConfig, privateKey: Hex, chain: Chain): WalletContext {
  const account = privateKeyToAccount(privateKey);
  const walletClient = createWalletClient({
    account,
    chain,
    transport: http(cfg.rpcUrl, { retryCount: 2, timeout: 30_000 }),
  });
  return { account, walletClient };
}
