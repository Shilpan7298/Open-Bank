// SPDX-License-Identifier: AGPL-3.0-or-later
import Anthropic from "@anthropic-ai/sdk";
import { parseScore, type Score } from "./schema.js";
import { buildUserMessage, SYSTEM_PROMPT } from "./prompt.js";
import { number, percent, t } from "./i18n.js";
import type { LoanRequest, VerifiedData } from "./types.js";

export interface Scorer {
  score(verified: VerifiedData, request: LoanRequest): Promise<Score>;
}

export const MOCK_MODEL_ID = "mock-underwriter-v1";

/**
 * Deterministic scorer for tests and the simulation: a pure function of the verified data (the proposal text
 * cannot move it). No API key needed.
 */
export class MockScorer implements Scorer {
  async score(v: VerifiedData, request: LoanRequest): Promise<Score> {
    let band = v.repaidLoans >= 4 ? 1 : v.repaidLoans >= 2 ? 2 : 3;
    if (v.tier === "B") band += 1;
    if (v.tier === "C") band += 1;
    if (v.defaultedLoans > 0) band = 5;
    band = Math.min(5, band);
    const pd = [0.01, 0.03, 0.06, 0.12, 0.25][band - 1]!;
    const cover = [0.1, 0.3, 0.6, 0.8, 0.9][band - 1]!;
    return parseScore({
      risk_band: band,
      probability_of_default: pd,
      suggested_min_voucher_cover: cover,
      key_risks: v.repaidLoans === 0 ? ["no repayment history"] : [],
      rationale: `Mock score from verified data: ${v.repaidLoans} repaid, ${v.defaultedLoans} defaulted, tier ${v.tier}.`,
      borrower_summary: t(request.language, "underwriter.summary", {
        band: number(request.language, band),
        pd: percent(request.language, pd),
        cover: percent(request.language, cover),
      }),
      model_id: MOCK_MODEL_ID,
    });
  }
}

/** JSON schema the model must follow. Ranges are enforced afterwards by the zod schema. */
const OUTPUT_SCHEMA = {
  type: "object",
  properties: {
    risk_band: { type: "integer" },
    probability_of_default: { type: "number" },
    suggested_min_voucher_cover: { type: "number" },
    key_risks: { type: "array", items: { type: "string" } },
    rationale: { type: "string" },
    borrower_summary: {
      type: "object",
      properties: { language: { type: "string" }, text: { type: "string" } },
      required: ["language", "text"],
      additionalProperties: false,
    },
  },
  required: ["risk_band", "probability_of_default", "suggested_min_voucher_cover", "key_risks", "rationale", "borrower_summary"],
  additionalProperties: false,
} as const;

export class ScoringRefused extends Error {}
export class ScoringFailed extends Error {}

/** Minimal client surface, so tests can inject a fake. */
export interface MessagesClient {
  beta: { messages: { create(params: Anthropic.Beta.Messages.MessageCreateParamsNonStreaming): Promise<Anthropic.Beta.Messages.BetaMessage> } };
}

export class ClaudeScorer implements Scorer {
  constructor(
    private readonly client: MessagesClient = new Anthropic(),
    private readonly model = "claude-opus-5",
  ) {}

  async score(verified: VerifiedData, request: LoanRequest): Promise<Score> {
    const response = await this.client.beta.messages.create({
      model: this.model,
      max_tokens: 16000,
      thinking: { type: "adaptive" },
      output_config: { effort: "high", format: { type: "json_schema", schema: OUTPUT_SCHEMA } },
      // A safety decline is retried server-side on Anthropic's recommended fallback model.
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      system: SYSTEM_PROMPT,
      messages: [{ role: "user", content: buildUserMessage(verified, request) }],
    });
    if (response.stop_reason === "refusal") {
      throw new ScoringRefused(`model declined to score (${response.stop_details?.category ?? "no category"})`);
    }
    if (response.stop_reason !== "end_turn") throw new ScoringFailed(`unexpected stop_reason ${response.stop_reason}`);
    const text = response.content.find((b): b is Anthropic.Beta.Messages.BetaTextBlock => b.type === "text");
    if (!text) throw new ScoringFailed("no text block in response");
    let raw: unknown;
    try {
      raw = JSON.parse(text.text);
    } catch {
      throw new ScoringFailed("model output is not JSON");
    }
    // model_id records the model that actually served the request (a fallback may have run).
    return parseScore({ ...(raw as object), model_id: response.model });
  }
}
