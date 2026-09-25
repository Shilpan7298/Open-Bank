# Goldfinch (goldfinch-eng/mono @ bb251675d8): upstream notes

Scope: only `upstream/mono/packages/protocol/contracts/` plus the audit and changelog files in the same repo. All paths below are relative to `packages/protocol/` unless they start with `mono/`. Line numbers refer to the pinned commit. Default parameter values come from `blockchain_scripts/deployHelpers/index.ts:230-236`.

TL;DR: Goldfinch gives each loan two tranches. Backers put in first-loss junior capital by hand, and a pooled Senior Pool adds senior capital automatically at a fixed leverage ratio (4x). The payment waterfall pays senior before junior. On the senior side, losses are marked by a lateness heuristic. For OBP, the reusable parts are the accounting patterns: share-price tranche accounting, payment allocation order, the schedule math, epoch withdrawals, delta writedowns and an asset/liability check. The parts that do not fit OBP are the two-tranche lender structure, the UID/Go identity layer and the lateness writedown, because OBP's first-loss capital sits outside the lenders.

---

## 1. How the mechanism works

### 1.1 TranchedPool: one pool per borrower deal (`contracts/protocol/core/TranchedPool.sol`)

- **Structure.** A pool holds up to 5 `PoolSlice`s (`_initializeNextSlice`, :658-663, `require(numSlices < 5)`). Each slice has a `seniorTranche` (odd ids 1,3,5..) and a `juniorTranche` (even ids 2,4,..) (`TranchingLogic.sliceIndexToSeniorTrancheId/JuniorTrancheId`, TranchingLogic.sol:417-427). Structs are defined in `interfaces/ITranchedPool.sol:9-21`:
  - `TrancheInfo {id, principalDeposited, principalSharePrice, interestSharePrice, lockedUntil}`
  - `PoolSlice {seniorTranche, juniorTranche, totalInterestAccrued, principalDeployed}`
- **Positions** are ERC-721 `PoolTokens` holding `TokenInfo {pool, tranche, principalAmount, principalRedeemed, interestRedeemed}` (`interfaces/IPoolTokens.sol:9-15`). A position's claim equals `sharePrice * principalAmount / 1e18 - redeemed`, computed separately for interest and principal (`TranchingLogic.redeemableInterestAndPrincipal`, :57-78).
- **Share prices** use 1e18 fixed point. `principalSharePrice` starts at 1e18, which means all deposited cash is redeemable. `interestSharePrice` starts at 0 and grows toward roughly the APR (TranchingLogic.sol:61-68, 397-415).
- **Roles.** `LOCKER_ROLE` is held by the borrower and the owner (:85-87). `SENIOR_ROLE` is held by the Senior Pool, and only that role may deposit into a senior tranche (:124-127).
- **Lifecycle of a slice:**
  1. `deposit(tranche, amount)` (:115-138) requires the tranche to be unlocked, `hasAllowedUID(msg.sender)`, and `block.timestamp >= fundableAt`. It mints a PoolToken.
  2. `lockJuniorCapital()` (:265, `_lockJuniorCapital` :632-635) sets `junior.lockedUntil = now + DrawdownPeriodInSeconds` (1 day default).
  3. `SeniorPool.invest(pool)` deposits `strategy.invest()` into the senior tranche (see 1.3).
  4. `lockPool()` / `_lockPool()` (:639-655) raises `creditLine.limit` by `junior+senior deposits` (capped at `maxLimit`) and locks both tranches. It is lockable only once, and a comment explains this blocks indefinite locking (:642-645).
  5. `drawdown(amount)` (:200-258) is `onlyLocker`. It works only on the current slice: `available = sum_tranches(principalSharePrice * principalDeposited)`, and after the drawdown both tranches' `principalSharePrice` becomes `amountRemaining / totalDeposited` (`calculateExpectedSharePrice`, TranchingLogic.sol:80-87 with `_scaleByPercentOwnership` :457-466). Both tranches are therefore drawn pro rata, and junior is not deployed first. Unused cash stays redeemable after `lockedUntil`.
  6. `pay(amount)` / `pay(principal, interest)` (:314-357) goes to `CreditLine.pay` and then to `distributeToSlicesAndAllocateBackerRewards` (:483-534). Interest accrued since the last checkpoint and principal are split across slices by `principalDeployed / totalDeployed` (`scaleByFraction`, TranchingLogic.sol:139-147).
  7. `withdraw` / `withdrawMax` (:153-195, `_withdraw` :582-629) requires token approval, `hasAllowedUID(msg.sender)` **again** (:589-592), and `now > lockedUntil`. Before a lock it refunds principal directly. After a lock it redeems interest first, then principal.

