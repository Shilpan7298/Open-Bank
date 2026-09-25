# Nexus Mutual staking: notes for OBP InsuranceBasket

Source: `upstream/smart-contracts/` (NexusMutual/smart-contracts @ 9e885628e9). All paths below are relative to that folder. Line numbers are at that commit.

Terminology clash: in Nexus a **tranche** is a 91-day *time cohort* of stake (when it unlocks). In OBP a tranche is a *seniority layer* (junior/senior). This note says "time-tranche" for the Nexus meaning and "junior/senior" for the OBP meaning.

## 1. How the mechanism works

### 1.1 Time grid
- `TRANCHE_DURATION = 91 days`, `MAX_ACTIVE_TRANCHES = 8` (7 whole quarters + current partial), `BUCKET_DURATION = 28 days` (`contracts/modules/staking/StakingPool.sol:100-106`).
- `trancheId = timestamp / 91d`, `bucketId = timestamp / 28d`. Ids are absolute from the Unix epoch, not per-pool.
- Stake is locked until the end of the time-tranche it was deposited into. Deposit must target a tranche in `[currentTrancheId, currentTrancheId + 7]` (`StakingPool.sol:329-334`). `extendDeposit` moves shares to a later tranche (`StakingPool.sol:1014`).
- Covers end on bucket boundaries in practice: expiry bucket = `ceil((start + period) / 28d)`; min cover period is 28 days, max 365 days (`contracts/modules/cover/Cover.sol:52-53`).

### 1.2 Stake, shares and expiry
Pool-level state (`StakingPool.sol:34-65`): `activeStake`, `stakeSharesSupply`, `rewardsSharesSupply`, `accNxmPerRewardsShare`, `rewardPerSecond`, `firstActiveTrancheId`, `firstActiveBucketId`, `lastAccNxmUpdate`.
Per time-tranche: `Tranche{stakeShares, rewardsShares}`; per (NFT, time-tranche): `Deposit{lastAccNxmPerRewardShare, pendingRewards, stakeShares, rewardsShares}` (`contracts/interfaces/IStakingPool.sol:43-59`).

- Shares are pool-wide: `newShares = supply == 0 ? sqrt(amount) : supply * amount / activeStake` (`StakingPool.sol:368-370`). One share price across all time-tranches, so a burn hits every active time-tranche pro rata.
- Stake of a time-tranche = `activeStake * tranche.stakeShares / stakeSharesSupply` (`StakingPool.sol:809`).
- `processExpirations(bool)` (`StakingPool.sol:182-314`) walks forward, interleaving bucket and tranche boundaries in time order:
  - Bucket boundary: accrue rewards up to the bucket start, then `rewardPerSecond -= rewardPerSecondCut[bucket]`.
  - Tranche end: accrue rewards up to tranche end, snapshot `ExpiredTranche{accNxmPerRewardShareAtExpiry, stakeAmountAtExpiry = activeStake, stakeSharesSupplyAtExpiry}`, then remove that tranche's pro-rata stake and its shares from the active totals.
- Withdraw (`StakingPool.sol:451`, `_processTrancheWithdrawal` at `:496`): stake only from expired tranches, valued from the snapshot: `stakeAmountAtExpiry * deposit.stakeShares / stakeSharesSupplyAtExpiry` (`:507-509`). Rewards can be withdrawn at any time. Once a time-tranche expires its stake is frozen at the snapshot and **can no longer be burned**.

### 1.3 Capacity
The header comment (`StakingPool.sol:17-22`) sums it up:
- total capacity = activeStake * globalCapacityRatio
- product capacity = total capacity * (1 - capacityReductionRatio) * productTargetWeight
- Per time-tranche, `getTrancheCapacities` (`StakingPool.sol:778-814`) gives
  `capacity[i] = trancheStake[i] * capacityRatio * (10000 - reductionRatio) * targetWeight / (10000 * 10000 * 100) / NXM_PER_ALLOCATION_UNIT`.
- `GLOBAL_CAPACITY_RATIO = 20000` (2x) is a constant in `Cover.sol:46`. `capacityReductionRatio` is per product (`CoverProducts`). `targetWeight` is 0..100 per product, set by the pool manager.
- Weights can sum to `MAX_TOTAL_WEIGHT = 2000` (20x, `StakingProducts.sol:46`). The same stake backs many products at once. Loss is bounded by stake, but gross capacity can be up to 2 x 20 = 40x stake.
- Units: 1 allocation unit = 0.01 NXM (`ALLOCATION_UNITS_PER_NXM = 100`, `StakingPool.sol:119-125`). Capacities round down (`:810`) and cover amounts round up (`divCeil` `:829`, `Math.roundUp` in `Cover.sol:421`). Both directions are conservative.

