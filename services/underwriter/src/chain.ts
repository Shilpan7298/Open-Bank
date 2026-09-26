// SPDX-License-Identifier: AGPL-3.0-or-later
import { readFileSync } from "node:fs";
import {
  decodeAbiParameters,
  parseAbi,
  type Address,
  type Hex,
  type LocalAccount,
  type PublicClient,
  type WalletClient,
} from "viem";
import { encodeScoreData, signScore, type OnChainScore } from "./eip712.js";
import type { VerifiedData } from "./types.js";

export interface Deployment {
  chainId: number;
  eas: Address;
  identityGate: Address;
  creditRegistry: Address;
  loanRegistry: Address;
  scoreOracle: Address;
  scoreSchema: Hex;
  [name: string]: unknown;
}

export function loadDeployment(path: string): Deployment {
  return JSON.parse(readFileSync(path, "utf8")) as Deployment;
}

const TIERS = ["None", "A", "B", "C", "Blocked"] as const;

export const abis = {
  eas: parseAbi([
    "struct Attestation { bytes32 uid; bytes32 schema; uint64 time; uint64 expirationTime; uint64 revocationTime; bytes32 refUID; address recipient; address attester; bool revocable; bytes data; }",
    "function getAttestation(bytes32 uid) view returns (Attestation)",
    // MockEAS on local Anvil. Real EAS takes an AttestationRequest struct (Phase 2, Base Sepolia).
    "function attest(bytes32 schema, address recipient, uint64 expirationTime, bytes data) returns (bytes32)",
  ]),
  gate: parseAbi([
    "function identityOf(address) view returns (bytes32)",
    "function tierOf(uint16 country) view returns (uint8)",
    "function registerIdentity(bytes32 uid)",
  ]),
  credit: parseAbi([
    "struct History { uint32 repaidLoans; uint32 defaultedLoans; uint256 outstandingPrincipal; }",
    "function historyOf(address) view returns (History)",
    "function creditLimit(address, uint8 tier) view returns (uint256)",
  ]),
  oracle: parseAbi([
    "struct Consensus { bool ok; uint8 riskBand; uint16 pdBps; uint16 minVoucherCoverBps; uint256 count; }",
    "function submitScore(bytes32 attestationUid, bytes signature)",
    "function consensus(uint256 loanId, address borrower) view returns (Consensus)",
  ]),
  registry: parseAbi([
    "function propose(uint256 principal, uint64 term, uint16 numInstallments, uint16 maxRateBps, uint16 sector, bytes32 purposeHash) returns (uint256)",
    "function loanCount() view returns (uint256)",
  ]),
};

/** Read the borrower's verified facts from chain. Nothing here comes from the borrower's own text. */
export async function readVerifiedData(client: PublicClient, d: Deployment, borrower: Address): Promise<VerifiedData> {
  const uid = await client.readContract({ address: d.identityGate, abi: abis.gate, functionName: "identityOf", args: [borrower] });
  const att = await client.readContract({ address: d.eas, abi: abis.eas, functionName: "getAttestation", args: [uid] });
  // Identity attestation data: (uint256 country, bytes32 person). The person id is not needed for scoring.
  const [countryRaw] = decodeAbiParameters([{ type: "uint256" }, { type: "bytes32" }], att.data);
  const country = Number(countryRaw);
  const tierIdx = await client.readContract({ address: d.identityGate, abi: abis.gate, functionName: "tierOf", args: [country] });
  const tier = TIERS[tierIdx];
  if (tier !== "A" && tier !== "B" && tier !== "C") throw new Error(`borrower tier ${tier} cannot borrow`);
  const h = await client.readContract({ address: d.creditRegistry, abi: abis.credit, functionName: "historyOf", args: [borrower] });
  const limit = await client.readContract({ address: d.creditRegistry, abi: abis.credit, functionName: "creditLimit", args: [borrower, tierIdx] });
  return {
    borrower,
    country,
    tier,
    repaidLoans: h.repaidLoans,
    defaultedLoans: h.defaultedLoans,
    outstandingPrincipal: h.outstandingPrincipal,
    creditLimit: limit,
    attestations: [{ schema: "identity", attester: att.attester, fields: { country } }],
  };
}

/** Sign the score (EIP-712), publish it as an EAS attestation, and submit both to ScoreOracle. */
export async function publishScore(
  publicClient: PublicClient,
  wallet: WalletClient,
  account: LocalAccount,
  d: Deployment,
  score: OnChainScore,
): Promise<{ uid: Hex; signature: Hex }> {
  const signature = await signScore(account, score, d.chainId, d.scoreOracle);
  const data = encodeScoreData(score);
  const { result: uid, request } = await publicClient.simulateContract({
    account,
    address: d.eas,
    abi: abis.eas,
    functionName: "attest",
    args: [d.scoreSchema, score.borrower, 0n, data],
  });
  await publicClient.waitForTransactionReceipt({ hash: await wallet.writeContract(request) });
  const submit = await publicClient.simulateContract({
    account,
    address: d.scoreOracle,
    abi: abis.oracle,
    functionName: "submitScore",
    args: [uid, signature],
  });
  await publicClient.waitForTransactionReceipt({ hash: await wallet.writeContract(submit.request) });
  return { uid, signature };
}
