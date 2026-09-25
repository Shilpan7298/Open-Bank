# Open Banking Protocol (OBP)

An AI-assisted, community-backed credit protocol on Ethereum. Borrowers prove creditworthiness privately, lenders fund loans at market-set rates, and a four-layer loss waterfall keeps any single default, or a bad year, from bringing the system down. Think of it as a bank whose equity, provisions and guarantors are on-chain and whose rules are code.

## Who it is for

The main users are people in low-income countries and in economies with broken or unstable finance (for example Egypt, Bangladesh, Argentina): high inflation, currency controls, thin credit bureaus, banks that do not lend to them. Design for them first:
- **Their language.** Everything a borrower, voucher or small lender sees must be translatable. User-facing strings live in `i18n/` (one JSON catalog per language, English is the source); code never hard-codes user-facing text. The AI underwriter accepts proposals in any language and returns a plain-language explanation in the borrower's language. Launch languages: English, Arabic (right-to-left), Bengali, Spanish. Translations drafted by machine are marked `needs_review` until a native speaker checks them.
- **Their money.** Loans are in dollar stablecoins while incomes are in local currency, so currency devaluation is a first-class default risk (model it in `sim/` as a country shock; the underwriter should weigh local-currency income).
- **Their devices and connections.** Later-phase frontends must work on cheap Android phones and slow or intermittent connections. Keep on-chain interactions few and gas-light.
- **Their law.** Crypto and stablecoin rules differ by country and change often. Jurisdiction tiers and the blocked list are governable for this reason; legal review per country comes before any real funds.

## Open collaboration

OBP is built in the open for a global community. Keep the repo easy to join: `./init.sh` must stay one command to green, `CONTRIBUTING.md` describes the workflow, `docs/good-first-issues.md` lists starter tasks, and translation work is a first-class contribution. Anything visible outside the repo (creating issues, labels, discussions, changing visibility, announcements) needs the founder's OK first.

Status: Phase 1 (testnet MVP). No mainnet deployment and no real funds until contracts are audited and legal structure is in place.

## Why the design looks like this

Lending to strangers fails when default is free. Every rule below exists to make default costly for the borrower and survivable for the system:
- Collateral and voucher stakes are locked on-chain up front, never promised, so self-vouching through fake wallets gains nothing.
- Losses hit people who chose to take risk (vouchers, insurers) before people who did not (senior lenders).
- The AI score informs humans with capital at stake; it never approves or funds a loan on its own, because borrower-written proposals are untrusted input that can be crafted to game a model.
- Isolation and concentration caps stop correlated defaults (crypto crash, country shock) from spreading. The 2008 failure mode was baskets that looked diversified but defaulted together.

## Loan lifecycle

1. Onboard: KYC off-chain with the legal entity; zkTLS proofs (income, bank history, repayments) become EAS attestations. Sanctions screening at wallet level.
2. Propose: amount, term, purpose.
3. Score: one or more AI underwriters post signed risk scores + rationale as attestations. Advisory only.
4. Back: borrower locks collateral; vouchers stake in slices until required cover is reached.
5. Price and fund: batch auction on rate. Lenders bid directly (Kickstarter mode) or via automated vaults that bid within a risk band.
6. Insure: loan is assigned to the insurance basket for its risk band and jurisdiction tier.
7. Sign: borrower e-signs a Ricardian loan agreement (arbitration clause) whose hash is stored with the loan.
8. Repay: collateral and stakes released, vouchers paid premium, borrower's credit limit rises.
9. Default: waterfall executes; legal recovery starts where the tier allows it.

## Loss waterfall (strict order)

1. Borrower collateral
2. Voucher stakes
3. Insurance basket: junior tranche, then senior tranche
4. Protocol reserve (acts as reinsurer)
5. Senior lenders

Invariant: a lower layer never absorbs loss while a higher layer has remaining capacity for that loan.

## Parameters (governable, these are launch defaults)