### 1.4 Allocation to covers (`_allocate`, `StakingPool.sol:816-923`)
- Eligible time-tranches: only those still active at `now + period + gracePeriod`: `firstTrancheIdToUse = (now + period + gracePeriod) / 91d` (`:835`). A cover is therefore never backed by stake that unlocks before the claim window closes.
- Carry-over: for tranches before `startIndex`, over-allocation (allocated > capacity, which happens after burns or when stake leaves) is summed into `carryOver` (`:850-860`). In the eligible tranches carryOver is first subtracted from free capacity, then the request is filled greedily from the earliest eligible tranche (`:864-901`). Reverts `InsufficientCapacity` if anything is left over (`:905`).
- `initialCapacityUsed` and `totalCapacity` are returned for pricing.
- Per-cover record: `coverTrancheAllocations[allocationId]` packs 8 x uint32 amounts, one per active time-tranche at buy time (`:82-84`, `:900-903`).

### 1.5 Bucketed expiry of allocations
- Active allocations per product: `trancheAllocationGroups[productId][groupId]`, where each group packs 5 x uint48 allocations plus a uint16 `lastBucketId` (`contracts/modules/staking/StakingTypesLib.sol:5-7`, `:20-53`).
- Scheduled expiries: `expiringCoverBuckets[productId][bucketId][groupId]` packs 8 x uint32 amounts per time-tranche (`StakingTypesLib.sol:13-14`, `:57-76`; `StakingPool.sol:80`).
- On buy, `_updateExpiringCoverAmounts(..., targetBucket = ceil((now+period)/28d), isAllocation=true)` adds the cover's per-tranche amounts to its expiry bucket (`StakingPool.sol:908-914`, `:962-1006`).
- Lazy read: `getActiveAllocations` (`StakingPool.sol:666-690`) loads the stored allocations and subtracts every expiry bucket from `lastBucketId+1` to the current bucket. Storage is rewritten with the new `lastBucketId` on the next mutation (`_updateStoredAllocations`, `:925-960`). Expiry is O(buckets elapsed), not O(covers).
- Explicit deallocation (`requestDeallocation`, `:579-628`) on cover edit or `Cover.expireCover` (`Cover.sol:372`) subtracts the cover from both stored allocations and its bucket, and stops its reward stream. Guard: `AlreadyDeallocated` if the allocation is already gone or its bucket has passed (`:594`).
- The same pattern exists at protocol level: `Cover._updateTotalActiveCoverAmount` (`Cover.sol:569-611`) keeps `totalActiveCoverInAsset` with 7-day expiry buckets. `Pool` then sets MCR = activeCover / 4.8 (`GEARING_FACTOR = 48000`, `contracts/modules/capital/Pool.sol:50`, `:375-376`), a system-wide leverage limit.

### 1.6 Rewards (premium streaming)
- On allocation: `rewards = premium * rewardRatio / 10000` (`GLOBAL_REWARDS_RATIO = 50%`, `Cover.sol:47`), streamed until the end of the expiry bucket. `rewardPerSecond += r`, and `rewardPerSecondCut[expiryBucket] += r` (`StakingPool.sol:565-574`). The full amount is minted to the pool up front.
- MasterChef-style accumulator `accNxmPerRewardsShare += elapsed * rewardPerSecond * 1e18 / rewardsSharesSupply`. Pool-manager fee is paid as extra reward shares held under tokenId 0 (`:397-414`, `setPoolFee` `:1246`).
- On early deallocation the remaining stream is burned (`:611-624`).

