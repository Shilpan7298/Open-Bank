# Huma v2 — upstream notes for OBP InsuranceBasket

Source: `upstream/huma-contracts-v2` @ 21aaad5302 (tag v2.2.0, "Merge PR #488 release-v2.2.0"). Paths below are relative to `upstream/huma-contracts-v2/`. Repo LICENSE is AGPL-3.0; every `.sol` under `contracts/` is `AGPL-3.0-or-later` except `contracts/common/utils/BokkyPooBahsDateTimeLibrary.sol` and one mock (MIT). No GPL-2.0-only / GPL-3.0-only / BUSL files found (`grep -r SPDX contracts` gives 58 AGPL-3.0-or-later and 2 MIT).

Huma v2 is a single-pool design: one `Pool` with a `PoolSafe` (the cash), a senior and junior `TrancheVault`, up to 16 `FirstLossCover` (FLC) contracts, one `EpochManager`, one tranche policy, one `PoolFeeManager`, and a `Credit`/`CreditManager` pair that calls into `Pool` on profit, loss and recovery. Amounts are stored as `uint96`. Time uses a 30/360 calendar (`common/SharedDefs.sol:4-7`, `DAYS_IN_A_YEAR = 360`).

---

## 1. How the mechanism works

### 1.1 State that matters

- `Pool.tranchesAssets {seniorTotalAssets, juniorTotalAssets}` (`liquidity/Pool.sol:24-27,50`): the book value of each tranche. This is the NAV used to price tranche shares (`TrancheVault.totalAssets()` just reads it, `TrancheVault.sol:596-598`). It is internal accounting, not a token balance.
- `Pool.tranchesLosses {seniorLoss, juniorLoss}` (`Pool.sol:29-32,51`): cumulative unrecovered loss per tranche. It is pool-wide, not per loan.
- `FirstLossCover.coveredLoss` (`FirstLossCoverStorage.sol:12`): cumulative loss this FLC has paid out and not yet recovered. FLC NAV is `underlyingToken.balanceOf(this)` (`FirstLossCover.sol:314-316`), so the FLC holds its own cash. Tranche capital sits in `PoolSafe`.
- `FirstLossCoverConfig {coverRatePerLossInBps, coverCapPerLoss, maxLiquidity, minLiquidity, riskYieldMultiplierInBps}` (`common/PoolConfig.sol:87-98`). FLC slots by convention: `BORROWER_LOSS_COVER_INDEX = 0`, `INSURANCE_LOSS_COVER_INDEX = 1`, `ADMIN_LOSS_COVER_INDEX = 2` (`common/SharedDefs.sol:13-15`).
- `LPConfig {liquidityCap, maxSeniorJuniorRatio (uint8, default 4), fixedSeniorYieldInBps, tranchesRiskAdjustmentInBps, withdrawalLockoutPeriodInDays (default 90), autoRedemptionAfterLockup}` (`PoolConfig.sol:55-68,283-284`).
- `PoolSafe.unprocessedTrancheProfit[tranche]` (`PoolSafe.sol:32`): cash earmarked for per-period yield payouts to non-reinvesting lenders.
- Per tranche vault (`TrancheVaultStorage.sol:12-57`): `epochRedemptionSummaries[epochId] {epochId, totalSharesRequested, totalSharesProcessed, totalAmountProcessed}`, `lenderRedemptionRecords[lender] {nextEpochIdToProcess, numSharesRequested, principalRequested, totalAmountProcessed, totalAmountWithdrawn}`, `depositRecords[lender] {principal, reinvestYield, lastDepositTime}`.
- `EpochManager._currentEpoch {id, endTime}` (`EpochManager.sol:26-29,48`). The epoch length is the pool's `payPeriodDuration` (monthly, quarterly or semi-annual), aligned to calendar period starts (`_createNextEpoch`, `EpochManager.sol:166-177`).

### 1.2 Profit (repayments of yield and fees)

