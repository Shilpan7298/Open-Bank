# Security review, 2026-09-25

**Scope:** every contract in `contracts/src`, `script/DeployLib.sol` and the AI underwriter (`services/underwriter`). This was an adversarial read by the founding engineer (an AI agent), not an independent audit. **An external audit is still required before any real funds.** slither was not available in the build environment.

Each finding below has a concrete exploit, a fix, and a test in `contracts/test/` that performs the attack and shows it now fails.

## Summary

| ID | Severity | Title | Status |
|---|---|---|---|
| H-1 | High | Wash lending drains insurance and the reserve; credit history can be farmed | Fixed |
| H-2 | High | Insurers and vault depositors exit ahead of a known loss | Fixed |
| M-1 | Medium | Voucher bait-and-switch cancels loans at will | Fixed |
| M-2 | Medium | Auction slot squatting locks out cheaper lenders | Fixed |
| M-3 | Medium | Free-form purpose codes dodge the sector cap and bloat exit checks | Fixed |
| M-4 | Medium | A rogue vault allocator lends depositors' money at 0% | Fixed |
| L-1 | Low | Dust loans (1 wei) round in odd ways | Fixed |
| R-1 to R-8 | Residual | Accepted risks and operational requirements | Documented |

## H-1: Wash lending drains insurance and the reserve

**Where:** `RateAuction.placeBid`, `LoanRegistry._quoteDues`, `LossWaterfall.executeDefault` (before the fix).

**Exploit:**
1. A borrower proposes a loan with the maximum rate (50% APR) and term (2 years).
2. They post the minimum collateral and vouch the rest themselves from a second wallet.
3. They fund the loan from a third wallet.
4. They default.
5. The basket insured the whole lender claim, `lenderDue - collateral - cover`, including 100% interest. The basket and then the reserve paid it to the borrower's own lending wallet.

For P = 1,000 that was about 1,100 of insurer money for a 15 fee. The same self-funded loop also farms credit history. It costs little, since the "interest" goes back to the borrower. After four repaid loans the borrower is "Proven" and needs only 30% backing on a 50,000 limit, so each identity could drain about 35,000.

**Fix:**
- **One person, one wallet.** Identity attestations now carry a salted unique person id (`IdentityGate`). `personOf()` exposes it.
- **Independent lenders.** Direct lenders must be verified people, and not the borrower (`RateAuction._checkIndependentLender`). Protocol vaults, whose bids come from an accountable allocator, hold `EXEMPT_LENDER_ROLE`.
- **Principal-only insurance.** The basket and the reserve now cover unpaid principal only (`executeDefault(loanId, loss, insurableLoss)`), and insured exposure is `principal - collateral - cover`. Interest above that stays with the lenders who set the rate.

**Tests:**
- `test/security/Exploits.t.sol`: `test_H1_secondWalletCannotLend`, `test_H1_onePersonOneWallet`, `test_H1_insurersNeverPayInflatedInterest`.
- `LossWaterfall.t.sol`: `test_interestNotInsured` and the updated fuzz.
- The system invariant now checks that insurers never pay interest.

**Economic change:** lenders now bear interest loss on defaults; previously it was insured. This was open question 1 in progress.md, and the founder should confirm it.

## H-2: Exit before a known loss

**Where:** `InsuranceBasket.processWithdrawals`, `LenderVault.withdraw` (before the fix).

**Exploit:**
1. A covered loan misses an installment. Default can only be declared 30 days later.
2. An insurer who already gave notice has their withdrawal processed at full NAV before anyone calls `markDefault`.
3. Exits are limited only by free capital, which is `capital - exposure/3`. The late loan can take its full exposure, so the loss falls on those who stayed.

Lender-vault depositors could likewise withdraw idle cash at a stale share price.

**Fix:**
- `LoanRegistry.isLate` reports a missed installment.
- **Basket:** anyone can `flagLate` a covered late loan, and remaining insurers are the natural keepers. While any loan in a basket is flagged, `processWithdrawals` reverts. Flags clear when the loan catches up (`clearLate`) and automatically on repayment, cancellation or default settlement. Queued shares therefore absorb the loss.
- **Vault:** exits are paused while any open position is late (`hasLatePosition`, `maxWithdraw` returns 0).

**Tests:** `test_H2_insurersCannotExitWhileLoanLate`, `test_H2_flagRequiresRealLateness`, `test_H2_vaultExitsPausedWhileLate`.