### 1.2 Payment waterfall between tranches (`TranchingLogic.applyToAllSlices`, :159-192)

Senior tranches across all slices are paid first, then junior tranches get whatever is left. For each slice, given `interest` and `principal` scaled to the slice:

- `principalAccrued = (totalDeposited - principalDeployed) + scale(totalDeployed - balance + principalOwed)` (`getTotalInterestAndPrincipal`, :117-137). This is the cumulative principal the slice should have back by now, counting undrawn cash and early repayment.
- **Senior** (`applyToSeniorTranche`, :281-332):
  - `expectedInterestSP = slice.totalInterestAccrued * seniorShare / seniorDeposited`, and `desiredNetInterestSP = expectedInterestSP * (100 - juniorFeePercent - reserveFeePercent) / 100`.
  - `reserveDeduction = interest * reserveFeePercent / 100`. `reserveFeePercent = 100 / ReserveDenominator`, which is 10% of interest by default (TranchedPool.sol:545).
  - Remaining interest fills the senior interest share price up to the net target, and principal fills the senior principal share price up to `principalAccrued / totalDeposited` (`_applyBySharePrice` → `_applyByAmount`, :481-534). Because the targets are **cumulative**, any past shortfall is paid to senior before junior sees anything.
- **Junior** (`applyToJuniorTranche`, :334-387):
  - Junior takes **all** remaining interest, including the `juniorFeePercent` that senior gave up. That is the junior's compensation for first loss (juniorFeePercent is passed to `initialize`, TranchedPool.sol:59, typically 20).
  - Junior principal is filled up to its expected level. Any principal left over after that is reclassified as junior interest and charged the reserve fee (:359-370).
- **Where losses land.** There is **no explicit loss or writedown on tranches**. A loss is simply cash that never arrives. Senior targets are met first from every payment, so junior share prices stay lower. This is subordination on cash flows only: junior has no mark, and nothing on-chain says "defaulted".

### 1.3 SeniorPool + leverage strategy (`SeniorPool.sol`, `LeverageRatioStrategy.sol`, `FixedLeverageRatioStrategy.sol`)

- **State** (`interfaces/ISeniorPool.sol:10-12`, SeniorPool.sol:65-75): `sharePrice` (1e18), `totalLoansOutstanding`, `totalWritedowns`, `writedownsByPoolToken[tokenId]`, `_usdcAvailable`, `_epochs`, `_withdrawalRequests`, `_checkpointedEpochId`, `_epochDuration` (2 weeks by default, :134).
- **Shares.** FIDU is a separate ERC-20 with 18 decimals, while USDC has 6. `getNumShares(usdc) = usdc*1e12 * 1e18 / sharePrice` (:813-815). `assets() = usdcAvailable + totalLoansOutstanding - totalWritedowns` (:771-773).
- `deposit(amount)` (:152-169) requires `Go.goSeniorPool(msg.sender)`. It is instant and priced at the current `sharePrice`.
- `invest(pool)` (:659-684) is **permissionless**. `amount = strategy.invest(this, pool)`, then `pool.deposit(seniorTrancheId, amount)`, and `totalLoansOutstanding += amount`.
- **Strategy** (`LeverageRatioStrategy._invest`, :86-99): `seniorTarget = junior.principalDeposited * leverageRatio / 1e18`, and the strategy invests `max(0, seniorTarget - senior.principalDeposited)`. It invests only if junior is locked and senior is not (:59-62). `FixedLeverageRatioStrategy.getLeverageRatio` (:29-31) returns the global config value, 4e18 by default (4:1, so junior is 20% of the pool).
- `redeem(tokenId)` (:691-700) calls `pool.withdrawMax`, then `_collectInterestAndPrincipal` (:843-859). There, `sharePrice += interest * 1e12 * 1e18 / fiduSupply`, and principal lowers `totalLoansOutstanding`. Interest is recognised when cash arrives, not as it accrues.
- `writedown(tokenId)` (:709-747) is **permissionless**:
  - It computes `(pct, amt) = Accountant.calculateWritedownForPrincipal(creditLine, principalRemaining, now, LatenessGracePeriodInDays=30, LatenessMaxDays=120)`.
  - `delta = prevWritedown[tokenId] - amt`. Then `sharePrice ± delta/shares` (`_distributeLosses`, :831-841), and `totalWritedowns` is adjusted to match.
  - It is fully reversible: a later repayment shrinks `amt` and raises the share price again.
