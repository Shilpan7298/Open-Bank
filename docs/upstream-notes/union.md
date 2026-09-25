# Union Protocol v2: upstream notes for OBP

Source: `upstream/union-v2-contracts/` at commit `67bc59b7ee` (full history present, 722 commits). Repo `LICENSE` is MIT, "Copyright (c) 2024 Union Finance Inc.". Below, paths are relative to that directory. Line numbers are at the pinned commit.

Summary: Union is an **open credit line** protocol. A staker deposits one stake and grants "trust" to many borrowers. A borrower borrows from a shared lender pool (uToken), and on each borrow the stake of its vouchers is locked in voucher-array order. If the borrower goes overdue, the locked stake becomes "frozen", which only matters for rewards. Once a grace window has passed, anyone can write the debt off against a chosen voucher's locked stake. Stakes sit in an `AssetManager` that routes funds to money markets (Aave, or idle). Stakers are paid in UNION inflation through the `Comptroller`, not in money-market yield.

---

## 1. How the mechanism works

### 1.1 State (contracts/user/UserManager.sol)
- `Staker { bool isMember; uint96 stakedAmount; uint96 locked; uint64 lastUpdated; uint256 stakedCoinAge; uint256 lockedCoinAge; }` (L45-52), held in `_stakers[staker]` (L149).
- `Vouch { address staker; uint96 trust; uint96 locked; uint64 lastUpdated; }` (L34-43). `_vouchers[borrower]` is an **array** of Vouch (L154). `voucherIndexes[borrower][staker] = Index{isSet, idx}` (L159).
- Reverse index: `vouchees[staker]` is an array of `Vouchee{borrower, voucherIndex}` (L164), with `voucheeIndexes[borrower][staker]` (L169).
- Frozen stake: `_memberFrozen[staker]`, `_frozenCoinAge[staker]`, `_totalFrozen` (L129, L174-179). `gLastWithdrawRewards[staker]` (L184).
- Params: `maxOverdueTime` (L134), `maxVouchers` (the maximum number of vouchers per borrower, L139), `maxVouchees` (the maximum number of borrowers per staker, L144), `effectiveCount` (vouches needed to register, L114), `newMemberFee` (UNION burned on register, L119), `_maxStakeAmount` (default 10,000e18, L333).
- Units: every internal amount is scaled to 18 decimals (`ScaledDecimalBase.decimalScaling`/`decimalReducing`, contracts/ScaledDecimalBase.sol). External calls pass token-native units. This dual-unit design caused several bugs (section 3).
- Deploy defaults (deploy/config/base-mainnet.ts L7-26, index.ts L39-61): `overdueTime` 30 days, `maxOverdue` 60 days, `maxVouchers` 400, `maxVouchees` 1000, `effectiveCount` 0 on Base (1 by default), origination fee 0.5%, `maxBorrow` 25,000, `minBorrow` 100.

### 1.2 Vouching: `updateTrust(address borrower, uint96 trustAmount)` (L586-626)
- Requires `onlyMember(msg.sender)` and `whenNotPaused`. Self-vouching reverts `ErrorSelfVouching`.
- **Existing vouch:** sets `trust = trustAmount`, but only if `trustAmount >= vouch.locked` (`TrustAmountLtLocked`, L599). Trust can be cut down to the locked amount at any time.
- **New vouch:** reverts if the staker is overdue as a borrower (`uToken.checkIsOverdue(staker)`, `VouchWhenOverdue`, L604). Enforces `vouchees[staker].length < maxVouchees` and `_vouchers[borrower].length < maxVouchers` (L608-615). Then pushes `Vouch(staker, trust, 0, 0)` and the matching `Vouchee` record.
- Trust is **not backed at vouch time**. It is a ceiling, and the effective vouch is `min(trust, stake)` (see `getVouchingAmount`, L553-560). A staker can hand out trust worth far more than its total stake across many borrowers, so the same stake is over-subscribed and borrowers draw on it first come, first served.
- `cancelVouch(staker, borrower)` (L688) can be called by the staker or the borrower, and only when `vouch.locked == 0` (`LockedStakeNonZero`, L644). The shared body `_cancelVouchInternal` (L638-680) removes the entry by **swap-and-pop** on both arrays and repairs the moved element's indexes.
- Membership: `registerMember(newMember)` (L722) counts vouchers whose `stakedAmount > 0` against `effectiveCount` (`_validateNewMember`, L1140-1160) and burns `newMemberFee` UNION. `UserManagerOp.registerMember` sends the fee to the Comptroller instead. The admin can bypass all of this with `addMember` (L572).