### 1.7 Pricing (`contracts/modules/staking/StakingProducts.sol:347-452`)
- Per (pool, product): `StakedProduct{lastEffectiveWeight, targetWeight, targetPrice, bumpedPrice, bumpedPriceUpdateTime}` (`contracts/interfaces/IStakingProducts.sol:24-30`). Prices are annual rates in basis points of 10000.
- `targetPrice = max(product.targetPrice, productMinPrice)`. The minimum is the product's min price or `DEFAULT_MIN_PRICE_RATIO = 100` (1%) (`Cover.sol:58`).
- Decay: `basePrice = max(targetPrice, bumpedPrice - PRICE_CHANGE_PER_DAY * dt / 1 day)` with `PRICE_CHANGE_PER_DAY = 200` (2 percentage points/day) (`getBasePrice`, `:402-418`).
- Bump: `priceBump = PRICE_BUMP_RATIO * coverAmount / totalCapacity` with `PRICE_BUMP_RATIO = 500`, i.e. +5 pp if the buy uses 100% of capacity (`:432`). The stored price becomes `bumpedPrice = basePrice + priceBump`.
- Premium: `coverAmount * unit * basePrice / 10000 * period / 365 days` (`:448-451`). **The buyer pays the pre-bump base price**; the bump only affects the next buyer. Fixed-price products skip bump and decay (`calculateFixedPricePremium`, `:385-400`).
- **No surge pricing at this commit.** Grepping for "surge" finds nothing. Older Nexus v2 had a surge above ~90% utilization; it has been removed here. Only bump and decay remain.
- Effective weight (`_getEffectiveWeight`, `:323-345`) is `max(targetWeight, allocated*100/totalCapacity)` and caps at uint16 max. It is bookkeeping for `MAX_TOTAL_WEIGHT` when a manager raises weights (`:298-299`).

### 1.8 Claim to burn path
1. `Claims.submitClaim` (`contracts/modules/assessment/Claims.sol:127`) requires `now < start + period + gracePeriod` (`:161`) and a 0.05 ETH deposit, then starts an assessment: 3-day vote (`Assessments.sol:31`) plus a per-product-type cooldown.
2. `Claims.redeemClaimPayout` (`Claims.sol:205`) runs once the claim is accepted and inside the redemption window (`_isClaimRedeemable` `:108-113`). It calls `Cover.burnStake(coverId, amount)` (`:221`) and then `pool.sendPayout`.
3. `Cover.burnStake` (`Cover.sol:613-655`): per pool allocation, `deallocation = allocation.coverAmount * payout / cover.amount` and `burn = deallocation * 10000 / cover.capacityRatio` (`:622-623`). With a 2x ratio, **stakers burn only half the payout**. The mutual's capital pool pays the full claim, so stakers are a pro-rata co-insurer, not first loss. The capacity ratio is snapshotted per cover (`CoverData.capacityRatio`) so later parameter changes do not reprice old covers.
4. `StakingPool.burnStake` (`StakingPool.sol:1163-1242`): `activeStake -= amount`. If `amount >= activeStake`, it burns `activeStake - 1` and sets `isHalted = true` (`:1173-1176`), which blocks deposits and extensions. If the cover has not expired, it deallocates `deallocationAmount`, taking from the **latest** time-tranches first (`:1206-1225`), and updates bucket and stored allocations.

## 2. Files and functions worth adapting

The repo `LICENSE` is GPLv3. SPDX headers were read at the pinned commit:

| File | SPDX | Functions / ideas |
|---|---|---|
| `contracts/modules/staking/StakingPool.sol` | **GPL-3.0-only** | `processExpirations(bool)`, `getActiveAllocations(uint)`, `_allocate(...)` (carry-over loop), `_updateExpiringCoverAmounts(...)`, `burnStake(uint, BurnStakeParams)` (halt-at-1-wei, deallocate on burn), `requestDeallocation(DeallocationRequest)`, reward accumulator in `depositTo` / `_processTrancheWithdrawal` |
| `contracts/modules/staking/StakingProducts.sol` | **GPL-3.0-only** | `getBasePrice(uint,uint,uint,uint)`, `calculatePremium(...)`, `calculateFixedPricePremium(...)`, `_getEffectiveWeight(...)` |
| `contracts/modules/staking/StakingTypesLib.sol` | **GPL-3.0-only** | packed `TrancheAllocationGroup` / `TrancheGroupBucket` (not recommended, see §4) |
| `contracts/modules/cover/Cover.sol` | **GPL-3.0-only** | `_updateTotalActiveCoverAmount(...)` (global bucketed active cover), `burnStake(uint,uint)` (pro-rata burn across pools, per-cover param snapshot), `recalculateActiveCoverInAsset(uint)` (repair path) |
| `contracts/modules/capital/Pool.sol` | **GPL-3.0-only** | `updateMCR` gearing logic, `activeCover / GEARING_FACTOR` (idea only) |
| `contracts/modules/assessment/Claims.sol` | **GPL-3.0-only** | `_isClaimRedeemable` timing windows (idea only; OBP defaults are not claims) |
| `contracts/interfaces/IStakingPool.sol`, `IStakingProducts.sol` | **GPL-3.0-only** | struct layouts only |
| `contracts/libraries/Math.sol` | **GPL-3.0-only** | `divCeil`, `roundUp`, `sqrt`. Use OZ `Math` (MIT) instead. |
| `contracts/libraries/SafeUintCast.sol` | MIT | Use OZ `SafeCast` instead. |
| `contracts/libraries/FloatingPoint.sol` | GPL-3.0-or-later | not needed |