- **Epoch withdrawals** (:196-311, :347-580):
  - `requestWithdrawal(fidu)` escrows FIDU and mints a non-transferable `WithdrawalRequestToken`. Each address may hold only one.
  - When an epoch ends, `_previewEpochCheckpoint` (:347-378) sets `usdcAllocated = min(_usdcAvailable, value(epoch.fiduRequested))` and `fiduLiquidated = shares(usdcAllocated)`. Unfilled FIDU carries over to the next epoch (`_initializeNextEpochFrom`, :468-478). If either amount is zero, the epoch is "Extended" instead of finalized.
  - Each request receives a pro-rata share via `usdcAllocated * req.fiduRequested / epoch.fiduRequested` (:485-525).
  - `claimWithdrawalRequest` takes a `1/WithdrawFeeDenominator` fee (0.5%) to the reserve (:297). `cancelWithdrawalRequest` burns a bps fee on the FIDU (:262-265).
  - Checkpointing is lazy: every mutating entry point calls `_applyEpochCheckpoints()` first.
- **Asset/liability guard.** `Fidu.canMint/canBurn` (`Fidu.sol:96-124`) reverts if `supply * sharePrice` differs from `seniorPool.assets()` by more than `ASSET_LIABILITY_MATCH_THRESHOLD = 1e6` (1 USDC). It is an on-chain invariant check on every mint and burn.

### 1.4 CreditLine + Accountant + Schedule (repayment terms, lateness, writedowns)

- **CreditLine state** (`CreditLine.sol:40-69`): `borrower, currentLimit, maxLimit, interestApr (1e18), lateFeeApr, balance, totalInterestPaid, lastFullPaymentTime, _totalInterestAccrued, _totalInterestOwed, _checkpointedAsOf, schedule{ISchedule, startTime}`.
- **Accrual** (`_interestAccruedOverPeriod`, :342-348): `balance * apr * dt / 365d`, plus a late fee (`_lateFeesAccuredOverPeriod`, :350-365). The late fee is `balance * lateFeeApr` counted from `oldestUnpaidDueTime + gracePeriod`. Interest becomes *owed* only when an interest due time is crossed (`totalInterestOwedAt`, :232-251). After `termEndTime`, all accrued interest is owed.
- **Principal owed** (straight-line amortisation over non-grace principal periods): `totalPrincipalOwedAt = currentLimit * principalPeriod / totalPrincipalPeriods` (:279-287).
- `_isLate`: `balance > 0 && now > schedule.nextDueTimeAt(lastFullPaymentTime)` (:367-370). A payment counts as "full" only when `interestOwed == 0 && principalOwed == 0` (:144-146).
- **Payment allocation order** (`Accountant.allocatePayment`, Accountant.sol:150-210): (1) interest owed, (2) principal owed, (3) accrued-not-yet-owed interest, (4) extra balance, (5) remainder not applied. It reverts `IO/PO/AI` if a later bucket is paid while an earlier one is short. `splitPayment` (:113-136) handles the single-amount form. The result is `PaymentAllocation {owedInterestPayment, accruedInterestPayment, principalPayment, additionalBalancePayment, paymentRemaining}` (`interfaces/ILoan.sol:103-109`).
- **Writedown formula** (`calculateWritedownForPrincipal`, Accountant.sol:53-96):
  - `amountOwedPerDay = balance*apr/365 + principalOwed` (:98-107)
  - `daysLate = (interestOwed + principalOwed) / amountOwedPerDay`, plus `(now - termEndTime)/1 day` after maturity
  - `pct = 0 if daysLate <= grace, else min(1, (daysLate - grace) / maxDaysLate)`
  - `amount = pct * principal`
- **Schedule** (`schedule/Schedule.sol`, :56-313):
  - It is a stateless, reusable contract parameterised by `periodMapper, periodsInTerm, periodsPerPrincipalPeriod, periodsPerInterestPeriod, gracePrincipalPeriods`. Start time is passed in on every call.
  - A drawdown mid-period creates a "stub period" that extends period 0 (:258-264).
  - `MonthlyPeriodMapper` (:12-22) maps timestamps to calendar months via BokkyPooBah's DateTime library, a git dependency that is not vendored.
  - `MonthlyScheduleRepo` deduplicates schedules by a param hash.