### 1.3 Staking: `stake(uint96)` / `unstake(uint96)` (L738-787)
- `stake`: first calls `comptroller.withdrawRewards`, which settles the coin-age snapshot (see 1.7). Then it checks `stakedAmount + amt <= _maxStakeAmount`, increments `stakedAmount` and `_totalStaked`, pulls the tokens and calls `AssetManager.deposit`.
- `unstake`: requires `stakedAmount - locked >= amount` (L772). Locked stake can never be withdrawn. It calls `AssetManager.withdraw` and accepts a **partial** withdrawal: the returned `remaining` value is subtracted from what is actually unstaked.

### 1.4 Credit limit from vouches
- `getCreditLimit(borrower)` (L492-499) is the sum over the borrower's vouchers of `min(staker.stakedAmount - staker.locked, vouch.trust - vouch.locked)`. The comment at L486-488 says this is a view for the UI only and can be very expensive.
- Borrowing does **not** call `getCreditLimit`. The limit is enforced implicitly: `UToken.borrow` calls `updateLocked(borrower, amount+fee, true)`, which reverts `LockedRemaining` if the vouchers cannot absorb the whole amount (L931).
- `UToken.borrow` (contracts/market/UToken.sol L609-671) also checks `minBorrow`, `maxBorrow` per account (principal + interest + new + fee), the global `debtCeiling`, that the borrower is not overdue, and `getLoanableAmount`. The **origination fee is added to principal and is also locked** against stake (L643, L658-662).

### 1.5 Stake locking: `updateLocked(borrower, amount, lock)` (L881-932, `onlyMarket`)
- Walks `_vouchers[borrower]` in array order ("first in, first out", L873-876). For each vouch it first accrues `staker.lockedCoinAge += vouch.locked * (now - max(staker.lastUpdated, vouch.lastUpdated))` and sets `vouch.lastUpdated = now`.
- **Lock:** `lockAmount = min(staker.stakedAmount - staker.locked, vouch.trust - vouch.locked)`. It takes `min(remaining, lockAmount)` and adds it to both `staker.locked` and `vouch.locked`.
- **Unlock** (on repay): takes `min(vouch.locked, remaining)` from the earliest vouchers first.
- Reverts if anything is left after the loop. There is one `locked` number per (staker, borrower) pair, because a credit line has no per-loan identity.
- Unlocking is called from `_repayBorrowFresh` (UToken L737-741) with the principal part only (`repayAmount - interest`). **Interest is never secured by stake.**

### 1.6 Overdue, frozen stake, write-off
- **Overdue** (UToken L457-463): `principal != 0 && now - lastRepay > overdueTime`. `lastRepay` is set on the first borrow and on every repayment that covers at least the accrued interest (L749). It is reset to 0 once principal reaches 0. A borrower who pays only interest therefore stays current forever, because there is no maturity date.
- **Frozen** = locked stake behind an overdue borrower. It is computed lazily in `_getEffectiveAmounts` (L941-1013) by looping over all of the staker's vouchees. If `now - lastRepay > overdueTime`, it adds `vouch.locked` to `stakerFrozen` and accrues `frozenCoinAge += locked * (now - max(staker.lastUpdated, lastRepay + overdueTime))` (`_calcFrozenCoinAge`, L1169-1176). Stored `_memberFrozen`/`_totalFrozen` are refreshed only in `onWithdrawRewards` (L1051-1071) and `batchUpdateFrozenInfo` (L1102-1122, a public keeper call that also pushes `_totalStaked - _totalFrozen` to the Comptroller). `onRepayBorrow` (L1078-1096) settles frozen coin-age when an overdue borrower repays.
- Frozen stake does **not** block anything extra, because locked stake is already non-withdrawable. It only (a) excludes the stake from reward weight and (b) is subtracted from `globalTotalStaked()` (L1124-1126).
- **`debtWriteOff(staker, borrower, amount)`** (L806-869):
  - Authorisation (L816-818): while `now <= lastRepay + overdueTime + maxOverdueTime`, only the **staker itself** may call it. A staker can voluntarily burn its own locked stake to pay down the debt at any time, even when the loan is not overdue. After that window **anyone** may call it.
  - Requires `amount <= vouch.locked` (`ExceedsLocked`). It reduces `staker.stakedAmount`, `staker.locked`, `_totalStaked`, `vouch.trust` and `vouch.locked` by `amount`, so the voucher's trust line shrinks by the loss.
  - Decrements `_memberFrozen`/`_totalFrozen`, with an underflow guard because the frozen values may be stale (L841-858).
  - If `vouch.trust == 0` it calls `_cancelVouchInternal`.
  - Then calls `AssetManager.debtWriteOff(token, amount)`, which moves `amount` of the UserManager's recorded principal into loanable pool funds (AssetManager L382-386). It then calls `UToken.debtWriteOff(borrower, amount)` (UToken L792-808), which reduces `principal` and `_totalBorrows` and resets `lastRepay` when principal reaches 0.