- No GPL-2.0-only files are among those recommended.
- Every recommended Nexus file is **GPL-3.0-only** ("only", not "or later"). GPLv3 section 13 lets GPL-3.0 code be combined with AGPL-3.0 code, but the GPL-3.0-only files keep their own license and cannot be relabelled AGPL-3.0-or-later. **The founder must confirm this license combination with a lawyer before any Nexus code is copied.**
- Recommendation: OBP's basket differs enough (seniority layers, epoch withdrawals, event-driven exposure) that a fresh implementation from this note is simpler than adapting Nexus code. If any adapted fragment survives, keep its GPL-3.0-only header and record it in `NOTICE.md`.

## 3. Known pitfalls and past findings visible in the repo

There is no audit folder in the repo. `README.md:16-18` points to an external audit list, and `release/3.0/release-3.0.md:5` links an Aug 2025 governance/assessments audit PR. The evidence below comes from code comments and tests.

1. **Full burn breaks share math.** Burning all stake would leave shares with zero backing (the next deposit divides by `activeStake = 0`). The fix is to leave 1 wei and halt the pool (`StakingPool.sol:1172-1176`). Tests: `test/unit/StakingPool/burnStake.js:119` (halts at 100%), `:141` (99% does not halt), `:213` (burn greater than stake).
2. **First-depositor share inflation.** The first deposit mints `sqrt(amount)` shares, not `amount` (`StakingPool.sol:368-370`). OBP's ERC-4626 junior/senior vaults need an equivalent: OZ virtual shares/decimals offset, or a seeded deposit.
3. **Over-allocation after burns or stake exit.** Allocations can exceed capacity once stake shrinks. `_allocate` carries the excess forward instead of reverting (`StakingPool.sol:850-873`). Tests: `test/unit/StakingPool/requestAllocation.js:1578`, `:1632`. Lesson: after a loss, the basket can be over its leverage limit. That must block *new* cover, never revert repayments or loss handling.
4. **Pack overflow.** Per-tranche allocations are uint32 in units of 0.01 NXM. Test `requestAllocation.js:428` asserts that a huge cover reverts on `SafeCast`. Any packing in OBP needs explicit bounds tests (USDC has 6 decimals).
5. **Underflow on lazy expiry.** `requestAllocation.js:347` ("shouldnt underflow while expiring cover during allocate capacity") exists because bucket subtraction and re-allocation can race when time advances.
6. **Burn deallocation rules.** No deallocation after expiry or during the grace period (`StakingPool.sol:1188-1191`; tests `burnStake.js:423`, `:459`). Deallocation takes from the latest time-tranches first (`:1206`). Rounding: allocation rounds up (`:829`) while burn deallocation rounds down (`:1199`), so dust stays allocated until the bucket expires.
7. **Double deallocation.** Guarded by `AlreadyDeallocated` (`StakingPool.sol:594`). Related tests on the deallocation path: `requestAllocation.js:555` (zero-amount edit only deallocates) and `:1688` (removes allocations on cover expiry).
8. **Stake can leave before a late claim is burned** (my reading; verify). Eligibility only covers `period + gracePeriod` (`StakingPool.sol:835`). The burn happens at *redemption* (`Claims.sol:221`), after the 3-day vote, the cooldown and the redemption window. A claim filed at the end of the grace period can be burned after the backing time-tranche expired and was snapshotted (`:267-271`). The snapshot stake is then unburnable and its stakers may already have withdrawn. OBP must not let capital leave while a covered loan is late or in default.
9. **Pro-rata burn across all time-tranches.** Burn reduces `activeStake` for every active tranche (`StakingPool.sol:1181` with `:809`), including tranches that did not back the claimed cover. This is acceptable in a mutual; OBP wants junior-then-senior ordering instead.
10. **Unbounded catch-up loops.** `processExpirations` (`:222`) and `getActiveAllocations` (`:680`) loop over every elapsed bucket and tranche since the last touch. The cost is bounded in practice (28-day buckets), but OBP should keep coarse epochs for the same reason. `lastBucketId` is uint16 (`StakingTypesLib.sol:20`).
11. **Docs drift from code.** `docs/contracts/StakingProducts.md:39` says decay is 0.5%/day; the code uses 2%/day (`StakingProducts.sol:42`). `StakingProducts.md:29` says "effective weight never exceeds the target weight"; the code returns `max(target, actual)` (`StakingProducts.sol:344`). Trust the code.
12. **Bump pricing favours one big buyer.** The premium uses the pre-bump price, so one purchase can take 100% of capacity at base price (test `requestAllocation.js:374`), while the same amount split into several buys pays more. The price is also path dependent (depends on buy order and timing), which makes it harder to simulate.
13. Open TODOs: `StakingPool.sol:256` ("check if we have to expire the tranche"), `:797`.