`Credit._makePayment` calls `pool.distributeProfit(yieldPastDuePaid + yieldDuePaid + lateFeePaid)` for a performing credit (`credit/Credit.sol:410-416`). Principal repaid is not profit; it only returns cash to `PoolSafe`. In `Pool._distributeProfit` (`Pool.sol:312-357`):
1. Admin fees come off the top: `PoolFeeManager.distributePoolFees` → `_getPoolFees` (`PoolFeeManager.sol:351-368`): `protocol = profit*protocolFeeBps`; then pool-owner and EA fees are rates applied to the remainder. The fees are accrued, not moved out.
2. `tranchesPolicy.distProfitToTranches(poolProfit, assets)` (`BaseTranchesPolicy.sol:16-42`) pays senior first, then splits what is left between junior and the FLCs.
   - RiskAdjusted (`RiskAdjustedTranchesPolicy.sol:13-31`): `seniorProfit = profit * S * (10000 - adjBps) / (10000 * (S + J))`. Senior gets its pro-rata share minus a bps haircut that shifts to junior.
   - FixedSeniorYield (`FixedSeniorYieldTranchesPolicy.sol:59-77,93-112`): a daily tracker accrues `unpaidYield += S * fixedBps * days / (360*10000)`, and senior takes `min(profit, unpaidYield)`. Senior does not absorb a profit shortfall as a loss. The unpaid yield just carries forward.
   - Junior/FLC split (`BaseTranchesPolicy.sol:95-124`): `weight_i = flcAssets_i * riskYieldMultiplierInBps_i / 10000`, `totalWeight = J + Σ weight_i`, `flcProfit_i = remaining * weight_i / totalWeight`, and junior gets the rest (rounding dust goes to junior).
3. Tranche profits are added to `tranchesAssets` and recorded in `PoolSafe.addUnprocessedProfit`. FLC profits go to `FirstLossCover.addCoverAssets` (`FirstLossCover.sol:171-176`), which pulls cash from PoolSafe into the FLC. FLC balance above `maxLiquidity` is paid out pro rata to providers by `payoutYield()` (`FirstLossCover.sol:232-267`).

### 1.3 Loss: exact order

Default is recognized only by `CreditManager._triggerDefault` (`credit/CreditManager.sol:317-343`), which `CreditLineManager.triggerDefault` exposes to the Evaluation Agent only (`CreditLineManager.sol:95-108`). It requires `missedPeriods >= 1` and at least `defaultGracePeriodInDays` elapsed since the start of the first missed period (`_isDefaultReady`, `CreditManager.sol:488-504`). Then:
- `principalLoss = unbilledPrincipal + nextDue - yieldDue + principalPastDue`, `yieldLoss = yieldDue + yieldPastDue`, `feesLoss = lateFee`.
- **First** `pool.distributeProfit(yieldLoss + feesLoss)`: unpaid yield and fees are booked as profit (admins accrue fees on it). **Then** `pool.distributeLoss(principalLoss + yieldLoss + feesLoss)`.

`Pool._distributeLoss` (`Pool.sol:365-377`) applies the loss in this order:
1. **FLCs in index order 0 → n-1** (borrower cover, then insurance cover, then admin cover): `loss = _firstLossCovers[i].coverLoss(loss)`. Each FLC pays (`FirstLossCover._calcLossCover`, `FirstLossCover.sol:417-439`) `covered = min(loss, loss*coverRatePerLossInBps/10000, coverCapPerLoss, flcTotalAssets)`. The FLC transfers `covered` into PoolSafe and adds it to `coveredLoss`. The cap is **per loss event, not per loan**. With a rate below 100%, an FLC with spare capital still passes part of the loss down.
2. **Junior tranche**: `juniorLoss = min(J, loss)` (`Pool.sol:387`).
3. **Senior tranche**: `seniorLoss = min(S, loss - juniorLoss)` (`Pool.sol:397`, the fix for Spearbit 5.3.11). **Any remainder above S is dropped silently.** It is not returned or recorded. The comment at `Pool.sol:388-396` admits this happens because admin fees booked in step "First" never take loss.
4. `tranchesAssets` falls and `tranchesLosses` grows. There is no cash movement for tranches, because the missing cash was never repaid.

Loss is applied instantly at `triggerDefault`. Between the missed payment and the default (the `Delayed` state) there is **no impairment or mark-down**. Tranche NAV still includes the full principal.

