# Progress

## Status (end of session 1, 2026-09-25)

Phase 1 foundation is in place and green.

- All 11 contract modules from CLAUDE.md are implemented, plus `StakeVault` (the stake yield vault), `DeployLib` and an Anvil deploy script.
- **Foundry: 137 tests pass** (`forge test`): unit, fuzz, 12 stateful invariants (8 of them system-wide), e2e and deploy.
- **Underwriter: 21 tests pass** (`npx vitest run`), including a live Anvil end-to-end run. **Sim: 1 test passes.**
- `tests.json`: **137 of 138 planned tests pass** (see session 1b below). The one not started is IB-13, basket capital earning base yield (see Next).
- `./init.sh` takes a fresh clone to green in one command.

## Session 1b: global access and open collaboration

The founder set the direction: OBP is mainly for people in poor or broken economies (Egypt, Bangladesh, Argentina), in their own languages, and built in the open with collaborators worldwide. Recorded in CLAUDE.md ("Who it is for", "Open collaboration").

- **`i18n/`:** English source plus Arabic (RTL), Bengali and Spanish machine drafts (`needs_review`), 37 messages each. They cover loan states, every contract cancel reason, errors, plain-language concept explanations, repayment prompts and score summaries. `i18n/check.mjs` runs in init.sh and CI.
- **Underwriter:**
  - Reads proposals in any language.
  - Is told never to penalise language or writing quality, and to weigh local-currency risk.
  - Returns `borrower_summary` in the borrower's language. It is part of the hashed published score.
  - The mock uses the catalogs and local numerals: `ar-EG` gives Arabic-Indic digits, `bn-BD` Bengali digits, and plain `ar` Western digits.
  - Existing tests gained the new required fields (a spec extension, not a weakening). New tests: UW-08, UW-09, I18N-01.
- **Collaboration:**
  - README rewritten for newcomers, plus README.ar.md, README.bn.md and README.es.md.
  - CONTRIBUTING.md (with translation sections in each launch language), CODE_OF_CONDUCT.md and SECURITY.md.
  - Issue templates: bug, idea, translation, country insight. A pull-request template.
  - CI (`.github/workflows/ci.yml` runs `./init.sh`).
  - docs/good-first-issues.md (13 starter tasks) and docs/ROADMAP.md.
- **Waiting on the founder:**
  - Creating GitHub issues and labels from the starter list.
  - Enabling Discussions and private vulnerability reporting.
  - Repository visibility.
  - A contact email for conduct and security reports (currently @Shilpan7298 on GitHub).
  - Merging this branch to `main`.
- **Open question:** the stablecoin legal position differs sharply by country. Bangladesh's central bank has warned against crypto, Egypt restricts it, and Argentina uses stablecoins widely. This needs country legal review before any real funds (Phase 3).

## Session 1c: real-economy use and security review

- **Real economy.** `drawdownTo` pays a sanctions-screened off-ramp partner or supplier. Tests show anyone can repay on the borrower's behalf. Loan purposes have plain-language names in all four languages. See `docs/REAL_WORLD_USE.md`.
- **Security review.** Full report in `docs/SECURITY_REVIEW.md`. Two High, four Medium and one Low finding, all fixed, each with a proof test in `contracts/test/security/`. Eight residual risks are documented.
  - **H-1, wash lending:**
    - one wallet per person (identity attestations carry a person id);
    - direct lenders must be verified people other than the borrower (vaults exempt);
    - insurance and the reserve cover unpaid principal only.
  - **H-2:** insurer and vault exits pause while a covered loan is late.
  - **M-1:** voucher stakes are binding.
  - **M-2:** a better-rate bid evicts the worst when the book is full.
  - **M-3:** purpose codes are bounded to 1..10.
  - **M-4:** vault floor rate of 5%.
  - **L-1:** minimum principal of 10 USDC.
- **Tests changed because the specification changed** (none were weakened):
  - The LR-04, LR-12 and LR-18 and E2E-03/04/05 expectations encoded the old loss definition, where insurance covered lender interest. They now assert principal-only cover, and that lenders lose at most interest while insurers have capacity.
  - VM-04 encoded withdrawable stakes; it now asserts binding stakes.
  - RA-09 encoded "full book rejects all new bids"; it now asserts eviction by a better rate.
  - The system-invariant waterfall check now applies the insurable cap.
  - Fixtures onboard lenders (now required) and use purpose codes 1..10.