- **CallableLoan** (`protocol/core/callable/`) is a newer single-class loan with an explicit `LoanPhase {Prefunding, Funding, DrawdownPeriod, InProgress}` (`interfaces/ICallableLoan.sol:25-30`). Lenders can "call" principal, and call-request tranches have priority over uncalled capital (`callable/structs/notes.md`). It is useful as a phase-machine reference but otherwise out of scope for OBP.

### 1.5 Identity: UniqueIdentity + Go

- **`UniqueIdentity.sol`** is a non-transferable ERC-1155 (`_beforeTokenTransfer` allows only mint or burn, :128-141). Id types: 0 non-US individual, 1 US accredited, 2 US non-accredited, 3 US entity, 4 non-US entity, 5-10 reserved (:18-28).
  - `mint(id, expiresAt, sig)` needs a `SIGNER_ROLE` signature over `keccak(account, id, expiresAt, address(this), nonces[account], chainid)` with an eth-signed-message prefix, not EIP-712 (:143-160). A per-account nonce stops replay.
  - Minting costs 0.00083 ETH (:30, :109). There is one token per id per address.
  - `expiresAt` limits only how long the **signature** is valid. The UID itself never expires. Burning also needs a signer signature (:116-126).
- **`Go.goOnlyIdTypes(account, ids)`** (`Go.sol:79-121`) returns true in any of these cases:
  - `account` has `ZAPPER_ROLE`
  - `account` is on the legacy config go-list (type 0 only)
  - `balanceOf(account, id) > 0`
  - **`tx.origin` holds the UID and `isApprovedForAll(tx.origin, account)`**, a delegation meant to let contracts act for UID holders
- `goSeniorPool` (:173-179) admits types {0,1,3,4}, which excludes US non-accredited, and always admits StakingRewards. `TranchedPool.hasAllowedUID` uses a per-pool `allowedUIDTypes` (:441-443), which can be changed only while the pool is empty (:94-101).

---

## 2. Files and functions worth adapting (with SPDX)

Every file listed here has `// SPDX-License-Identifier: MIT` on line 1, and none carries a per-file copyright line. The repo root `mono/LICENSE` is MIT, but its copyright line reads "Copyright (c) 2019 Zeppelin Solutions". Record that as-is in `NOTICE.md`, and credit Goldfinch / Warbler Labs as the authors named in the `@author` tags.

| File | Functions / pieces | SPDX | Use in OBP |
|---|---|---|---|
| `contracts/protocol/core/TranchingLogic.sol` | `usdcToSharePrice`, `sharePriceToUsdc`, `redeemableInterestAndPrincipal`, `_applyToSharePrice`, `_desiredAmountFromSharePrice`, `_applyByAmount` | MIT, but **imports `external/FixedPoint.sol`, which is AGPL-3.0-only** | Per-loan lender share-price accounting (single class) |
| `contracts/protocol/core/TranchedPool.sol` | `deposit`, `_withdraw` (pre-lock refund vs post-lock redeem), `drawdown` share-price update, `_lockPool` once-only lock | MIT | LoanRegistry funding and drawdown flow |
| `contracts/protocol/core/Accountant.sol` | `allocatePayment`, `splitPayment`; `calculateWritedownForPrincipal` as reference only | MIT, but **imports `external/FixedPoint.sol` (AGPL-3.0-only)** and `library/SafeMath.sol` (**no SPDX header**; wraps OZ MIT) | LoanRegistry repayment allocation |
| `contracts/protocol/core/CreditLine.sol` | `_checkpoint`, `totalInterestOwedAt`, `totalPrincipalOwedAt`, `_isLate`, `_lateFeesAccuredOverPeriod`, `PaymentScheduleLib` | MIT (imports the no-SPDX `library/SafeMath.sol`) | LoanRegistry accrual and lateness |
| `contracts/protocol/core/schedule/Schedule.sol` | `periodAt`, `principalPeriodAt`, `interestPeriodAt`, `nextDueTimeAt`, `withinPrincipalGracePeriodAt`, `_termStartAbsolutePeriod` (stub period) | MIT | Repayment schedule, possibly with a fixed-seconds period mapper |
| `contracts/protocol/core/schedule/MonthlyPeriodMapper.sol` | `periodOf`, `startOf` | MIT (depends on the external BokkyPooBahsDateTimeLibrary, not vendored here; verify its licence at our pin) | Optional calendar-month periods |
| `contracts/protocol/core/SeniorPool.sol` | Epoch engine: `requestWithdrawal`, `addToWithdrawalRequest`, `cancelWithdrawalRequest`, `claimWithdrawalRequest`, `_previewEpochCheckpoint`, `_applyEpochCheckpoint`, `_initializeNextEpochFrom`, `_applyWithdrawalRequestCheckpoint`, `_mostRecentEndsAtAfter`; writedown delta: `writedown` + `writedownsByPoolToken` | MIT | LenderVault redemption queue, InsuranceBasket notice period, per-position marks |
| `contracts/protocol/core/LeverageRatioStrategy.sol` / `FixedLeverageRatioStrategy.sol` | `invest`, `_invest` (only after first-loss capital is locked) | MIT | LenderVault sizing rule (reshaped, see 4) |
| `contracts/protocol/core/Fidu.sol` | `canMint`, `canBurn` asset/liability tolerance check | MIT | Invariant check pattern for vault shares |
| `contracts/interfaces/ISeniorPoolEpochWithdrawals.sol` | `Epoch`, `WithdrawalRequest` structs | MIT | Epoch data model |
| `contracts/interfaces/ILoan.sol`, `ITranchedPool.sol`, `IPoolTokens.sol`, `ISchedule.sol`, `IPeriodMapper.sol` | Structs (`PaymentAllocation`, `TrancheInfo`, `TokenInfo`), schedule interface | MIT | Naming and shape reference |
| `contracts/protocol/core/UniqueIdentity.sol` | `onlySigner` nonce+chainid replay protection, mint/burn-only transfer hook | MIT | Reference only; OBP uses EAS |
| `contracts/protocol/core/Go.sol` | `goOnlyIdTypes` per-product id-type allowlist | MIT | Reference only (drop the `tx.origin` branch) |