### 1.4 Recovery: exact order (the reverse of loss)

After a default, every payment on the credit goes to `pool.distributeLossRecovery(amountToCollect)` in full (`Credit.sol:406-409`). There is no profit or principal split. `Pool._distributeLossRecovery` (`Pool.sol:423-434`) → `_distLossRecoveryToTranches` (`Pool.sol:441-476`):
1. Senior: `min(recovery, seniorLoss)` goes back into `seniorTotalAssets`, and `seniorLoss` shrinks by the same amount.
2. Junior: the same, capped at `juniorLoss`.
3. FLCs in **reverse** index order (admin, then insurance, then borrower): `FirstLossCover.recoverLoss` (`FirstLossCover.sol:211-226`) takes `min(coveredLoss, remaining)` and pulls that cash from PoolSafe into the FLC.
4. Anything left after that stays in PoolSafe with no owner. `_distributeLossRecovery` ignores the final remainder.

Recovery is pool-wide. It goes to whoever holds shares **now**, not to whoever held them when the loss hit. Huma handles this operationally: `docs/umls/sequence-diagrams/defaultHandling.puml` has the owner set `liquidityCap = 0` and every FLC `maxLiquidity = 0` after a default, so nobody can buy in cheaply before a recovery arrives.

### 1.5 Capacity / ratio

- Tranche deposit cap (`Pool.getTrancheAvailableCap`, `Pool.sol:226-243`): `cap = liquidityCap - (S+J)`. For senior, it is further limited to `max(J*maxSeniorJuniorRatio, S) - S`. It reads 0 after a junior loss (the fix for 5.5.4).
- FLC deposit cap: `maxLiquidity - flcAssets` (`FirstLossCover.sol:333-337,400-409`). `isSufficient()` checks `flcAssets >= minLiquidity` (`:280-282`). Only the admin FLC's sufficiency gates `enablePool` (`PoolConfig.sol:653-656`).

### 1.6 Epoch withdrawal queue, and whether pending redemptions absorb losses

- `TrancheVault.addRedemptionRequest(lender, shares)` (`TrancheVault.sol:328-398`) is rejected if `nextEpochStart < lastDepositTime + lockoutDays` (`:349-356`). This is a lockout after the last deposit. **It is not a notice period.** The request joins the *current* epoch and is processed when that epoch closes, so notice is at most one pay period. The shares move from the lender into the vault (`ERC20._transfer(lender, this, shares)`, `:395`). They stay in `totalSupply`. Principal is moved pro rata into `principalRequested`.
- **Pending requests keep absorbing losses and earning profit.** Escrowed shares are still in supply, and the price is set only at processing time: `price = trancheAssets * 1e18 / totalSupply` (`EpochManager.sol:207-213`). A loss or recovery before the epoch closes changes what the requester gets. Once processed, `executeRedemptionSummary` (`TrancheVault.sol:258-289`) burns the shares and moves `totalAmountProcessed` cash from PoolSafe to the vault. `tranchesAssets` is reduced (`EpochManager.sol:230`), so settled amounts no longer bear loss. The lender then pulls the money with `disburse()` (`:451-455,674-683`).
- `closeEpoch()` (`EpochManager.sol:104-114`) is permissionless once `block.timestamp > endTime`. It reverts if any `unprocessedTrancheProfit != 0` (`:180-188`, the fix for 5.3.20). `_processEpoch` (`:255-293`) works as follows:
  - `available = PoolSafe.getAvailableBalanceForPool()`, which is cash minus unwithdrawn admin fees minus unprocessed profit (`PoolSafe.sol:70-83`). Processing stops if `available <= minPoolBalanceForRedemption` (1 token unit).
  - **Senior first** (`_processSeniorRedemptionRequests`, `:305-327`): redeem `min(requested, available)`. Shares are recomputed with `ceilDiv` when there is a shortfall.
  - **Junior next** (`_processJuniorRedemptionRequests`, `:342-381`): `minJunior = ceilDiv(S_after, maxSeniorJuniorRatio)`, `maxRedeemable = min(available, J - minJunior)`. Junior can exit only down to the ratio floor.
  - Unprocessed shares roll into epoch `id+1` and merge with the new requests there (`TrancheVault.sol:272-281`). Allocation within an epoch is **pro rata by shares requested**. There is no FIFO priority across epochs.
