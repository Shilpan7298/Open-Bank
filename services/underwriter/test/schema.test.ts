import { describe, expect, it } from "vitest";
import { parseScore } from "../src/schema.js";

const valid = {
  risk_band: 2,
  probability_of_default: 0.03,
  suggested_min_voucher_cover: 0.4,
  key_risks: ["short repayment history"],
  rationale: "Verified income covers repayments 3x.",
  model_id: "mock-v1",
};

describe("parseScore", () => {
  it("accepts a valid score, as object or JSON string", () => {
    expect(parseScore(valid)).toEqual(valid);
    expect(parseScore(JSON.stringify(valid))).toEqual(valid);
  });

  it.each([
    ["band below range", { ...valid, risk_band: 0 }],
    ["band above range", { ...valid, risk_band: 6 }],
    ["fractional band", { ...valid, risk_band: 2.5 }],
    ["PD above 1", { ...valid, probability_of_default: 1.2 }],
    ["negative cover", { ...valid, suggested_min_voucher_cover: -0.1 }],
    ["missing rationale", { ...valid, rationale: undefined }],
    ["extra field", { ...valid, approve: true }],
  ])("rejects %s", (_name, raw) => {
    expect(() => parseScore(raw)).toThrow();
  });
});
