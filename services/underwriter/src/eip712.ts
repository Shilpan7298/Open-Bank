// SPDX-License-Identifier: AGPL-3.0-or-later
import { encodeAbiParameters, hashTypedData, keccak256, stringToBytes, type Address, type Hex, type LocalAccount } from "viem";
import type { Score } from "./schema.js";

/** Mirrors IScoreOracle.Score. Field order and types must match the Solidity struct exactly. */
export interface OnChainScore {
  loanId: bigint;
  borrower: Address;
  riskBand: number;
  pdBps: number;
  minVoucherCoverBps: number;
  expiry: bigint;
  rationaleHash: Hex;
  modelId: Hex;
}

export const SCORE_TYPES = {
  Score: [
    { name: "loanId", type: "uint256" },
    { name: "borrower", type: "address" },
    { name: "riskBand", type: "uint8" },
    { name: "pdBps", type: "uint16" },
    { name: "minVoucherCoverBps", type: "uint16" },
    { name: "expiry", type: "uint64" },
    { name: "rationaleHash", type: "bytes32" },
    { name: "modelId", type: "bytes32" },
  ],
} as const;

export function scoreDomain(chainId: number, verifyingContract: Address) {
  return { name: "OBP ScoreOracle", version: "1", chainId, verifyingContract } as const;
}

/** Canonical JSON of the full score (published off-chain; its hash goes on-chain). */
export function canonicalScoreJson(score: Score): string {
  return JSON.stringify({
    risk_band: score.risk_band,
    probability_of_default: score.probability_of_default,
    suggested_min_voucher_cover: score.suggested_min_voucher_cover,
    key_risks: score.key_risks,
    rationale: score.rationale,
    borrower_summary: score.borrower_summary,
    model_id: score.model_id,
  });
}

/** Convert a validated score to the on-chain struct. Cover rounds up (conservative), PD to nearest bp. */
export function toOnChainScore(score: Score, loanId: bigint, borrower: Address, expiry: bigint): OnChainScore {
  return {
    loanId,
    borrower,
    riskBand: score.risk_band,
    pdBps: Math.round(score.probability_of_default * 10_000),
    minVoucherCoverBps: Math.min(10_000, Math.ceil(score.suggested_min_voucher_cover * 10_000 - 1e-9)),
    expiry,
    rationaleHash: keccak256(stringToBytes(canonicalScoreJson(score))),
    modelId: keccak256(stringToBytes(score.model_id)),
  };
}

export function scoreDigest(s: OnChainScore, chainId: number, oracle: Address): Hex {
  return hashTypedData({ domain: scoreDomain(chainId, oracle), types: SCORE_TYPES, primaryType: "Score", message: s });
}

export async function signScore(account: LocalAccount, s: OnChainScore, chainId: number, oracle: Address): Promise<Hex> {
  return account.signTypedData({ domain: scoreDomain(chainId, oracle), types: SCORE_TYPES, primaryType: "Score", message: s });
}

/** Attestation data: `abi.encode(Score)`, which ScoreOracle decodes. All fields are static, so 256 bytes. */
export function encodeScoreData(s: OnChainScore): Hex {
  return encodeAbiParameters(
    [{ type: "tuple", components: SCORE_TYPES.Score.map((f) => ({ name: f.name, type: f.type })) }],
    [s],
  );
}