- **CI miss.** After H-1, CI failed because the underwriter's Anvil test still used the old identity encoding. I had run only `forge test` before pushing. It is fixed, and the full `./init.sh` now runs before every push.
- **Founder decisions:**
  - confirm principal-only insurance (it reverses the earlier interest-covered choice);
  - requiring KYC for direct lenders;
  - credit-farming mitigation (R-1);
  - repayment schedules and early-payoff refunds (`docs/REAL_WORLD_USE.md`).

## How to resume

1. `./init.sh`. It installs Foundry if needed, picks native solc or the solc-js fallback, builds, and runs all three suites.
2. `./scripts/fetch-upstream.sh` clones the upstream reference repos into `upstream/` (gitignored). Notes are in `docs/upstream-notes/`.
3. `scripts/set-test-status.py passing ID ...` updates `tests.json`.
4. Local chain: `anvil &` then, in `contracts/`, `forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast`. Addresses are written to `contracts/deployments/local.json`, which the underwriter reads.

## Environment notes (sandboxed cloud container)

- `foundry.paradigm.xyz`, GitHub release downloads and `binaries.soliditylang.org` are blocked here.
  - Foundry 1.7.1 is installed from npm (`@foundry-rs/forge|anvil|cast`).
  - solc 0.8.35 runs through solc-js behind a small CLI shim (`tools/solcjs/solc`).
  - `init.sh` detects this and writes `FOUNDRY_SOLC` into `contracts/.env`, which is gitignored and which forge reads.
  - On a normal machine, init.sh uses foundryup and native solc.
- `gh` is not installed. The five upstream forks (union-v2-contracts, goldfinch mono, huma-contracts-v2, ido-contracts, ethereum-credit-guild) were approved, but GitHub refused them: this session's access covers only shilpan7298/open-bank. They still need creating. Commands:
  - `gh repo fork unioncredit/union-v2-contracts --clone=false`
  - `gh repo fork goldfinch-eng/mono --clone=false`
  - `gh repo fork 00labs/huma-contracts-v2 --clone=false`
  - `gh repo fork gnosis/ido-contracts --clone=false`
  - `gh repo fork volt-protocol/ethereum-credit-guild --clone=false`
- The reference-only repos have no pin in UPSTREAM.md, so they are pinned to the HEAD cloned on 2026-09-25 (see `scripts/fetch-upstream.sh`).
- slither is not installed.

## What was built