- Per-lender settlement is lazy. `_getLatestLenderRedemptionRecord` (`TrancheVault.sol:756-800`) walks every epoch from `nextEpochIdToProcess` to `currentEpochId` and applies `amount += remaining * epochAmountProcessed / epochSharesRequested` and `remaining -= ceilDiv(remaining * sharesProcessed, sharesRequested)`.
- `cancelRedemptionRequest` (`:407-445`) returns shares and principal. It is disabled when `autoRedemptionAfterLockup`.
- Closing the pool (`Pool.closePool`, `Pool.sol:152-169`) sets `maxSeniorJuniorRatio = 0`, processes all pending requests, and sets `readyForFirstLossCoverWithdrawal`. Afterwards lenders use `withdrawAfterPoolClosure` (`TrancheVault.sol:461-487`).
- FLC capital is **not** on an epoch queue. `redeemCover` works only when the owner-set flag `readyForFirstLossCoverWithdrawal` is true (`FirstLossCover.sol:179-190`), which normally happens only at pool closure (the fix for 5.3.2).

### 1.7 CreditDueManager (repayment schedule, late fees)

All of it is in `credit/CreditDueManager.sol`:
- Yield: `principal * yieldInBps * days / (10000 * 360)` (`_computeYield`, `:416-423`). Per period, `yieldDue = max(accrued on principal, committed on committedAmount)` (`:188-195`).
- Principal due per period: `unbilled * minPrincipalRateInBps * days / (10000 * daysInPeriod)` (`:395-404`). For n skipped full periods the formula is `unbilled * (1 - (1-r)^n)` (`:384-393`). All remaining principal is due in the final period (`:214-218`) or once past maturity (`:141-146`).
- Bill refresh: `getNextBillRefreshDate` (`:267-277`) returns `nextDueDate + latePaymentGracePeriodInDays` when in GoodStanding with an unpaid due, and `nextDueDate` otherwise.
- Late: `_isLate` (`:341-382`). While late, `getDueInfo` (`:27-222`) moves due amounts to past due, counts `missedPeriods`, and sets state `Delayed`.
- Late fee: `refreshLateFee` (`:289-333`) computes `lateFee += lateFeeBps * max(outstandingPrincipal, committed) * days / (10000 * 360)`. It accrues daily from the missed due date, not from the end of grace. `totalPastDue = lateFee + yieldPastDue + principalPastDue`.
- Payoff: `unbilledPrincipal + nextDue + totalPastDue` (`:225-229`).
- Payment allocation (`Credit._makePayment`, `Credit.sol:269-430`): a partial past-due payment goes to yield past due, then late fee, then principal past due, then next due (yield before principal), then extra to unbilled principal. It is a pure view library over `CreditRecord`/`DueDetail` (`credit/CreditStructs.sol:47-89`).

---

## 2. Files and functions worth adapting

Every file listed is `// SPDX-License-Identifier: AGPL-3.0-or-later` (header line read for each). **None are GPL-2.0-only or GPL-3.0-only.** Adapting any of them makes the OBP contract AGPL-3.0-or-later. That matches the project license in CLAUDE.md, but it must be recorded in `NOTICE.md`.