## 4. What OBP should change

OBP basket = one pool per (risk band, jurisdiction tier), with junior and senior share classes. It pays loan loss after collateral and vouchers, junior before senior, and the ReserveVault takes what the basket cannot.

**Carry over (as ideas, re-implemented):**
- Capacity as a ratio of capital: Nexus `capacity = stake * 2`, OBP `capacity = 3 * (juniorAssets + seniorAssets)`. Snapshot the ratio per loan, as Nexus does with `CoverData.capacityRatio`.
- Per-product weight as a per-bucket cap: Nexus `productCapacity = capacity * weight`, OBP `countryCap = sectorCap = monthCap = 25% * capacity`. This is a uniform "target weight" of 25 on each concentration dimension.
- Blocking new cover when over the limit without reverting existing positions (carry-over lesson, pitfall 3).
- Halt / 1-wei rule when a share class is wiped out (pitfall 1), and inflation protection on first deposit (pitfall 2).
- Maturity buckets for *projections*: expected exposure run-off per epoch tells the withdrawal queue when capital will free up. Nexus uses the same bucket structure to expire allocations.
- A global active-exposure total, like `Cover.totalActiveCoverInAsset`, which lets ReserveVault size its cap and reinsurance (compare Nexus MCR gearing).
- Per-loan loss handling: deallocate cover by the loss amount, and snapshot pricing and ratio parameters at assignment.

**Simplify:**
- **Exposure removal should be event-driven, not time-driven.** A Nexus cover simply expires at a timestamp. An OBP loan past maturity and unpaid is *late or defaulting*, which is exactly when cover matters. Exposure must be removed only on repayment (partial or full) or on final default settlement. Expiry buckets become projections, not the source of truth. Concentration counters (country/sector/month) also need per-loan decrements, which buckets cannot provide cheaply.
- **No packed storage.** Loans per basket are few and large. Use plain `uint256` or `uint128` per-loan records and per-dimension totals. Drop `StakingTypesLib`.
- **Pricing.** Loan rate comes from RateAuction; the insurance premium is a governable per (band, tier) rate at launch (the `calculateFixedPricePremium` analogue: `cover * rate * term / 365d`). If a dynamic premium is added later, prefer a deterministic utilization curve evaluated on post-assignment utilization over Nexus bump/decay (pitfall 12). Tune it in `sim/`.
- **Rewards.** If premiums arrive with each repayment, credit them to junior/senior on receipt by a fixed split; no per-second streaming is needed. If a premium is ever paid up front, stream it to maturity with a per-epoch cut (Nexus `rewardPerSecondCut`). Otherwise a depositor can join just before the premium lands and capture it.

**Drop:**
- Time-tranches with fixed 91-day locks, `extendDeposit`, the staking NFT, pool-manager fee shares, and private pools. OBP uses epoch notice withdrawals (see Huma `EpochManager`).
- Multiple products per pool with weights summing to 20x (`MAX_TOTAL_WEIGHT`). OBP leverage (3x) is measured on the **sum** of all exposures in a basket; the same capital must not be reused per product.
- Pro-rata co-insurance burn (`burn = payout / capacityRatio`). The OBP basket is first loss after vouchers: it absorbs 100% of the covered loss up to its capital, junior then senior.
- Claims/assessment voting. Default is a LoanRegistry state transition, not a claim vote.
- Withdrawal valued from a frozen snapshot (`ExpiredTranche`). OBP requires pending withdrawals to keep absorbing losses, so withdrawals are queued as **shares** and priced at processing time.