| Module | Notes |
|---|---|
| ProtocolAccess | Shared base. The timelock holds DEFAULT_ADMIN (parameters, roles, unpause); the guardian can only pause. |
| IdentityGate | Re-validates the EAS identity attestation (schema, trusted attester, recipient, revocation, expiry) on every check. Country maps to tier; an unmapped country is tier C; Blocked countries can be reopened. Wallet-level sanctions oracle. |
| CreditRegistry | Repayment history and stage (New / Established after 2 repaid / Proven after 4). Tiered limits that step up per repaid loan and drop to 0 after any default. Stage x tier backing table; collateral can never be set below 20%. |
| CollateralEscrow | Per-loan collateral in the loan asset (no price oracle in Phase 1). Internal balances. Leftover collateral after a default stays for the borrower. |
| StakeVault | ERC-4626 (OZ, decimals offset 6). Only modules deposit. Phase 1 holds the asset idle; yield arrives as transfers. |
| VouchingModule | One fully funded slice per voucher per loan, held as stake-vault shares. States Open, Locked, Released / Defaulted / Cancelled. Staking closes at auction end. Losses are pro rata by construction. Blocked: self-vouching, sanctioned vouchers, vouchers with a default. |
| RateAuction | Written from scratch. 25 bps tick grid, clears at the lowest tick that covers principal, pro rata marginal fill rounded up, all-or-nothing funding, binding bids. MAX_BIDS = 100 with minBid = ceil(P/100). |
| LoanRegistry | Orchestrator. At settle it re-checks every funding condition and cancels on the first failure (reason emitted). Drawdown stores the agreement hash and takes the reserve fee. Equal installments. Repayments split cumulatively between lenders, voucher premium and insurance premium. Default is permissionless after the grace period. Lenders claim pro rata. |
| InsuranceBasket | One basket per (band, tier). Junior and senior NAV with virtual shares. Leverage <= 3x and per-key concentration <= 25% of capacity. FIFO withdrawal queue with 30 to 90 day epoch-rounded notice; queued shares keep absorbing losses. Exits pay only capital not needed for the limits. |
| ReserveVault | Fee of 1-2% of principal, reduced so reserve assets never exceed 5% of outstanding principal. `sync` rebates any excess. Acts as reinsurer. |
| LossWaterfall | The only place default losses are allocated: collateral, voucher stakes, basket junior then senior, reserve, then lenders. Each layer takes min(remaining, its capacity for the loan). |
| ScoreOracle | Score = EAS attestation carrying `abi.encode(Score)` plus an EIP-712 signature by a registered scorer. Quorum of distinct scorers, most-conservative aggregation. Registration, expiry and revocation are re-checked at read time. |
| LenderVault | ERC-4626 per band. A human allocator bids (the AI band only filters). Per-borrower and deployment caps. Positions valued conservatively; defaults hit the share price in the same block. Donations are inert. Exits are limited to idle cash. |
| services/underwriter | Verified data goes first; the proposal is fenced in delimited tags and marked untrusted. ClaudeScorer: `claude-opus-5`, adaptive thinking, JSON-schema output, server-side refusal fallbacks, zod validation. MockScorer: deterministic. EIP-712 signing, EAS attestation, ScoreOracle submit, CLI. The struct, domain and encoding are cross-checked by shared vectors on both sides. |
| sim/ | Launch parameters only (`obp_sim/params.py`). The Monte Carlo model is Prompt 2 work. |

## Decisions and reasons

Filling gaps in CLAUDE.md. None of these changes a stated parameter or the waterfall order.