| File | Functions | Why |
|---|---|---|
| `contracts/liquidity/Pool.sol` | `_distributeLoss(uint256)`, `_distLossToTranches(uint256)`, `_distributeLossRecovery(uint256)`, `_distLossRecoveryToTranches(uint256)`, `getTrancheAvailableCap(uint256)` | Junior-then-senior loss math, senior-then-junior recovery math, and the ratio-bounded senior cap |
| `contracts/liquidity/EpochManager.sol` | `closeEpoch()`, `_processRedemptionRequests(uint256)`, `_processEpoch(...)`, `_processSeniorRedemptionRequests(...)`, `_processJuniorRedemptionRequests(...)`, `_createNextEpoch(CurrentEpoch)` | Epoch batch pricing, the liquidity-limited partial fill with `ceilDiv` share rounding, and the ratio floor on junior exits |
| `contracts/liquidity/TrancheVault.sol` | `addRedemptionRequest(address,uint256)`, `executeRedemptionSummary(EpochRedemptionSummary)`, `_getLatestLenderRedemptionRecord(address,uint256)`, `_disburse()`, `_deposit(uint256)`, `_convertToShares(uint256,uint256)`, `convertToAssets(uint256)`, `transfer`/`transferFrom` overrides | Escrowed-share queue in which pending shares keep bearing P&L, lazy per-user settlement, and non-transferable shares |
| `contracts/liquidity/TrancheVaultStorage.sol` | structs `LenderRedemptionRecord`, `DepositRecord` | Record layout |
| `contracts/liquidity/interfaces/IRedemptionHandler.sol` | struct `EpochRedemptionSummary` | Per-epoch summary |
| `contracts/liquidity/FirstLossCover.sol` | `_calcLossCover(uint256)`, `coverLoss(uint256)`, `recoverLoss(uint256)` | Min-of-(rate, cap, assets) cover rule, a good template for per-loan cover limits |
| `contracts/liquidity/RiskAdjustedTranchesPolicy.sol` | `_calcProfitForSeniorTranche(uint256,uint96[2])` | One-line premium split between senior and junior, with a single rounding step |
| `contracts/liquidity/BaseTranchesPolicy.sol` | `distProfitToTranches(...)` | Senior-first split shape (drop the FLC part) |
| `contracts/credit/CreditDueManager.sol` | `getDueInfo(...)`, `refreshLateFee(...)`, `_isLate(...)`, `getNextBillRefreshDate(...)`, `_computeYield(...)`, `_computePrincipalDueForPartialPeriod(...)`, `_computePrincipalDueForFullPeriods(...)`, `getPayoffAmount(...)` | Repayment schedule and late fees for `LoanRegistry` (not for the basket) |
| `contracts/credit/CreditManager.sol` | `_isDefaultReady(PayPeriodDuration,uint256)` | Default-readiness rule based on missed periods plus a grace period |
| `contracts/common/Calendar.sol` | period helpers | Only if OBP adopts 30/360 period-aligned epochs. The date library it depends on is MIT (BokkyPooBah) |

Not worth adapting: `PoolFeeManager.sol` (admin fee accrual and FLC auto-investing), `FixedSeniorYieldTranchesPolicy.sol`, `PoolSafe.sol` (trivial; OBP should hold cash inside each basket), `PoolConfig*.sol` / `PoolConfigCache.sol` (upgradeable config plumbing), and `TrancheVault.processYieldForLenders` / `nonReinvestingLenders`.

---

## 3. Known pitfalls and audit findings