**Licence flags:**
- **GPL-3.0-only** files in this repo: `contracts/rewards/MerkleDistributor.sol`, `contracts/rewards/MerkleDirectDistributor.sol`, `contracts/rewards/BackerMerkleDistributor.sol`, `contracts/rewards/BackerMerkleDirectDistributor.sol`, `contracts/interfaces/IMerkleDistributor.sol`, `contracts/interfaces/IMerkleDirectDistributor.sol`. **None of them is recommended.** Do not copy them.
- **GPL-2.0-only**: no such files were found anywhere in `mono/`.
- **AGPL-3.0-only**: `contracts/external/FixedPoint.sol` (vendored from UMA, per the comment on line 3), plus a duplicate in `packages/protocol-l2`. `Accountant.sol` and `TranchingLogic.sol` depend on it. **Do not copy FixedPoint.** Replace `scaleByFraction` and the writedown maths with OZ `Math.mulDiv` (MIT) when adapting. Then the MIT files stand alone and no "-only" licence reaches the AGPL-3.0-or-later project. Flag this for the lawyer anyway.
- **No SPDX header**: `contracts/library/SafeMath.sol` (an OZ wrapper adding `saturatingSub`). It is not needed on Solidity 0.8, so drop it.
- Everything here targets Solidity 0.6.12 (UID is 0.8.4, and callable loans are 0.8.18), so an adaptation is a port and not a copy-paste. Keep the MIT header on any ported file and log it in `NOTICE.md`.

---

## 3. Known pitfalls and past findings visible in the repo