1. **Loss definition.** The loss at default is the lenders' unpaid contractual claim (principal plus interest at the clearing rate), and the waterfall covers all of it. Unpaid voucher and insurance premiums are simply lost to those layers. This keeps lenders last and makes the basket's insured exposure `lenderDue - collateral - voucher cover`.
2. **Required voucher cover.** It is max(stage x tier table, AI score's suggestion): the score can only raise it. Tier C additionally needs collateral + cover >= principal at settle.
3. **Launch values inside CLAUDE.md ranges.** All governable; tune in sim/.

   Stage x tier table (collateral / cover):

   | Stage | A | B | C |
   |---|---|---|---|
   | New | 30 / 60 | 35 / 75 | 40 / 90 |
   | Established | 25 / 20 | 30 / 30 | 35 / 40 |
   | Proven | 20 / 10 | 25 / 10 | 30 / 10 |

   Credit limits (base / step / max): A 2k / 2k / 50k, B 1k / 1k / 20k, C 500 / 500 / 5k.

   Everything else:
   - Voucher premium: 4% APR on staked principal.
   - Insurance premium: band x 1% plus 0.5% per tier step.
   - Senior premium haircut: 30% (junior earns more for going first).
   - Reserve fee: 1.5%.
   - Default grace: 30 days after a missed installment.
   - Auction: 3 days. Drawdown window: 7 days. Notice: 30 days, rounded up to 7-day epochs.
4. **Concentration cap denominator.** The cap is measured against basket capacity (3x capital), not current exposure; otherwise a new basket could never take its first loan. Consequence: one origination month can hold at most 25% of capacity, which throttles origination pace per basket. The E2E bad-year test needed four months and eight countries to fill a basket.
5. **Basket exits.** Exits must keep leverage *and* concentration within limits, so the basket tracks active keys per dimension to compute the largest concentration on exit.
6. **Exposure removal.** Exposure is removed only on full repayment, cancellation or default settlement, never on a date (Nexus pitfall). Partial repayments do not reduce basket exposure (conservative).
7. **Reserve.** Excess above the cap goes to a governance-set rebate recipient, which must be non-zero so the cap always holds. `totalOutstandingPrincipal` counts the full principal of Active loans.
8. **Repayment always works.** Repay, markDefault, claims and exits are never paused. Payouts to sanctioned addresses revert and the funds stay put: collateral, stake claims, lender claims, refunds and basket withdrawals are all pull-based.
9. **Rounding.** Rounding is in the protocol's favour throughout: dues round up, claims round down, auction fills round up (dust stays in the auction), and stake loss absorption burns shares rounded up.
10. **Repayment split.** It uses nested two-way splits so that every party's cumulative share is monotone and exact at full repayment. Independent floors can make one share go down by 1 wei.
11. **Module order.** RateAuction, ScoreOracle, ReserveVault, InsuranceBasket and LossWaterfall were built before LoanRegistry, so LoanRegistry could be tested against real modules rather than mocks.
12. **Licences.** No upstream code was copied except the EAS `Attestation` struct and interface (MIT, recorded in NOTICE.md). Everything else was written from the notes, so no GPL-3.0-only (Nexus) or header-less (EasyAuction) code is in the tree.

## Tests corrected while being written

Each of these was a newly written test, wrong before it ever passed. The contract code was not changed to make any of them pass.

- VM-04: wrong expected balance (`before` was read after the first stake).
- RA-09: reused an end time already in the past after a warp.
- InsuranceBasket IB-02/03/04/12: setups put more than 25% of capacity on one key or one origination month, which the concentration rule correctly rejects. Setups now spread loans over months, and the fuzz bound matches the rule.
- LR-07, GOV-05, the system handler: `vm.prank` / `expectRevert` was consumed by an external call inside the argument list. Values are now computed first.
- LR-16 fuzz: six random parts could exceed the total due.
- LV-06: the 10% per-borrower cap legitimately blocked the bid. The test now raises caps, since it tests idle limits.
- E2E-01: forgot the refund of lender 2's unfilled bid.
- E2E-04/05: all borrowers shared one country, so the country cap blocked the third loan (correctly).
- Deploy script: the Anvil account-2 private key had one wrong hex digit. It is now derived from the standard mnemonic.
- System invariant handler: the first version funded almost no loans, so the invariants were vacuous. It was reworked with state-directed actions and weighted selectors. Measured: about 95% of runs fund loans and about 90% reach a default.

## Open questions for the founder (economic design and licences)

1. Should the waterfall cover lender interest (current choice) or principal only?
2. Is the concentration denominator = capacity acceptable, given it caps origination per basket per month at 25% of capacity?
3. When the loan book runs off, the reserve cap falls to 0 and everything is rebated. Should there be a minimum reserve floor?
4. Should the basket require a minimum junior share (say 20% of capital)? Without one, junior can exit first and leave senior as first loss.
5. Should vouchers be allowed to bid on the loan they vouch for? Currently they can; only the borrower is blocked.
6. Licences for later adaptation, for the lawyer:
   - Nexus files are GPL-3.0-only.
   - The EasyAuction core files have no SPDX header (repo LICENSE is LGPL-3.0, version unclear).
   - Goldfinch `Accountant` / `TranchingLogic` import `FixedPoint.sol`, which is AGPL-3.0-only.

## Next (in order)

1. **IB-13.** Hold basket capital in the stake vault so insurers earn base yield. Needs a design for vault withdrawal rounding (burned shares round up) so book value can never exceed vault value.
2. **Late-loan handling.** Freeze basket withdrawals and mark down LenderVault positions while a covered loan is late. Today exposure stays until settlement, and the 30-day notice is at least as long as the 30-day default grace. Consider epoch withdrawals for LenderVault too.
3. **Recovery after default.** Legal recovery, returned in reverse waterfall order. Phase 1 has no recovery path yet.
4. **Prompt 2 simulation in sim/**, then **Prompt 3 security review**. Install slither if possible.
5. Later phases (interfaces kept clean, not built): real EAS `attest` (AttestationRequest), zkTLS attestations, Chainlink feeds, multi-asset reserve, Kleros disputes, frontend, Base Sepolia.