Audits: `audit/spearbit.pdf` (March 2024, v2.0.x) and `audit/spearbit-incremental-Nov-2024.pdf` (PR 481, one informational finding). Findings relevant to the basket, with Huma's resolution:
- **5.1.1 (High)**: `transfer` was disabled but `approve + transferFrom` was not. This let shares reach non-lenders, bypass the owner/EA liquidity check, and turn principal into "yield". Fixed: both are overridden (`TrancheVault.sol:577-590`, `FirstLossCover.sol:295-308`). OBP shares must be fully non-transferable, or the escrow and notice logic breaks.
- **5.2.2 (Medium)**: depositing on someone else's behalf reset their `lastDepositTime` lockout and could block their exit. Fixed by removing the receiver parameter. OBP rule: nobody can change another account's notice or lock clock.
- **5.2.1 (Medium)**: fee investment into the FLC reverted when the cap was below `minDepositAmount`, which blocked all fee withdrawals. The lesson: a min-deposit check must not sit on internal flows.
- **5.3.2 (Low)**: FLC providers could deposit just before profit distribution and redeem right after, earning without taking risk. Huma fixed it by locking FLC withdrawals until pool closure. For OBP this is the argument for a notice period plus lock-on-deposit.
- **5.3.4**: the junior redemption path lacked the minimum-balance guard (fixed, `EpochManager.sol:276`).
- **5.3.11**: senior loss was not capped at senior assets (fixed at `Pool.sol:397`). The capped remainder is still **silently dropped**. OBP must return it to the waterfall (reserve, then senior lenders).
- **5.3.16 (inflation attack)**: redeem down to 1 wei, then front-run the next depositor. Fixed by requiring the pool owner to keep `minDepositAmount` in each tranche (`PoolConfig.sol:743-767`). OBP needs a seeded, non-withdrawable minimum per basket tranche, or virtual shares.
- **5.3.18**: allocation is pro rata by *requested* shares, so a lender can over-request and cancel the excess after processing. Huma accepted this and documented it. OBP should forbid cancellation once the notice window is running, or make any cancellation restart the notice.
- **5.3.20**: an epoch could be closed before yield processing, which gave worse redemptions. Fixed by reverting on unprocessed profit (`EpochManager.sol:180-188`). That couples epoch close to an autotask. OBP can drop the problem by not paying yield out per period.
- **5.3.21**: once a loss drove tranche assets to 0 while supply was still above 0, share conversion divided by zero. Fixed so `_convertToShares` returns 0 and `_deposit` reverts `ZeroSharesMinted` (`TrancheVault.sol:654-658,734`). A wiped-out tranche is therefore **permanently undepositable**. OBP needs an explicit "tranche wiped: reset shares" path, or must retire the basket.
- **5.5.4**: senior cap underflowed after a junior loss (fixed with `Math.max`, `Pool.sol:237-240`).
- **5.5.30**: `unprocessedAmount` was computed before processing. It only affects an event.
- **Nov-2024 3.1.1**: the design of `autoRedemptionAfterLockup` means lockups are measured from the last deposit, and re-depositing extends them.

Pitfalls visible in the code, not raised by the audit:
- **No impairment before default.** A loan can sit in `Delayed` for `missedPeriods` plus `defaultGracePeriodInDays` at full NAV. Anyone watching can request redemption and exit at a price that ignores a known delinquency. Default is also **discretionary**: only the EA can call it (`CreditLineManager.sol:103-104`).
- **Recovery goes to current holders**, and there is no per-loan attribution (`Pool.sol:441-476`). The only mitigation is a manual procedure (`docs/umls/sequence-diagrams/defaultHandling.puml`).
- **Unpaid yield and fees are booked as profit at default** (`CreditManager.sol:336-337`), so admins earn fees on money never received, and tranches cover them.
- A recovery above all recorded losses becomes orphaned cash in PoolSafe (`Pool.sol:428-433`).
- FLC NAV is the token balance (`FirstLossCover.sol:314-316`), so direct transfers move the share price. Tranches use internal accounting, which is safer. Use the tranche approach.
- FLC per-loss rules (`coverRatePerLossInBps < 10000`) let a layer with spare capacity pass part of a loss down, which violates OBP's waterfall invariant if copied as-is.
- Unchecked `uint96(...)` downcasts appear throughout (e.g. `Pool.sol:399-404`, `EpochManager.sol:320-324`). `maxSeniorJuniorRatio` is an integer `uint8`, so fractional ratios are impossible.
- `_getLatestLenderRedemptionRecord` loops over every epoch since the lender's last touch (`TrancheVault.sol:771-790`). This is fine for monthly epochs and grows linearly with shorter ones.
- If `closeEpoch` is called late, `_createNextEpoch` computes the next end from the old `endTime`, so the new end can already be in the past and closes can happen back to back (`EpochManager.sol:169-172`).
- Tests: the liquidity layer has Hardhat unit tests only (`test/unit/liquidity/*.ts`, about 10k lines; loss and recovery cases in `test/unit/liquidity/PoolTest.ts:1001-1212`). The only Foundry fuzz/invariant harness covers Receivable (`test/foundry/Receivable.t.sol`, `test/foundry/handler/ReceivableHandler.sol`). **There are no invariant tests for the loss waterfall or the epoch queue**, so OBP must write its own.
- The one TODO in scope is unrelated (`contracts/factory/PoolFactory.sol:351`).

---

## 4. What OBP should change