1. **Epoch finalisation bug** (Medium; `internal-audits/v3.0.0/SeniorPool.md`). After a no-op epoch, the first new withdrawal request became withdrawable immediately, because a short-circuit returned the epoch without extending `endsAt`. The fix is the explicit `Unapplied / Extended / Finalized` status in `_previewEpochCheckpoint` (SeniorPool.sol:347-378, enum :913-917). The same audit found that a zero epoch duration was allowed (now blocked, :105). OBP should copy the three-state design and write an invariant test for "no claim before the epoch ends".
2. **Rounding in the epoch and share maths** (`internal-audits/v3.0.0/epoch-level-checkpointing/rounding-errors-from-integer-division.md`). The FIDU (18 decimals) to USDC (6 decimals) conversion leaves up to about 1e12 FIDU of dust in each epoch. The code zeroes "dusty" requests (SeniorPool.sol:407-429, 509-518). OBP can avoid this by using an ERC-4626 vault with OZ decimals offset and one rounding direction (favouring the vault).
3. **Direct token donations** (`.../sending-erc20s-directly-to-pool.md`). The pool uses `_usdcAvailable` rather than `balanceOf`, so donations are inert. This matches the ERC-4626 inflation-attack defence OBP needs.
4. **Allocation-order regression** (`contracts/test/core/accountant/Accountant.allocatePayment.t.sol:19-44`). The `AI` revert once subtracted `owedInterestPayment` from balance instead of `owedPrincipalPayment`. That test also carries handler invariants (interest owed first, principal owed second, accrued third, :49-59). Port these invariants.
5. **Writedown bug** (`mono/CHANGELOG.md:80-86`, v2.7.4). "Fixed Accountant library for writedown bug; writedowns are now done on PoolToken rather than pools". That is why the old `writedowns` mapping is deprecated (SeniorPool.sol:57-65). Keep marks per position and apply them as deltas.
6. **Oversized pool-token principal bug** (`contracts/protocol/core/PoolTokens.sol:121-134`). Before v2.6.0, positions could claim more principal than was lent to the borrower, and an admin repair function was needed. Invariant: sum of position principal ≤ amount deployed plus refundable cash, per loan.
7. **Missing KYC gate on one entry point** (`mono/CHANGELOG.md:94-96`, v2.7.3). `unstakeAndWithdrawInFidu` lacked a go-list check. Put every fund-moving entry point behind one modifier and test the full list.
8. **`tx.origin` delegation** (`Go.sol:104-117`, reviewed in `internal-audits/v3.1.0/go-upgrade-audit.md`). The internal audit worried about phishing and reentrancy through new `msg.sender` paths. `tx.origin` also breaks with ERC-4337 smart accounts, where origin is the bundler. **Do not port.**
9. **KYC re-checked on withdraw** (TranchedPool.sol:589-592). A lender whose UID was burned or whose type was removed cannot withdraw at all, so funds get stuck. OBP must tell "sanctioned: freeze" apart from "attestation lapsed: may still exit".
10. **The lateness heuristic ignores subordination and recovery.**
    - The Senior Pool writes down its **senior** position with the same days-late formula it would use for an unprotected loan. It ignores the junior buffer.
    - The writedown is permissionless, reversible and moves the share price in steps (SeniorPool.sol:709-747). Deposits are instant (:152-169), so anyone can buy in at a depressed price just before a repayment reverses a writedown.
    - Also, `amountOwedPerDay` adds the *whole* `principalOwed` to one day of interest (Accountant.sol:98-107). When principal is owed, `daysLate` comes out near 1 day before maturity, so amortising loans are under-marked until after the term ends. This is an observed quirk worth confirming in a test before reusing anything from it.
11. **No explicit default state.** TranchedPool/CreditLine have only "late" (`_isLate`). Losses are implicit, junior holders get no mark, and recovery is off-chain. The only admin tool is `emergencyShutdown`, which pauses and sweeps all pool and credit-line USDC to the reserve (TranchedPool.sol:360-378). That is a large centralised power.
12. **Leverage depends only on junior size** (LeverageRatioStrategy.sol:91-93). Nothing stops borrower-affiliated wallets from filling the junior tranche to attract 4x senior money. The UID check requires only that each wallet has *a* UID. This is the self-vouching failure OBP's design targets. In addition, `invest` is permissionless and the borrower (LOCKER) controls lock timing (TranchedPool.sol:85, :265-272).
13. **Slices add complexity.** Up to 5 slices, with interest pro-rated by `principalDeployed` (TranchedPool.sol:483-506). `initializeNextSlice` is blocked when the loan is late or outside the principal grace period (:283-289). TODO comments admit accounting shortcuts: "Drawdown only draws down from the current slice for simplicity" (:206-207), and the balance is updated before the lateness check (CreditLine.sol:170-173).
14. **Fragile payment path.** `pay(uint256 amount)` transfers `amountToPay = min(amount, maxPayable)` but passes the original `amount` to `_pay` (TranchedPool.sol:319-325). It relies on `splitPayment` capping and on `assert(paymentRemaining == 0)`. Use a single capped value everywhere.
15. **Known small bugs left as TODOs.** A duplicate `TrancheLocked` event (`contracts/test/core/tranchedpool/TranchedPool.deposit.t.sol:148`). A callable-loan assertion failure found in a bug bash (`contracts/test/core/callable/scenarios/CallableLoans.realScenarios.t.sol:339-341`, fixed in cfab3d57). An unclear reserve accounting emit in `internal-audits/callable-loans/contracts/Waterfall.md:7`.
16. **Upgradeable config registry.** `ConfigOptions` enums warn "NEVER EVER CHANGE THE ORDER" (ConfigOptions.sol:13), and parameters are global and admin-settable with no timelock. OBP puts parameters behind `TimelockController` and scopes them per risk band.

---

## 4. What OBP should change