| Parameter | Default |
|---|---|
| Borrower collateral | >= 20%; higher for new borrowers and tier B/C |
| Voucher cover | 10% to 90% of principal, many vouchers each covering a slice; required cover falls as repayment history grows |
| Insurance basket leverage | covered exposure <= 3x basket capital at launch |
| Insurance withdrawal notice | 30 to 90 days (epoch-based) |
| Basket concentration | <= 25% from any one country, sector, or origination month |
| Reserve funding fee | 1% to 2% of principal per loan |
| Reserve cap | 5% of total outstanding principal; above cap, fee is reduced or excess rebated |
| Reserve assets | mostly stablecoins and tokenized T-bills across issuers; gold tokens <= 20% |
| Locked stakes | held in a low-risk yield vault so vouchers and insurers earn base yield while locked |
| Credit limits | start small, step up after each repaid loan |
| Target all-in borrower APR | about 9% to 13% |

Illustrative stage table (tune in simulation):

| Borrower stage | Voucher cover | Insurance basket |
|---|---|---|
| New | 60% to 90% | small or none |
| 2 to 3 loans repaid | 20% to 40% | picks up the middle |
| Proven | 0% to 10% | most of the cover |

## Jurisdiction tiers

- Tier A: New York Convention signatory, working courts, credit bureau. Lowest collateral, highest limits, legal recovery.
- Tier B: partial enforcement. More voucher cover.
- Tier C: no practical enforcement. Economic security only (collateral + stakes >= 100%).
- Blocked: comprehensively sanctioned jurisdictions only, on a governable list that can open automatically when sanctions are lifted. Everyone else is screened per wallet, not per country. A humanitarian route for blocked places may exist only through licensed institutions.

## Architecture

Contracts (Solidity, Foundry, target an Ethereum L2 such as Base; develop on Base Sepolia / Anvil):

- `LoanRegistry` loan state machine and terms, stores agreement hash
- `CollateralEscrow`
- `VouchingModule` slices, locked stakes, freeze and slash on default, voucher reputation
- `RateAuction` uniform-price batch auction on rate
- `LenderVault` ERC-4626 automated lending by risk band with exposure caps
- `InsuranceBasket` tranched pool per risk band and tier, capacity limit, epoch withdrawals
- `ReserveVault` fee intake, cap logic, reinsurer payouts
- `LossWaterfall` single place where default losses are allocated
- `CreditRegistry` credit limits, repayment history, tiers
- `IdentityGate` EAS attestation checks, sanctions oracle check
- `ScoreOracle` verifies signed AI scores, quorum of scorers
- Governance: OZ `TimelockController`, guardian pause

Off-chain (`services/`): AI underwriter (signs EIP-712 scores, publishes rationale), attestation issuer, simulation (`sim/`) for stress testing parameters.

## Upstream code

See `docs/UPSTREAM.md` for the vetted repo list, licenses, pinned commits and what each contributes. Rules:
- Copy or adapt code only from repos marked "incorporate". Keep original SPDX headers and copyright lines on adapted files, and record every adapted file in `NOTICE.md` with source repo, commit and path.
- Repos marked "reference only" (BUSL-1.1, CC-BY-NC-ND, Commons Clause, or no license file) may be read for ideas; do not copy their code, including small snippets.
- Project license for contracts: AGPL-3.0-or-later (required if Huma code is included; compatible with MIT, LGPL-3.0, GPL-2.0-or-later, GPL-3.0). Flag any GPL-2.0-only file before using it. The founder will confirm license choices with a lawyer.

## Commands

- `./init.sh` install deps, build, run tests
- `forge build`, `forge test -vvv`, `forge test --match-contract Invariant`, `forge coverage`
- `forge fmt`, `slither .` (when installed)

## Working conventions

- Tests first for each module; track them in `tests.json`. Do not delete or weaken a test to make it pass; if a test is wrong, explain why in `progress.md` before changing it.
- Invariant and fuzz tests are the definition of done for anything that moves funds.
- Keep scope to what the current phase asks for. No speculative features or abstractions.
- Commit after each working increment with a descriptive message. Update `progress.md` at the end of each session.
- Ask before any action visible to others or hard to reverse: creating GitHub forks or repos, pushing, deploying, deleting branches.
- Never commit private keys or secrets. Use `.env` (gitignored) and Anvil default keys for tests.
- Keep chat replies short: what changed, test status, what is next or blocked.
