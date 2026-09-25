// SPDX-License-Identifier: AGPL-3.0-or-later
import type { Address } from "viem";

/** Borrower facts read from chain (EAS attestations, IdentityGate, CreditRegistry). Trusted. */
export interface VerifiedData {
  borrower: Address;
  country: number;
  tier: "A" | "B" | "C";
  repaidLoans: number;
  defaultedLoans: number;
  outstandingPrincipal: bigint;
  creditLimit: bigint;
  /** Further verified attestations (e.g. zkTLS income, bank history), already decoded. */
  attestations: { schema: string; attester: Address; fields: Record<string, string | number> }[];
}

/** What the lender and borrower asked for. The proposal text is untrusted: written by the borrower. */
export interface LoanRequest {
  loanId: bigint;
  principal: bigint;
  termDays: number;
  proposal: string;
}
