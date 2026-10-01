#!/usr/bin/env -S deno run --allow-read --allow-write --allow-env

import { getAddress, Wallet } from "npm:ethers@6";

const EIP712_DOMAIN = {
  name: "LotteryCore",
  version: "1",
  chainId: 84532,
  verifyingContract: "0xaF5d21301B0454538836FcdC857eeFd7A0A96733",
};

const EIP712_TYPES = {
  FreeEntry: [
    { name: "raffleId", type: "uint256" },
    { name: "user",     type: "address"  },
  ],
};

function usage() {
  console.error([
    "Usage:",
    "  deno run --allow-read --allow-write --allow-env bulk-sign-free-entries.ts <csv-file> <signer-private-key> <raffleId> [chainId] [verifyingContract]",
    "",
    "Arguments:",
    "  csv-file           CSV of addresses to whitelist (one address per line, header optional)",
    "  signer-private-key Private key of the backend signer",
    "  raffleId           Target raffle",
    "  chainId            (optional) Defaults to 84532 (Base Sepolia)",
    "  verifyingContract  (optional) LotteryCore address, defaults to Base Sepolia deployment",
    "",
    "Output:",
    "  bulk-entries-<raffleId>.json  — {address, raffleId, signature} per entry + claim links",
    "",
    "Example:",
    "  deno run --allow-read --allow-write --allow-env bulk-sign-free-entries.ts whitelist.csv 0xac09... 3",
  ].join("\n"));
}

async function main() {
  const [csvPath, signerKey, raffleIdArg, chainIdArg, contractArg] = Deno.args;

  if (!csvPath || !signerKey || !raffleIdArg) {
    usage();
    Deno.exit(1);
  }

  const raffleId = BigInt(raffleIdArg);
  const chainId = chainIdArg ? Number(chainIdArg) : EIP712_DOMAIN.chainId;
  const verifyingContract = contractArg ?? EIP712_DOMAIN.verifyingContract;

  const domain = { ...EIP712_DOMAIN, chainId, verifyingContract };
  const signer = new Wallet(signerKey);

  // Read CSV: one address per line, skip empty lines and header if it looks like one
  const raw = await Deno.readTextFile(csvPath);
  const addresses = raw
    .split(/\r?\n/)
    .map((line) => line.trim().split(",")[0])
    .filter((line) => line.length > 0)
    .map((line) => {
      try {
        return getAddress(line);
      } catch {
        return null;
      }
    })
    .filter((addr) => addr !== null);

  if (addresses.length === 0) {
    console.error("Error: no valid addresses found in CSV");
    Deno.exit(1);
  }

  console.log(`Signer:    ${signer.address}`);
  console.log(`Raffle:    ${raffleId.toString()}`);
  console.log(`Addresses: ${addresses.length}`);
  console.log(`Contract:  ${verifyingContract} (chain ${chainId})`);

  const entries = [];
  for (const address of addresses) {
    const signature = await signer.signTypedData(domain, EIP712_TYPES, {
      raffleId,
      user: address,
    });
    entries.push({
      address,
      raffleId: Number(raffleId),
      signature,
      claimLink: `/app/raffle/${raffleId.toString()}?sig=${signature}`,
    });
  }

  const output = {
    signer: signer.address,
    contractAddress: verifyingContract,
    chainId,
    raffleId: Number(raffleId),
    entryCount: entries.length,
    entries,
  };

  const outputPath = new URL(`bulk-entries-${raffleId.toString()}.json`, `file://${Deno.cwd()}/`).pathname;
  await Deno.writeTextFile(outputPath, `${JSON.stringify(output, null, 2)}\n`);

  console.log(`\nOutput: ${outputPath}`);
  console.log(`Sample claim link: ${entries[0].claimLink}`);
}

main().catch((error) => {
  console.error(`Error: ${error.message}`);
  Deno.exit(1);
});
