import { describe, expect, it } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { encodeScoreData, scoreDigest, signScore, toOnChainScore, type OnChainScore } from "../src/eip712.js";

// Shared with contracts/test/unit/UnderwriterVectors.t.sol.
const ORACLE = "0x1000000000000000000000000000000000000001";
const VECTOR: OnChainScore = {
  loanId: 42n,
  borrower: "0x00000000000000000000000000000000000000B0",
  riskBand: 3,
  pdBps: 600,
  minVoucherCoverBps: 6000,
  expiry: 2_000_000_000n,
  rationaleHash: `0x${"11".repeat(32)}`,
  modelId: `0x${"22".repeat(32)}`,
};
// Anvil account 2 (public test key).
const ANVIL_PK2 = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a";

describe("on-chain score encoding", () => {
  it("UW-04: EIP-712 digest and signature match ScoreOracle", async () => {
    expect(scoreDigest(VECTOR, 31337, ORACLE)).toBe("0xcefcfff942a15586bb5a318193c7d3f9f88f6ea8688b976b4f2f7643e6bc93ba");
    const sig = await signScore(privateKeyToAccount(ANVIL_PK2), VECTOR, 31337, ORACLE);
    expect(sig).toBe(
      "0x3bc570a96f1878cd92b538839a6953be01f9336a92ce6c84747c2eaf329e10bc2264a6ac430a77705e4212d33ea19df8017e0750a50f1cb89b099a49dce7e06e1b",
    );
  });

  it("UW-05: attestation data is abi.encode(Score)", () => {
    const data = encodeScoreData(VECTOR);
    expect((data.length - 2) / 2).toBe(256);
    expect(data.slice(2, 66)).toBe("2a".padStart(64, "0"));
    expect(data.endsWith("22".repeat(32))).toBe(true);
  });

  it("converts fractions conservatively", () => {
    const s = toOnChainScore(
      { risk_band: 2, probability_of_default: 0.03456, suggested_min_voucher_cover: 0.33333, key_risks: [], rationale: "r", borrower_summary: { language: "en", text: "s" }, model_id: "m" },
      1n,
      "0x00000000000000000000000000000000000000B0",
      1n,
    );
    expect(s.pdBps).toBe(346);
    expect(s.minVoucherCoverBps).toBe(3334); // rounds up
    const exact = toOnChainScore(
      { risk_band: 2, probability_of_default: 0, suggested_min_voucher_cover: 0.6, key_risks: [], rationale: "r", borrower_summary: { language: "en", text: "s" }, model_id: "m" },
      1n,
      "0x00000000000000000000000000000000000000B0",
      1n,
    );
    expect(exact.minVoucherCoverBps).toBe(6000);
  });
});