## 5. Suggested minimal design: capacity and concentration in `InsuranceBasket`

State per basket (band, tier):
- `junior`, `senior`: share class with `assets`, `shares`, `halted`. Queued withdrawal shares stay in `shares` until paid, so losses reduce their value.
- `totalExposure`, `exposureByCountry[c]`, `exposureBySector[s]`, `exposureByMonth[m]` (m = origination month index).
- `loanCover[loanId] = {exposure, country, sector, month, maturityEpoch, capacityRatioSnap}`.
- `maturingExposure[epoch]`: projection only.
- Params (governable, snapshotted per loan where they affect a loan): `LEVERAGE = 3`, `CONC_BPS = 2500`, `premiumRateBps`.

Helper: `capital() = junior.assets + senior.assets`; `capacity() = LEVERAGE * capital()`.

Assign cover (called by LoanRegistry at step 6; `exposure = principal - collateral - voucherCover`, floored at 0):
1. Require the basket is not halted and the loan is not already covered.
2. `newTotal = totalExposure + exposure`; require `newTotal <= capacity()`.
3. `cap = CONC_BPS * capacity() / 10000`. Require each of `exposureByCountry[c] + exposure`, `exposureBySector[s] + exposure` and `exposureByMonth[m] + exposure` is `<= cap`. The cap is measured against capacity rather than current exposure, so the first loans in a young basket are not blocked and the limit equals 25% of exposure once the basket is full. Confirm this choice in simulation.
4. Write totals, the per-loan record and `maturingExposure[maturityEpoch] += exposure`; compute the premium from the snapshotted rate.
5. If a check fails, revert. The loan stays unfunded or needs more collateral or voucher cover. The reserve does not absorb it.

Reduce cover (on repayment of principal):
- Set `delta = min(record.exposure, principalRepaid)`, or recompute exposure from outstanding principal net of released collateral.
- Subtract `delta` from the record, `totalExposure`, the three dimension counters and `maturingExposure[maturityEpoch]`. On full repayment, delete the record.

Absorb loss (called only by LossWaterfall, after collateral and vouchers):
1. `hit = min(remainingLoss, record.exposure)`.
2. `j = min(hit, junior.assets)`, `junior.assets -= j`. `s = min(hit - j, senior.assets)`, `senior.assets -= s`. Return `remainingLoss - j - s` to LossWaterfall for the ReserveVault.
3. If a class's assets fall to 0 (or dust) with shares outstanding, mark it halted (Nexus pitfall 1). Deposits into a halted class revert until governance resets it.
4. Remove the loan's full exposure from all counters, whether the loss was full or partial. The loan is settled.
5. Do not revert when `totalExposure > capacity()` after the loss. Only new assignments are blocked (pitfall 3).

Withdrawals (epoch-based, 30–90 day notice):
- A request records shares and an eligible epoch. At epoch close, `free = capital() - ceil(totalExposure / LEVERAGE)`, reduced further so that each dimension counter stays within `CONC_BPS * LEVERAGE * capitalAfter / 10000`.
- Pay queued requests (junior and senior queues handled separately, senior first if governance wants junior to stay last out) up to `free`, pricing shares at current assets. The unpaid remainder rolls to the next epoch and stays at risk and earning.
- Pause payouts from a basket while any covered loan is late or in default, or hold back its estimated loss (pitfall 8).
- `maturingExposure` lets the UI show when queued capital is expected to free up.

Invariants to fuzz (definition of done):
- `totalExposure == sum(loanCover[*].exposure)`, and each dimension counter equals the sum over its loans.
- After any assignment: `totalExposure <= capacity()` and every dimension counter is `<= cap`.
- After any withdrawal payout: the same inequalities hold with the post-payout capital.
- Junior assets are never reduced by a loss while senior was reduced for the same loan with junior > 0 (waterfall order). The basket never absorbs more than `record.exposure` per loan.
- Share price is monotone except through `absorbLoss`. No mint happens against zero assets.

Open questions for simulation and the founder: whether concentration caps should use exposure or capacity as the denominator; whether to add a minimum junior share of basket capital (otherwise senior can end up first loss); and epoch length (a coarse epoch keeps catch-up loops cheap, pitfall 10).