**The core mismatch.** Goldfinch's first-loss capital is *lender capital inside the loan* (backers in the junior tranche). In OBP, first loss is **outside the lenders**: borrower collateral, then voucher stakes, then the insurance basket (junior, then senior), then the reserve. Only after all of those do lenders lose. The insurance basket's tranching belongs to `InsuranceBasket`, not to the loan. So:

- **Carry over:**
  - **Share-price position accounting** (TranchingLogic helpers), with **one lender class per loan**. Kickstarter bidders and `LenderVault` fills sit pari passu at the auction clearing rate.
  - **Payment allocation order and revert rules** (`Accountant.allocatePayment`), with its invariants.
  - **Checkpointed accrual** (`CreditLine._checkpoint`, owed vs accrued split, late fee after grace).
  - **Schedule maths** (Schedule.sol), with a stub period and principal grace periods. For Phase 1 use a fixed-length period mapper (for example 30 days) and drop the calendar dependency.
  - **Epoch withdrawal engine** with the three-state checkpoint, for `LenderVault` redemptions and the 30-90 day `InsuranceBasket` notice.
  - **Per-position delta writedowns** (`writedownsByPoolToken` pattern) in `LenderVault`.
  - **Asset/liability tolerance check** (Fidu `canMint/canBurn`) as an invariant, both in tests and on-chain.
  - **"Senior money only after first-loss is locked"** (LeverageRatioStrategy.sol:59-62). In OBP this becomes "vaults may bid only after the loan reached `Backed`": collateral + voucher cover ≥ required, and insurance capacity was reserved.
- **Simplify:**
  - One drawdown per loan, no slices, no `maxLimit` growth inside a loan. Credit limit steps belong in `CreditRegistry`.
  - Explicit phases like CallableLoan's `LoanPhase` (see 5), including **Late → Defaulted**, so that `LossWaterfall` has a single trigger.
  - The rate comes from `RateAuction` and is not borrower- or admin-set (`interestApr` in `TranchedPool.initialize`).
  - The reserve fee is 1-2% of principal taken at drawdown and sent to `ReserveVault`, not 10% of interest (`ReserveDenominator`). Voucher premiums replace `juniorFeePercent`.
  - Use Solidity 0.8 checked maths plus OZ `Math.mulDiv`. No FixedPoint and no SafeMath.
- **Replace:**
  - **Identity.** Replace UID/Go with `IdentityGate`: EAS attestation (schema, trusted attester, not revoked, not expired) plus a sanctions oracle check, keyed on `msg.sender` only. Signatures (AI scores, attestations) use EIP-712 with nonce, chainid and deadline, which improves on UID's eth-sign message. Gate *entry* (deposit, bid, propose, drawdown). On exit, a lapsed attestation may still withdraw, while a sanctioned address is frozen into escrow.
  - **Loss marking.** Replace the lateness writedown with a waterfall-aware mark. `LenderVault` exposure to loan L is marked down only by `max(0, exposure - remainingCoverAhead(L))`, where the cover ahead is collateral + stakes + insurance + reserve capacity. The mark becomes a realised loss only when `LossWaterfall` reports it. To stop deposit sandwiches, marks update only at epoch checkpoints, or deposits are also epoch-settled.
- **Drop:** tranches inside a loan, the 5-slice machinery, BackerRewards/GFI/StakingRewards/Membership/Zapper, the legacy go-list, the `tx.origin` path, CallableLoan, the Curve/Compound code, `emergencyShutdown` sweep-to-reserve (replace with guardian pause only), FIDU as a separate token (use ERC-4626 shares), and the global `ConfigOptions` registry.

---

## 5. Minimal interface sketches (prose, OBP-original)

### 5.1 `LoanRegistry`

**State per loan:**
- `borrower`, `principal`, `termSeconds`, `periodSeconds`, `gracePrincipalPeriods`, `purposeHash`, `riskBand`, `jurisdictionTier`
- `rateBps`, set once by RateAuction
- `agreementHash`
- `status`: `Proposed → Backing → Auction → Funded → Active → {Repaid | Late → (Active | Defaulted)} → Closed`, plus `Cancelled` from any pre-`Active` state
- Accounting: `balance`, `totalInterestAccrued`, `totalInterestOwed`, `totalInterestPaid`, `checkpointedAt`, `startTime`, `lastFullPaymentTime`
- Lender positions: `positionId → {lender, principal, principalRedeemed, interestRedeemed}` plus loan-level `principalSharePrice` / `interestSharePrice`