**Keep (adapt from Huma):**
- Two-tranche NAV held as internal accounting, junior absorbing loss before senior, and recovery applied senior first then junior (the reverse of the loss order).
- Escrowed-share withdrawal requests that stay in supply until the epoch closes, priced at the epoch-close NAV. This gives OBP's "pending withdrawals absorb losses until settled" requirement directly.
- Epoch batch processing with partial fills, `ceilDiv` rounding in the basket's favor, unfilled remainders rolled forward, and lazy per-user settlement records.
- The RiskAdjusted premium split, used for basket premiums: senior gets its pro-rata share of premium minus `riskAdjBps`, and junior gets the rest.
- Non-transferable shares (both `transfer` and `transferFrom` blocked), a minimum seed deposit per tranche, and a reject on zero-share mints.
- CreditDueManager's schedule and late-fee formulas go into `LoanRegistry`/`CreditRegistry`, not into the basket.

**Change:**
- **Notice instead of lockout.** A request made at time t becomes eligible at the first epoch close at or after `t + noticePeriod` (30 to 90 days, governable per basket). Until then, and until it settles, the shares bear losses and earn premium. No cancellation after the request, or cancellation that restarts the notice (closes the 5.3.18 gaming).
- **Capacity constraint on exits.** Exits are limited by leverage rather than by cash: after settlement, `coveredExposure <= 3 * (J + S)` must still hold. A junior floor stays as well: `S <= maxSeniorJuniorRatio * J`, with a bps-precision ratio. Process pro rata within the eligible cohort. Settle junior no earlier than senior, as Huma does.
- **Per-loan attribution.** The basket must record `coverCommitted[loanId]` (the insured slice, set when the loan is assigned) and `lossPaid[loanId]` split by tranche. Payouts for a loan are capped at its committed cover (the Huma `coverCapPerLoss` idea, but per loan). Recovery for a loan is capped at what the basket paid for that loan, returned senior first, then junior, and never beyond.
- **Return the uncovered remainder.** `coverLoss` returns `uncovered` to `LossWaterfall`, which then calls `ReserveVault` and finally senior lenders. Nothing is dropped (unlike `Pool.sol:397`).
- **Impairment or freeze.** When a covered loan passes its late grace, `LossWaterfall` should call `impair(loanId, amount)`. That reduces the NAV used for withdrawal pricing (junior first) without moving cash, and it is reversed on cure. At minimum, withdrawal settlement for the basket should be blocked while any covered loan is impaired. Default triggering should be permissionless once `_isDefaultReady`-style conditions hold, not EA-only.
- **Recovery sniping.** While a basket has unrecovered `lossPaid`, block new deposits, or snapshot the loss to the holders at loss time. Simplest for Phase 1: block deposits until each defaulted loan is closed out, with a governable write-off date after which late recoveries go to `ReserveVault`.
- **No profit booking on default.** Only cash premiums are profit. Unpaid interest is not.
- **Concentration check at assignment.** Track `exposureBy[country]`, `exposureBy[sector]` and `exposureBy[originationMonth]`, and require each to stay `<= 25%` of basket capacity (`3 * capital`), not of current exposure, so a new basket can take its first loans. This is a design choice to confirm.
- Use OZ `SafeCast` and `uint256` storage (or checked casts). Use explicit bps for every ratio.

**Drop:**
- The FLC contracts inside the basket. Borrower collateral and voucher stakes are per-loan layers owned by `CollateralEscrow`/`VouchingModule`, applied by `LossWaterfall` before the basket. Huma's pool-wide "borrower FLC" does not fit.
- Also drop: `PoolFeeManager`, admin/EA fee accrual and fee-to-FLC investing, `FixedSeniorYieldTranchesPolicy`, non-reinvesting payouts, `unprocessedTrancheProfit`, `autoRedemptionAfterLockup` with its sentinel, pool-owner/EA liquidity requirements (keep only the seed minimum), `PoolConfigCache` plumbing, upgradeability, and receivables.

---

## 5. Minimal `InsuranceBasket` interface sketch (prose; one instance per (riskBand, tier))