- **How the loss is split:** there is no pro-rata allocation. Each call consumes one named voucher's `vouch.locked`, and the caller chooses which voucher and how much. What each voucher can lose is fixed by the array-order locking at borrow time. After full write-off, accrued interest is simply dropped (`_calculatingInterest` returns 0 when principal is 0, L570-586). test/simulations/bad-debt.ts asserts `owed == 0` after writing off principal only.
- **Lenders' side:** the uToken exchange rate is `_totalRedeemable / totalSupply` (UToken L543-546), and `_totalRedeemable` never drops on default. Bad debt that nobody writes off stays in `_totalBorrows` indefinitely, and the shortfall appears only as missing liquidity when lenders redeem. There is no loss layer beyond voucher stakes.

### 1.7 Yield and rewards on stakes
- **AssetManager** (contracts/asset/AssetManager.sol):
  - `balances[sender][token]` and `totalPrincipal[token]` count only UserManager deposits. uToken deposits are not counted as principal.
  - `deposit` (L274-333) first fills adapter **floors** in array order, then fills in reverse order under **ceilings**. If every adapter refuses, the tokens stay idle in the AssetManager.
  - `withdraw` (L335-380) pays from the idle balance first, then walks `withdrawSeq`, and returns `remaining` (a partial fill is allowed).
  - `getLoanableAmount = poolBalance - totalPrincipal` (L183-186), so uTokens can never lend out the staked principal.
  - Adapters: `AaveV3Adapter` (supply/withdraw via Aave v3, `claimRewards` onlyAdmin) and `PureTokenAdapter` (holds tokens idle). Admin functions: `rebalance`, `setWithdrawSequence`, `addAdapter`/`removeAdapter`.
- **The money-market interest earned on stakes is not credited to stakers.** No accounting path at this commit assigns it to stakers or to uToken holders. It shows up only as extra `getLoanableAmount`.
- **Comptroller** (contracts/token/Comptroller.sol) pays UNION inflation:
  - `gInflationIndex += dt * inflationPerSecond(totalStaked) / totalStaked` (L354-360). `inflationPerSecond` comes from a step lookup table on `totalStaked / halfDecayPoint` (L319-352).
  - User reward = `(curIndex - userIndex) * effectiveStaked * multiplier` (L269-296).
  - `multiplier = 1 + effectiveLocked/effectiveStaked` for members and `0.75` for non-members (L362-373). Lending (locked stake) is rewarded up to 2x.
  - `effectiveStaked = (stakedCoinAge - frozenCoinAge) / timeSinceLastWithdraw`, and `effectiveLocked` is the same with `lockedCoinAge` (UserManager L998-1012). Frozen stake therefore earns nothing.
  - `withdrawRewards` keeps rewards in `accrued` if the Comptroller has too little UNION (L199-212).

---

## 2. Files and functions worth adapting (all MIT)

Every `.sol` file under `contracts/` carries `//SPDX-License-Identifier: MIT`. **No GPL-2.0-only or GPL-3.0-only file exists in this repo.** Two files place the SPDX line on line 2, after a comment that says "if you are using this as a template": `contracts/asset/PureTokenAdapter.sol` and `contracts/mocks/AdapterMock.sol`. Keep that comment and the SPDX line together if either is adapted. Adapted files need `NOTICE.md` entries (source repo, commit `67bc59b7ee`, path) and the MIT copyright line "Copyright (c) 2024 Union Finance Inc.".