## M-1: Voucher bait-and-switch

**Where:** `VouchingModule.unstake` (before the fix).

**Exploit:** a griefer stakes the entire cover cap, which blocks honest vouchers, then unstakes one block before the deadline. The loan fails its cover check and cancels. The attack costs only gas, and it can be repeated against any borrower.

**Fix:** stakes are binding like bids. They can be withdrawn only if the loan is cancelled.

**Tests:** `VouchingModuleTest.test_coverCannotBePulledBeforeDeadline` and `test_unstakeOnlyWhenCancelled`. VM-04 was rewritten because the rule changed.

## M-2: Auction slot squatting

**Where:** `RateAuction.placeBid` (before the fix).

**Exploit:** 100 bids of P/100 each at the maximum rate fill `MAX_BIDS`. Cheaper lenders get `TooManyBids`, so the borrower pays the maximum rate.

**Fix:** when the book is full, a strictly lower rate evicts the worst bid (highest rate, most recent first). The evicted escrow is withdrawn on a pull basis (`withdrawEvicted`), so a blacklisted address cannot block evictions.

**Tests:** `RateAuctionTest.test_maxBidsAndMinBid` (RA-09, rewritten for the new rule).

## M-3: Free-form purpose codes

**Where:** `LoanRegistry.propose` (before the fix).

**Exploit:** a borrower picks an unused sector code so the 25% sector concentration cap never binds. Every new code also adds a key that `InsuranceBasket.freeCapital` iterates over, so insurer exits become more expensive over time.

**Fix:** purposes are a governed list, `1..maxPurpose` (10 at launch). Each code has a plain-language name in `i18n`.

**Tests:** `test_M3_purposeCodesAreBounded`.

## M-4: Rogue allocator

**Where:** `LenderVault.bid` (before the fix).

**Exploit:** a compromised or colluding allocator bids depositors' money at 0% into a friend's loan.

**Fix:** a governed floor rate, `minRateBps` (5% at launch), can only be changed through the timelock.

**Tests:** `test_M4_allocatorCannotLendBelowFloor`.

## L-1: Dust loans

**Fix:** a governed `minPrincipal` (10 USDC at launch). **Test:** `test_L1_dustLoansRejected`.

## Residual risks (not fully fixable in code)

- **R-1: Colluding real people.** A verified accomplice can still fund a borrower's loan. Losses to insurers are now bounded by the principal gap: about 10% of P for a new borrower, net of the 1.5% fee. Both parties are identified people, so legal recovery applies in tier A. Credit farming with an accomplice is still possible. Options for the founder: require time seasoning for stage progression, or count only loans funded at least partly by independent vaults.
- **R-2: Self-declared purpose.** Within the 10 codes a borrower can still pick a false purpose. The AI underwriter should flag a mismatch between the proposal text and the code (next step).
- **R-3: Key compromise.** The KYC attester, scorer keys and allocator are trusted. Launch with ScoreOracle quorum of at least 2 independent scorers, and multisig or HSM keys for the attester and allocator.
- **R-4: Governance keys.** `script/Deploy.s.sol` (Anvil only) uses one proposer key and makes the deployer the guardian. Production needs a multisig proposer, a separate guardian, and a timelock delay of 2 days or more.
- **R-5: Keepers.** `markDefault`, `flagLate` and `processWithdrawals` need someone to call them. They are permissionless, and the parties at risk are incentivised to call them. Run a public keeper as well.
- **R-6: External dependencies.** A reverting sanctions oracle blocks claims and new activity, but never repayment or default. A USDC blacklist on a protocol contract would freeze it; this is an issuer risk.
- **R-7: Prompt injection.** A borrower's proposal can try to talk the model into a better band. Mitigations:
  - the proposal is fenced and marked untrusted;
  - verified data comes first;
  - the score can only raise cover;
  - consensus takes the most conservative score, and a quorum is supported;
  - the score never funds a loan.

  Residual: a manipulated band still selects the basket and premium rate.
- **R-8: Late-pause duration.** Exits stay paused until the late loan cures or someone calls `markDefault` after the 30-day grace. That is at most about grace plus keeper delay.

## Next

- Run slither and an independent audit.
- Invariant tests for H-2 under random lateness and cures.
- Underwriter check that the purpose code matches the proposal.
- The founder decides on R-1 (stage-progression seasoning) and confirms the H-1 change to the loss definition.