State: `asset`, `riskBand`, `tier`, `epochLength`, `noticePeriod`, `maxLeverageBps (30000)`, `maxConcentrationBps (2500)`, `maxSeniorJuniorRatioBps`, `riskAdjBps`. Per tranche `k ∈ {junior, senior}`: `assets[k]`, `supply[k]`, `balance[k][user]`, `lossUnrecovered[k]`, `impairment[k]`. Plus `coveredExposure`, `exposureBy[dimension][key]`, per-loan `cover[loanId] {committed, paidJunior, paidSenior, recovered, open}`, per-epoch `pending[k][epoch] {sharesRequested, sharesSettled, amountSettled}`, per-user `request[k][user]` (Huma's `LenderRedemptionRecord` idea), and `claimable[user]`.

Views:
- `capital() = assets[J] + assets[S]`. `capacity() = capital * maxLeverageBps / 10000`. `availableCover() = capacity - coveredExposure`.
- `navForPricing(k) = assets[k] - impairment[k]`. `sharePrice(k) = navForPricing(k) / supply[k]`.
- `canCover(loanId, amount, country, sector, month)` returns true when `amount <= availableCover()` and each `exposureBy[...] + amount <= capacity * 2500/10000`.

Capital side:
- `deposit(tranche, assets)`: IdentityGate-checked caller. Reverts while `lossUnrecovered > 0` (the anti-sniping rule) or if the senior deposit would breach `S <= ratio*J`. Mints `assets * supply / nav`, rejects zero shares, and the first deposit needs the seed minimum.
- `requestWithdraw(tranche, shares)`: moves the shares into escrow (still in `supply`) and sets `eligibleEpoch = first epoch ending >= now + noticePeriod`. No cancel, or cancel restarts the notice.
- `closeEpoch()`: permissionless after `epochEnd`. For eligible requests, prices at `navForPricing` (impairment included) and fills pro rata within each tranche. The fill is limited by (a) post-exit `coveredExposure <= capacity`, (b) `S <= ratio*J`, and (c) no open impairment on the basket (Phase 1: skip settlement if any). It burns the filled shares, moves the amount from `assets[k]` into `claimable`, and rolls unfilled shares forward.
- `claim()`: pays out `claimable`. The only point where cash leaves the basket for a user.

Loan side (callers restricted to `LossWaterfall`/`LoanRegistry`):
- `bindCover(loanId, amount, country, sector, month)`: requires `canCover`, records `cover[loanId].committed`, and adds to `coveredExposure` and `exposureBy`.
- `releaseCover(loanId)` on repayment: subtracts the exposure.
- `receivePremium(amount)`: pulls cash. Senior gets `amount * S * (10000 - riskAdjBps) / (10000 * (S+J))` and junior gets the rest, both added to `assets`.
- `impair(loanId, amount)` / `clearImpairment(loanId)`: moves `impairment[J]` first, then `[S]`, capped at the loan's committed cover. No cash moves.
- `coverLoss(loanId, loss) returns (paid, uncovered)`: `pay = min(loss, committed - alreadyPaid, capital)`. Take junior up to `assets[J]`, then senior. Record `paidJunior`/`paidSenior` and `lossUnrecovered[k]`. Transfer `pay` to the caller, clear this loan's impairment and exposure, and return `uncovered = loss - pay` for the ReserveVault. Invariant: `uncovered > 0` implies `capital == 0` or the per-loan committed cover is exhausted.
- `recover(loanId, amount) returns (unused)`: pull cash, credit senior up to `paidSenior - recoveredSenior`, then junior, and return the unused remainder to the caller (it goes to vouchers and then the borrower in reverse-waterfall order). After `writeOffDate`, `closeLoan(loanId)` zeroes the remaining `lossUnrecovered` for that loan.

Invariants to fuzz:
- `cash == Σ assets + Σ claimable`.
- `coveredExposure <= capacity` after every call except `coverLoss`.
- In `coverLoss`, senior pays nothing while `assets[J] > 0`.
- Pending (unsettled) shares' value moves one-for-one with NAV.
- Recovery never exceeds the loss paid, per loan and per tranche.
- No per-dimension exposure exceeds 25% of capacity at bind time.
