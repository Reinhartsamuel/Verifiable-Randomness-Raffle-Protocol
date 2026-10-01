#!/usr/bin/env -S deno run --allow-read --allow-write --allow-env

import { getAddress, Wallet, ethers } from "npm:ethers@6";

const EIP712_DOMAIN = {
  name: "LotteryCore",
  version: "1",
  chainId: 84532,
  verifyingContract: "0x0000000000000000000000000000000000000000",
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
    "  deno run --allow-read --allow-write generate-whitelist-eip712.js <address> <signer-private-key> [raffleId] [output-json]",
    "",
    "Arguments:",
    "  address            Single address to sign",
    "  signer-private-key Private key of the backend signer",
    "  raffleId           (optional) Target raffle, defaults to 1",
    "  output-json        (optional) Output file, defaults to whitelist-eip712.json",
    "",
    "Example:",
    "  deno run --allow-read --allow-write generate-whitelist-eip712.js 0xf39... 0xac09... 1",
  ].join("\n"));
}

function buildDomain(contractAddress) {
  return {
    ...EIP712_DOMAIN,
    verifyingContract: contractAddress,
  };
}

async function main() {
  const userRaffleParticipantAddress = Deno.args[0];
  const backendAdminSignerPrivateKey = Deno.args[1];
  const raffleIdArg = Deno.args[2] ?? "1";
  const outputArg = Deno.args[3] ?? "whitelist-eip712.json";

  if (!userRaffleParticipantAddress || !backendAdminSignerPrivateKey) {
    usage();
    Deno.exit(1);
  }

  const user = getAddress(userRaffleParticipantAddress.trim());
  const raffleId = BigInt(raffleIdArg);
  const adminSignerOfficialWallet = new Wallet(backendAdminSignerPrivateKey);

  console.log(`Signer: ${adminSignerOfficialWallet.address}`);
  console.log(`User:   ${user}`);
  console.log(`Raffle: ${raffleId}`);

  const contractAddress = "0xaF5d21301B0454538836FcdC857eeFd7A0A96733";
  const domain = buildDomain(contractAddress);

  // Sign — signTypedData handles EIP-712 hashing internally (standard padded encoding).
  const signature = await adminSignerOfficialWallet.signTypedData(domain, EIP712_TYPES, {
    raffleId,
    user,
  });

  const output = {
    signer: adminSignerOfficialWallet.address,
    contractAddress,
    chainId: EIP712_DOMAIN.chainId,
    entry: {
      address: user,
      raffleId: Number(raffleId),
      signature,
    },
  };

  const outputPath = new URL(outputArg, `file://${Deno.cwd()}/`).pathname;
  await Deno.writeTextFile(outputPath, `${JSON.stringify(output, null, 2)}\n`);

  console.log(`\nSignature: ${signature}`);
  console.log(`Output: ${outputPath}`);
}

main().catch((error) => {
  console.error(`Error: ${error.message}`);
  Deno.exit(1);
});

// forge script script/DeployFreeEntryVerifier.s.sol --broadcast --private-key 0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6 --rpc-url http://localhost:8545
// deno run --allow-read --allow-write ./EIP712Sign/contoh-code-generate-whitelist-eip712.js 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65 0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356 1
// source .env && cast call 0xaF5d21301B0454538836FcdC857eeFd7A0A96733 "recoverSigner(uint256,address,bytes)" 1 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65 0x82f1a97b713f459c062f015675ad9366b586483f0109fb66445d92462af4c76545e8fe509d308a4ecedaad64a9ea3fe2450decda3f0ea8663451c3e96f24fbc31c --rpc-url $RPC_URL
// forge script script/DeployFreeEntryVerifier.s.sol --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $RPC_URL  --etherscan-api-key $ETHERSCAN_API_KEY --broadcast --verify