// SPDX-License-Identifier: AGPL-3.0-or-later
import { z } from "zod";

/** Risk bands 1 (lowest risk) to 5 (highest). Must match `ScoreOracle` and `InsuranceBasket` on-chain. */
export const MIN_RISK_BAND = 1;
export const MAX_RISK_BAND = 5;

/** Model output after parsing. Probabilities and cover are fractions in [0, 1]. */
export const ScoreSchema = z
  .object({
    risk_band: z.number().int().min(MIN_RISK_BAND).max(MAX_RISK_BAND),
    probability_of_default: z.number().min(0).max(1),
    suggested_min_voucher_cover: z.number().min(0).max(1),
    key_risks: z.array(z.string().min(1).max(280)).max(10),
    rationale: z.string().min(1).max(4000),
    /** Plain-language explanation for the borrower, in the borrower's language. */
    borrower_summary: z
      .object({
        language: z.string().regex(/^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$/),
        text: z.string().min(1).max(2000),
      })
      .strict(),
    model_id: z.string().min(1).max(100),
  })
  .strict();

export type Score = z.infer<typeof ScoreSchema>;

/** Parse and validate untrusted model output. Throws on anything that does not match the schema. */
export function parseScore(raw: unknown): Score {
  return ScoreSchema.parse(typeof raw === "string" ? JSON.parse(raw) : raw);
}