| Path | SPDX | Functions worth studying or adapting | Use in OBP |
|---|---|---|---|
| contracts/user/UserManager.sol | MIT | `updateTrust` (L586), `_cancelVouchInternal` (L638), `stake`/`unstake` (L738/L767), `debtWriteOff` (L806), `updateLocked` (L881), `getCreditLimit` (L492), `_validateNewMember` (L1140) | VouchingModule: the guard set (self-vouch, overdue cannot vouch, count caps, locked stake not withdrawable, write-off gating) and the structure of the stake-consume path. Rewrite; do not port the credit-line data model. |
| contracts/interfaces/IUserManager.sol | MIT | `updateLocked`, `debtWriteOff`, `onRepayBorrow` hook signatures | Shape of the hooks between the market and the vouching module |
| contracts/market/UToken.sol | MIT | `checkIsOverdue` (L457), `borrow` (L609), `_repayBorrowFresh` (L701), `debtWriteOff` (L792) | LoanRegistry/LossWaterfall: the hook order (repay, then unlock; write-off, then reduce principal). Replace the interest model with fixed-term schedules. |
| contracts/asset/AssetManager.sol | MIT | `deposit` (L274), `withdraw` (L335), `debtWriteOff` (L382), `getLoanableAmount` (L183) | Idea only: keep staker principal separate from lendable funds. For the vault, prefer OZ ERC4626. |
| contracts/asset/PureTokenAdapter.sol | MIT (line 2) | whole file (idle-hold adapter) | Phase 1 "no-strategy" stake vault reference |
| contracts/asset/AaveV3Adapter.sol | MIT | `deposit`, `withdraw`, `_getSupply` (the dust threshold of 10 wei at L272-280) | Phase 2 strategy for the stake vault |
| contracts/token/Comptroller.sol | MIT | `_getRewardsMultiplier` (L362), `_calculateRewardsInternal` (L269) | Idea only: pay lockers more than idle stakers. OBP pays premium in the loan asset, not with an inflation token. |
| contracts/ScaledDecimalBase.sol | MIT | `decimalScaling`/`decimalReducing` | Do not adopt. Use a single unit per asset (section 3). |
| contracts/Controller.sol | MIT | admin/guardian pause, UUPS | Replaced by OZ AccessControl, Pausable and TimelockController |
| test/foundry/userManager/*.t.sol, test/findings/*.ts | MIT (repo license) | `TestUpdateLocked`, `TestWriteOffDebt`, `TestUpdateTrust`, `TestGetFrozenInfo` | Test cases to re-express as Foundry tests for VouchingModule |

---

## 3. Known pitfalls and past audit findings visible in the repo

There is no audit report PDF or folder at this commit. The evidence is the regression tests in `test/findings/` and `test/audit-2024/` (run by `.github/workflows/ci_audit.yml` on `findings/**` branches), the finding-named merges in the git history, and `slither.db.json`, which triages 207 entries: unused-return 66, reentrancy-no-eth 59, incorrect-equality 54, and so on.

Vouching and write-off:
1. **UNI-1011, index corruption on cancel:** `test/findings/uni-1011-157-vouchers-and-vouchees-indices-become.ts`. Swap-and-pop left `vouchee.voucherIndex` pointing at a popped slot, so later reads reverted. The fix is the index repair at UserManager L658-661 and L676. Lesson: avoid paired arrays with cross-indexes. Append-only per-loan slices sidestep this.
2. **UNI-1017, loan could be written off by anybody at any time:** `test/findings/uni-1017-115-loan-can-be-written-off-by-anybody.ts`. The fix is the time gate `lastRepay + overdueTime + maxOverdueTime` (L816-818). The gate still lets a staker burn its own locked stake on a performing loan.
3. **UNI-1029, third-party full write-off reverted:** `debtWriteOff` called the public `cancelVouch`, which checks `msg.sender`. The fix (commit `7fb32e8`) split out `_cancelVouchInternal`. Test: `test/findings/uni-1029-40-its-impossible-to-writing-off-any.ts`.
4. **UNI-1015, overdue borrowers could not repay:** `test/findings/uni-1015-133-repayborrow-is-inaccessible-by.ts` (commit `a99eed5`). Lesson: a default-state hook must never block repayment.
5. **UNI-1214/1240/1241, frozen coin-age miscalculated** when rewards were withdrawn before the loan went overdue: `test/findings/uni-1214-error-calculating-stakers-frozencoinage.ts` and `test/foundry/testRepayBorrowWhenOverdue.t.sol`. Frozen state is lazy and snapshot-based, and the underflow guard at L841-858 exists because `_memberFrozen` can be stale. Lesson: make frozen/defaulted an explicit per-loan state, not a derived time window.
6. **Decimal-scaling bugs:** commit `295042b` (`_totalStaked` decremented by an unscaled amount in `debtWriteOff`), `1dd601d` (exchangeRateStored decimals), `9425e85`/UNI-1992 (permit repay scaling), UNI-2162 (decimal error). Also see the mixed use of `amount` and `actualAmount` in `debtWriteOff` L866-867.
7. **UNI-1020, unsafe downcasting:** the fix is SafeCast to uint96 everywhere. OBP should use uint256 or checked casts.
8. **Untested guard:** `testCannotLessThanOutstanding` is an empty `// TODO:` (test/foundry/userManager/TestUpdateTrust.t.sol L156-158), so the `TrustAmountLtLocked` path has no test.

Rewards and asset management:
9. **UNI-1028, reward multiplier issuance** (`test/findings/uni-1028-49-union-rewards-issuance.ts`): the 2x multiplier must apply only while stake is actually locked. **UNI-1212, rewards lost on unstake-all** when the Comptroller is underfunded; the fix is the `accrued` carry-over. **UNI-1989**: wrong accrue-reward calculation, and commit `9f1c1ea` makes the global stake be computed after frozen is updated.
10. **AssetManager:** UNI-1206 (adapter removal corrupts `withdrawSeq`; `test/findings/uni-1206-24-...ts`), UNI-1016 (a removed adapter still held funds), UNI-1024 (`rebalance` reverts), UNI-1027 (partial withdrawals), UNI-1030/1031 (lingering max approvals). Lesson: multi-adapter routing carries a lot of risk surface. Start with one ERC-4626 vault.
11. **uToken:** UNI-1994 (audit-2024, redeem burned too few uTokens; fixed with round-up `mulDiv`, commit `bb7454f`), UNI-1221 (zero-amount redeem), UNI-2213 / commit `a340007` (interest wrong after a second borrow).

Design-level issues (my reading, not flagged in the repo):
12. **Over-subscribed stake.** Trust across borrowers can exceed stake (1.2), so a voucher's real exposure is set by borrowing order, not by what it agreed to.
13. **Lock order is not really FIFO.** Swap-and-pop on cancel reorders `_vouchers[borrower]`, so which voucher gets locked or unlocked first changes over time.
14. **Interest and fees.** Interest is unsecured and forgiven on write-off. The origination fee is secured by stake, which means vouchers pay the protocol's fee on default.
15. **No maturity.** Paying only interest resets `lastRepay`, so a loan can roll forever.
16. **Losses never reach the lender accounting.** `_totalRedeemable` is untouched by bad debt (1.6), so the last redeemers absorb the loss implicitly.
17. **Unbounded loops.** `_getEffectiveAmounts` makes one external `getLastRepay` call per vouchee (up to `maxVouchees` = 1000), `updateLocked` loops up to `maxVouchers` = 400, and `getCreditLimit` is flagged as UI-only (L486-488).
18. **Pause and reentrancy gaps.** `UserManager.debtWriteOff` has neither `whenNotPaused` nor `nonReentrant`; it relies on `UToken.debtWriteOff` being `whenNotPaused`. `AssetManager.debtWriteOff` has no auth modifier: it only decrements the caller's own balance, so the effect is harmless, but it is sloppy.
19. **Yield on stake is orphaned** (1.7).

---

## 4. What OBP should change

OBP model: fixed-term loans. Vouchers stake **slices against one specific loan**. Stakes backing an open loan are irrevocable until repayment (release) or default (consumed). The waterfall order is collateral, then this loan's voucher stakes, then insurance, then reserve, then senior lenders. Sanctioned addresses cannot vouch. Locked stake earns base yield.

**Carry over (as ideas, rewritten):**
- The guard set:
  - no self-vouching (UserManager L589);
  - an address with an overdue or defaulted loan cannot open new slices (L604);
  - caps on the number of slices per loan and on active slices per voucher, to bound gas (L608-615; use far smaller caps than 400/1000);
  - locked stake cannot be withdrawn (L772);
  - a public keeper-callable path after a grace window, so defaults cannot be stalled (L816-818).
- Keeping stake principal separate from lendable liquidity (`getLoanableAmount`, AssetManager L183). In OBP, stake funds never fund loans.
- The hook shape: LoanRegistry calls the vouching module on fund/repay/default, and the module never pulls loan state on its own except through view calls.
- Repayment must stay possible in every state before final write-off (lesson of UNI-1015).
- Voucher reputation: Union shrinks `trust` by the written-off amount (L837). OBP should record per-voucher outcomes (loans backed, repaid, defaulted, amount lost) for CreditRegistry and the UI.

**Simplify:**
- Replace trust plus a global stake with a **fully funded slice per loan**. Each slice is `{loanId, voucher, principal, vaultShares}`. The credit line, `min(trust, stake)`, the lock loop and `updateLocked` all disappear, because a slice is locked by construction the moment the loan is funded.
- Replace lazy frozen coin-age with an explicit **per-loan state machine**: `Open` (collecting slices, withdrawable) → `Locked` (loan funded) → `Released` (repaid) or `Defaulted` (waterfall ran) or `Cancelled` (never funded, slices withdrawable). There are no time-derived frozen amounts and no keeper batch updates.
- Split losses **pro-rata by slice principal** within the loan, in O(1): store a per-loan `lossRatio`/`recoveryRatio` and let each voucher claim `slicePrincipal * recoveryRatio`. Drop caller-chosen, per-voucher write-off.
- Write-off initiation: only `LossWaterfall` calls `absorbLoss`, after LoanRegistry has declared default (past due + grace, keeper-callable by anyone). Vouchers cannot write off voluntarily; if they want to help a borrower, they can simply repay on the borrower's behalf.
- Vouchers cover principal only (and possibly the scheduled interest if governance chooses). Never the protocol's origination or reserve fee; that fee is charged to the borrower up front.
- Yield: one OZ ERC-4626 `StakeVault` over a low-risk strategy (Phase 1: idle USDC, the equivalent of `PureTokenAdapter`). Slices hold vault shares, so yield accrues per slice automatically. Cover counts at `min(principal, convertToAssets(shares))`, so a strategy loss cannot silently leave a loan under-covered.
- Units: one asset (USDC) per module, native decimals, no 18-decimal internal scaling.

**Drop:**
- Membership: `registerMember`, `effectiveCount`, `newMemberFee`, `addMember`. Identity comes from IdentityGate (EAS + sanctions), checked on every `stakeSlice` and at release/claim time (a newly sanctioned voucher's claim is escrowed, not paid).
- Comptroller, UNION inflation, coin-age and the reward multiplier. Vouchers earn vault base yield plus the loan's voucher premium, paid in the loan asset on repayment.
- uToken open-market mechanics: exchange rate, `mint`/`redeem`, variable `accrueInterest`, `repayInterest`, and `lastRepay`-based overdue. These are replaced by fixed-term schedules in LoanRegistry and the RateAuction.
- The multi-adapter AssetManager (floors, ceilings, `withdrawSeq`, `rebalance`), `UserManagerOp`/`UserManagerDAI`, `VouchFaucet`, `ERC1155Voucher`, `UnionLens`, and UUPS `Controller`.

**Invariants to encode (from Union's bugs):**
- `sum(slice.principal for loan) == loan.coverPrincipal`, and `sum(slice.shares for loan) == loan.shares`.
- In `Locked` state, no slice can be withdrawn, and the loan's shares can only leave through `release` or `absorbLoss`.
- `absorbLoss(loanId, x)` pays out `<= min(x, loanCoverValue)`. It is called at most once per loan and only after the collateral layer has been fully applied. That last condition is LossWaterfall's invariant, but VouchingModule should assert the loan is `Defaulted`.
- Voucher claims after default sum to `loanCoverValue - absorbed` (± rounding, which rounds against the claimant).
- A sanctioned or blocked address never holds a new slice. A borrower never holds a slice on its own loan.

---

## 5. Suggested minimal interface (OBP `VouchingModule` and its use by `CreditRegistry`)

The sketch below is prose and pseudocode, not Union code. Roles: `LOAN_REGISTRY`, `LOSS_WATERFALL`, and governance via the timelock.

**Storage (conceptual):**
- `loans[loanId] = { borrower, state, requiredCover, coverPrincipal, shares, recoveryAssets, premiumAssets, openUntil }`
- `slices[loanId][voucher] = { principal, shares, claimed }`: one slice per voucher per loan, which blocks trivial splitting across slices. Also keep a small append-only `voucherList[loanId]` for events and views.
- `voucherStats[voucher] = { activeSlices, backed, repaid, defaulted, lost }`
- params: `minSlice`, `maxSlicesPerLoan`, `maxActiveSlicesPerVoucher`

**Called by LoanRegistry:**
- `openCover(loanId, borrower, requiredCover, openUntil)`: state `Open`. `requiredCover` comes from `CreditRegistry.requiredVoucherCoverBps(borrower, tier, principal)` multiplied by the principal.
- `lockCover(loanId)`: requires `Open` and `coverPrincipal >= requiredCover`, then moves to `Locked`. Called atomically with funding. After this, slices are irrevocable.
- `cancelCover(loanId)`: moves `Open` to `Cancelled` (auction failed or loan withdrawn). Every voucher can then `withdrawSlice`.
- `release(loanId, premiumAssets)`: moves `Locked` to `Released`. The premium is transferred in and split pro-rata by principal at claim time. It updates `voucherStats` and decrements `activeSlices`.

**Called by LossWaterfall:**
- `absorbLoss(loanId, lossAssets) returns (absorbed)`: requires `Locked` and that LoanRegistry marks the loan defaulted. It computes `value = vault.convertToAssets(loans.shares)` and `absorbed = min(lossAssets, value)`, redeems enough shares to send `absorbed` to the waterfall recipient, stores `recoveryAssets = value - absorbed` (left as shares), sets state `Defaulted` and updates stats. Loss is pro-rata by construction, because every voucher later claims `slice.principal / coverPrincipal` of the remainder. The function returns `absorbed` so the waterfall moves the rest of the loss to insurance.

**Called by vouchers:**
- `stakeSlice(loanId, assets)`:
  - requires state `Open` and `now <= openUntil`;
  - `IdentityGate.canVouch(msg.sender)` (sanctions oracle and blocked list);
  - `msg.sender != borrower`, and the sender has no overdue or defaulted loan (`LoanRegistry.hasDelinquency(msg.sender)`);
  - `assets >= minSlice`, and `coverPrincipal + assets <= requiredCover` (the cap stops over-staking and keeps the premium share honest);
  - the slice count caps.
  It pulls the asset, deposits it into StakeVault and records the principal and shares.
- `withdrawSlice(loanId)`: only in `Open` or `Cancelled`. Redeems the voucher's shares.
- `claim(loanId)`: only in `Released` or `Defaulted`. Pays the pro-rata share of the remaining vault value (principal plus yield, minus any absorbed loss) plus, if `Released`, the premium share. Rounds down. If the voucher has since become sanctioned, the payout is held for the compliance path instead of transferred.

**Views:**
- `coverOf(loanId) -> (requiredCover, coverPrincipal, coverValue, state)`
- `sliceOf(loanId, voucher)`
- `voucherStats(voucher)`
- `isFullyCovered(loanId)`

**CreditRegistry's side.** The credit limit is **not** derived from vouches; that is Union's model. The limit comes from the borrower's history and tier, and vouches only satisfy the per-loan cover requirement.
- `creditLimit(borrower)` steps up after each repaid loan and is capped by tier.
- `requiredVoucherCoverBps(borrower, tier)` follows the stage table: 60-90% new, 20-40% after 2-3 repaid loans, 0-10% proven. It rises for tier B. For tier C, LoanRegistry enforces collateral + cover >= 100%.
- `recordRepayment(borrower, loanId)` and `recordDefault(borrower, loanId)` are called by LoanRegistry. VouchingModule separately updates voucher reputation, which CreditRegistry may read for voucher-quality weighting in a later phase (out of Phase 1 scope).
- LoanRegistry, not VouchingModule, checks at proposal time that `principal <= creditLimit(borrower)`, and at funding that `VouchingModule.isFullyCovered(loanId)` holds.