**Functions:**
- `propose(amount, term, scheduleParams, purposeHash) returns loanId`: IdentityGate check on the borrower, and CreditRegistry limit ≥ amount. Status becomes `Proposed`.
- `markBacked(loanId)`: permissionless. It reads CollateralEscrow + VouchingModule and succeeds only if `collateral ≥ minCollateral(tier, stage)` and `collateral + stakes ≥ requiredCover`. It reserves InsuranceBasket capacity and moves the loan to `Auction`.
- `settleAuction(loanId, rateBps, fills[])`: `onlyRateAuction`. It records the rate, mints positions at `principalSharePrice = 1e18`, pulls funds, and moves the loan to `Funded`. If the auction does not fill, it refunds and moves to `Cancelled`.
- `sign(loanId, agreementHash, borrowerSig)`: EIP-712 over `(loanId, agreementHash, rateBps, principal, schedule)`. Status stays `Funded`, now with a signed flag.
- `drawdown(loanId)`: borrower only, and only if signed and within the drawdown window. It sends the reserve fee to ReserveVault and the rest to the borrower, starts the schedule, and moves to `Active`.
- `repay(loanId, amount)`: caps `amount` at the total due, then checkpoints and allocates in the order interest owed → principal owed → accrued interest → extra principal. The loan-level share prices increase accordingly. After the final payment the loan moves to `Repaid`, which releases collateral and stakes and notifies CreditRegistry (credit limit up).
- `poke(loanId)`: permissionless. It moves `Active → Late` when `now > nextDueTime(lastFullPaymentTime)`, and `Late → Defaulted` when `daysLate > defaultAfterDays(tier)`. On `Defaulted` it calls `LossWaterfall.allocate(loanId, outstandingPrincipal + interestOwed)` once, then freezes accrual.
- `claim(positionId)`: pays redeemable interest, then principal, including waterfall recoveries credited to the loan's share prices.
- **Views:** `amountsOwed(loanId, t)`, `nextDueTime(loanId)`, `daysLate(loanId)`, `status(loanId)`, `redeemable(positionId)`.

**Invariants:**
- Sum of position redeemable ≤ loan cash held.
- Allocation order is always respected.
- Status transitions are monotonic except `Late → Active` on cure.
- `LossWaterfall.allocate` is called exactly once per default.

### 5.2 `LenderVault` (one ERC-4626 per risk band, USDC asset)

**State:**
- `idle`, the tracked cash (never `balanceOf`)
- `principalOutstanding`
- `markdowns[positionId]` and `totalMarkdowns`
- Caps: `maxPerLoan`, `maxPerBorrower`, `maxShareByCountry/Sector/OriginationMonth` (for example 25%), `maxBandExposure`
- The epoch queue: `epochs[id] {endsAt, sharesRequested, sharesLiquidated, assetsAllocated}`, `requests[owner] {epochCursor, sharesRequested, assetsClaimable}`

**Functions:**
- `totalAssets() = idle + principalOutstanding - totalMarkdowns`. Interest is recognised on receipt.
- `deposit/mint`: IdentityGate on the receiver and caller, applying any pending epoch checkpoint first. Standard 4626 rounding favours the vault, with a decimals offset.
- `withdraw/redeem`: disabled for instant exit. Use `requestRedeem(shares)`, which escrows shares, then `claim()` after the epoch finalises. Each epoch pays out `min(idle, value(sharesRequested))` pro rata and carries the rest over. Cancelling costs a fee.
- `bid(loanId, rateBps, amount)`: keeper or allocator role, within band rules. Allowed only when the loan is in `Auction`, `rateBps ≥ bandFloor`, and every cap still holds after the bid. It submits to RateAuction, and on fill `principalOutstanding += filled`.
- `harvest(positionId)`: calls `LoanRegistry.claim`, then `idle += interest + principal` and `principalOutstanding -= principal`.
- `updateMark(positionId)`: applied only at checkpoints. `newMark = max(0, exposure - LossWaterfall.coverAhead(loanId))`, scaled by status (0 while Active, a lateness factor while Late, the full expected shortfall once Defaulted). It applies `newMark - oldMark` as a delta.
- `onLossRealised(loanId, amount)`: `onlyLossWaterfall`. It converts the mark into a realised write-off of the principal.

**Invariants:**
- `|convertToAssets(totalSupply) - totalAssets| ≤ dust`.
- No exposure is above a cap at the moment of funding.
- No request is claimable before its epoch ends.
- Vault losses are never booked while a higher waterfall layer for that loan still has capacity.
