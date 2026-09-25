# Upstream notes: Gnosis EasyAuction, Morpho Blue, MetaMorpho, Vault V2

Scope: what OBP's `RateAuction` and `LenderVault` can learn from or adapt from these four repos. Pinned commits:
- `upstream/ido-contracts` @ e5ec2e696c (gnosis/ido-contracts, Solidity >=0.6.8, SafeMath era)
- `upstream/morpho-blue` @ 8e26ca6a8d
- `upstream/metamorpho` @ ded84e5966 (Morpho Vault V1.0)
- `upstream/vault-v2` @ 1ae84f3552

Paths below are relative to `upstream/`. Line numbers are at the pinned commits.

---

## 1. How each mechanism works

### 1.1 EasyAuction: uniform-price batch auction (`ido-contracts/contracts/EasyAuction.sol`)

**Model.** An auctioneer sells `fullAuctionedAmount` of an auctioning token for a bidding token. Every order, including the auctioneer's reserve order, is a packed `bytes32` of `(uint64 userId, uint96 buyAmount, uint96 sellAmount)` (`IterableOrderedOrderSet.sol:205-232`). For a bidder, `sellAmount` is the bidding tokens they put in and `buyAmount` is the minimum number of auctioning tokens they want back, so their limit price is `buyAmount/sellAmount`: auctioning tokens per bidding token, and lower is better for the auctioneer. The auctioneer's reserve order is `(auctioneerId, minBuyAmount, fullAuctionedAmount)` (`EasyAuction.sol:195-199`).

**State** (`AuctionData`, `EasyAuction.sol:100-115`): `orderCancellationEndDate`, `auctionEndDate`, `initialAuctionOrder`, `minimumBiddingAmountPerOrder`, `interimSumBidAmount` and `interimOrder` (a cursor for settlement across several transactions), `clearingPriceOrder`, `volumeClearingPriceOrder` (the filled part of the marginal order), `minFundingThresholdNotReached`, `isAtomicClosureAllowed`, `feeNumerator`, `minFundingThreshold`. The order book is `mapping(uint256 => IterableOrderedOrderSet.Data) sellOrders` (`:116`).

**Stages** are enforced by timestamp modifiers (`:22-57`): placement until `auctionEndDate`, cancellation until `orderCancellationEndDate` (which must be <= the end date), then the solution-submission stage (after the end, while `clearingPriceOrder == 0`), then finished (`clearingPriceOrder != 0`).

**Sorted order book** (`libraries/IterableOrderedOrderSet.sol`):
- It is a doubly linked list between the sentinels `QUEUE_START` and `QUEUE_END` (`:10-14`), stored as `nextMap` and `prevMap`.
- Order is defined by `smallerThan` (`:149-184`): first by price `buyAmount/sellAmount`, compared by cross-multiplication, then by smaller `buyAmount`, then by smaller `userId`. The same user placing an identical order reverts ("same order twice").
- `insert(self, element, elementBeforeNewOne)` (`:47-97`) takes an off-chain hint. If the hint was removed in the meantime, it walks the `prevMap` history of removed nodes back to a live node (`:78-80`), then scans forward to the insertion point. It returns `false` rather than reverting for a duplicate, an unknown hint, or a hint that is not smaller than the new order.
- `removeKeepHistory` (`:102-115`) keeps the removed node's `prev` pointer so that stale hints still resolve. Cancellation uses it. `remove` (`:121-130`) clears the pointer and is used only at claim time, when no more inserts can happen.

**Placement** (`_placeSellOrders`, `EasyAuction.sol:266-340`):
- Optional allow-list check via `AllowListVerifier.isAllowed` (`:274-286`).
- Each order must beat the reserve price strictly: `minBuy_i * reserveBuy < reserveSell * sell_i` (`:293-299`).
- `buyAmount > 0` and `sellAmount > minimumBiddingAmountPerOrder` (`:305-315`).
- Only the sum of orders whose insert succeeded is pulled in with `transferFrom` (`:316-339`). Bids are escrowed up front.

**Cancellation** (`cancelSellOrders`, `:342-376`): removes the orders with `removeKeepHistory`, checks ownership, and refunds `sellAmount`.

**Clearing** (`settleAuction`, `:451-566`):
- Walk from `interimOrder` (best price first), adding each order's `sellAmount` to `currentBidSum`. The loop stops when `currentBidSum * buyAmountOfIter >= fullAuctionedAmount * sellAmountOfIter` (`:468-479`), i.e. once the bids so far, all valued at the current order's price, demand at least the full supply.
- Case [13] (`:495-504`): the current order is the marginal order and is partly filled, with `volumeClearingPriceOrder = sellAmountOfIter - uncoveredBids`, where `uncoveredBids = currentBidSum - fullAuctionedAmount*sellAmountOfIter/buyAmountOfIter`. The clearing price is that order's price.
- Case [14] (`:505-515`): the current order is not needed at all. The price is a synthetic order `(0, fullAuctionedAmount, prevBidSum)`, which lies strictly between two orders (proof in `security-considerations.md:8-37`).
- Case [15] (`:520-527`): the book ran out while `currentBidSum > minBuyAmount`. The price is `fullAuctionedAmount/currentBidSum`, higher than the last order and every bid is fully filled.
- Case [16] (`:528-540`): even at the reserve price the demand is short. The price is the reserve, and the auctioneer's filled volume is `currentBidSum*fullAuctionedAmount/minBuyAmount`, so the auction only partly sells.
- If `minFundingThreshold > currentBidSum`, the auction is marked failed (`:544-546`). Everyone is then refunded, and the auctioneer gets back tokens plus fee (`:650-656`).
- `processFeesAndAuctioneerFunds` (`:640-688`) pays the auctioneer `fill * priceDenominator / priceNumerator` in bidding tokens plus the unsold tokens, and pays a fee (at most 1.5%, `:131-142`) pro rata to the fill.
- Settlement then clears several storage slots for gas refunds (`:559-565`).

**Gas bound.** `precalculateSellAmountSum(auctionId, steps)` (`:378-411`) moves the cursor over `steps` orders in a separate transaction and reverts ("too many orders summed up") if it would pass the clearing point. `settleAuction` then resumes from the cursor. `settleAuctionAtomically` (`:413-448`) lets one last order be placed and settled in the same transaction, when enabled, and only while the cursor has not advanced past it. The settlement loop only visits orders that are better than the clearing price, so it runs at most (bidding volume up to clearing) / `minimumBiddingAmountPerOrder` times (README:37-38).

**Claiming** (`claimFromParticipantOrder`, `:568-638`): it removes each order (so an order cannot be claimed twice), all orders must belong to one user, and anyone may call it because payment always goes to the order owner.
- Failed threshold: refund `sellAmount` [10].
- Marginal order: auctioning tokens `volumeClearingPriceOrder*num/den`, plus a refund of `sellAmount - volumeClearingPriceOrder` [25].
- Orders better than the clearing price: `sellAmount*num/den` [17].
- Orders worse than the clearing price: full refund [24].
- Every division rounds down, and `security-considerations.md:62-306` proves that total outflow never exceeds total inflow. This is the model for OBP's own rounding argument.

### 1.2 Morpho Blue: isolated markets (`morpho-blue/src/Morpho.sol`)

**Isolation.** A market is `MarketParams{loanToken, collateralToken, oracle, irm, lltv}` and its id is the hash of those params (`IMorpho.sol:6-12`, `MarketParamsLib`). `Market` stores `totalSupplyAssets`, `totalSupplyShares`, `totalBorrowAssets`, `totalBorrowShares`, `lastUpdate` and `fee`, all as uint128 (`IMorpho.sol:26-33`). Each account has a `Position{supplyShares, borrowShares, collateral}`. Losses in one market never touch another. `createMarket` is permissionless but only accepts owner-enabled IRMs and LLTVs, which can never be disabled (`Morpho.sol:150-164`, `IMorpho.sol:86-90`).

**Share accounting** (`libraries/SharesMathLib.sol`):
- `toShares = assets * (totalShares + 1e6) / (totalAssets + 1)` and `toAssets = shares * (totalAssets + 1) / (totalShares + 1e6)` (`:20-44`), with explicit rounding helpers `toSharesDown/Up` and `toAssetsDown/Up`.
- Rounding always favours the protocol: supply mints shares rounded down (`Morpho.sol:183`), withdraw burns shares rounded up (`:216`), borrow mints debt shares rounded up (`:251`), repay burns them rounded down (`:283`).
- The virtual shares and assets make a first-depositor inflation attack uneconomic. The side effect is that the virtual borrow shares behave like bad debt that can never be realised (`SharesMathLib.sol:19`).

**Interest** (`_accrueInterest`, `Morpho.sol:483-509`):
- It runs lazily on every interaction. `borrowRate` is per second, WAD-scaled, and comes from `IIrm.borrowRate(marketParams, market)`.
- `interest = totalBorrow * wTaylorCompounded(rate, elapsed)`, a three-term Taylor approximation of e^(rt) - 1 (`MathLib.sol:38-44`). The same `interest` is added to both totalBorrow and totalSupply.
- The protocol fee takes a cut of interest by minting supply shares to `feeRecipient`, priced against `totalSupplyAssets - feeAmount` so that the fee does not dilute itself (`:494-502`).

**IRM interface** (`interfaces/IIrm.sol:10-19`): `function borrowRate(MarketParams memory, Market memory) external returns (uint256)`, plus a `borrowRateView` variant. The IRM may keep state. Setting `irm = address(0)` means zero interest (`:487`).

**Health and liquidation** (`:347-417`):
- A position is healthy when `collateral * price / 1e36 * lltv >= borrowed(rounded up)` (`:527-539`).
- The liquidation incentive factor is `min(1.15, 1/(1 - 0.3*(1 - lltv)))` (`:365-369`).
- **Bad debt is realised inside `liquidate`**, only when the borrower's collateral reaches 0 (`:390-403`). The remaining borrow shares are converted with `badDebtAssets = min(totalBorrowAssets, shares.toAssetsUp)` and subtracted from **both** `totalBorrowAssets` and `totalSupplyAssets`. That instantly lowers the supply share price, so the loss is spread pro rata over that market's suppliers only.

**Invariants** worth mirroring in OBP tests (`test/invariant/DynamicInvariantTest.sol:33-100`): sum of shares equals total shares, totalSupply >= totalBorrow, token balance + totalBorrow >= totalSupply, and zero collateral implies zero borrow shares (bad debt is always realised).

### 1.3 MetaMorpho (Vault V1): allocator over markets with supply caps (`metamorpho/src/MetaMorpho.sol`)

**Share accounting.** It is an OZ ERC-4626 with `DECIMALS_OFFSET = max(0, 18 - decimals)` (`:62`, `:128`). Conversion is `shares = assets * (supply + 10^offset) / (totalAssets + 1)` (`:652-670`). `totalAssets()` is the sum of `expectedSupplyAssets` over `withdrawQueue` (`:589-593`), so bad debt in any market is **realised in the vault share price immediately**, as soon as Blue writes it off. `lastTotalAssets` (`:106`) is the base for the performance fee, and the fee is charged only on `totalAssets - lastTotalAssets` (`:898-911`).

**Routing.**
- Deposits walk `supplyQueue`, filling each market up to `config[id].cap`. A market that reverts is skipped via try/catch, and the deposit reverts with `AllCapsReached` if anything is left over (`_supplyMorpho`, `:775-805`).
- Withdrawals walk `withdrawQueue`, limited by each market's liquidity (`_withdrawMorpho`, `:807-829`).
- `reallocate(MarketAllocation[])` (`:366-415`) lets allocators move funds between markets. It requires total withdrawn == total supplied and checks the cap on the supply side.
- The queue is limited to `MAX_QUEUE_LENGTH = 30` (`libraries/ConstantsLib.sol:16`), because every deposit or withdraw loops over it.

**Timelocked risk changes.**
- `submitCap` (`:273-289`): lowering a cap takes effect immediately. Raising one writes `pendingCap[id] = {value, validAt = now + timelock}` (`libraries/PendingLib.sol:14-47`), and anyone can call `acceptCap` after `validAt` (`:470-475`, modifier `afterTimelock` `:176-181`).
- The same pattern covers `submitTimelock` (raising the timelock is instant, lowering it is timelocked, `:213-226`), `submitGuardian` (`:257-268`) and `submitMarketRemoval` (`:292-303`, which lets a broken market with non-zero supply be dropped and its funds written off).
- The timelock is bounded between `MIN_TIMELOCK = 1 day` and `MAX_TIMELOCK = 2 weeks` (`ConstantsLib.sol:10-13`).

**Roles** (README:25-110): owner, curator (caps), allocators (queues and reallocate), and guardian. The guardian can only revoke pending timelock, guardian, cap and removal changes (`:420-446`). No role can move funds out of the vault.

### 1.4 Vault V2: adapters, id-based absolute and relative caps (`vault-v2/src/VaultV2.sol`)

**Accounting.**
- `_totalAssets` is recorded state (`:225`). `accrueInterestView` (`:670-699`) computes `realAssets = idle balance + sum(adapter.realAssets())`, then `newTotalAssets = min(realAssets, _totalAssets + _totalAssets*elapsed*maxRate)`.
- So losses are realised at once (the share price falls). Gains are capped at `maxRate` (at most 200% APR, `ConstantsLib.sol`), which smooths the rate and can build a buffer.
- Interest and losses are counted once per transaction: `firstTotalAssets` is a transient variable (`:224`, `:653-662`), which stops flash-loan share shorting around a loss (doc `:30-33`).
- `virtualShares = 10^max(0, 18 - decimals)` plus one virtual asset (`:199`, `:309`, `:702-727`).
- Fees: a performance fee of up to 50% on interest and a management fee of up to 5% a year on assets.

**Caps** (`IVaultV2.sol:8-12`: `Caps{allocation, absoluteCap, relativeCap}` keyed by `bytes32 id`):
- On each `allocate`, the adapter returns the ids of the risk factors the position touches and a signed `change`. For the Blue adapter these are the adapter, the collateral token and the market (`adapters/MorphoMarketV1AdapterV2.sol:268-274`).
- The vault adds `change` to each id's allocation and requires `absoluteCap > 0`, `allocation <= absoluteCap`, and `relativeCap == WAD || allocation <= firstTotalAssets * relativeCap` (`:582-603`).
- Relative caps are "soft": they are not checked on exit (doc `:52-60`). Deallocation updates the allocations but does not check caps (`:610-631`).
- This is the right shape for OBP's per-borrower, per-band, per-country and per-month caps.

**Timelocks** (`:349-381`, doc `:131-145`):
- The curator calls `submit(abi-encoded call)`, which stores `executableAt[data] = now + timelock[selector]`. The target function calls `timelocked()`, which checks the time and that the selector is not `abdicated`, then clears the entry.
- `revoke(data)` is available to the curator or sentinels. Decreasing a timelock is itself subject to that function's timelock (`:469-476`), and `abdicate` permanently freezes a setter (`:478-482`).
- `decreaseAbsoluteCap` and `decreaseRelativeCap` skip the timelock and can be called by the curator or a sentinel (`:537-566`), while the increases are timelocked (`:528-557`).

**Liquidity and exit.**
- Idle cash is used first, then an optional `liquidityAdapter` (`exit`, `:811-829`).
- `forceDeallocate` (`:840-852`) lets anyone pull assets out of an adapter into idle cash for a penalty of up to 2% of the amount, which enables in-kind exit.
- `max*` functions always return 0 (`:744-759`, a non-standard ERC-4626 behaviour).
- Adapters report `realAssets()` (`interfaces/IAdapter.sol:6-19`). A write-off in the Blue adapter is `burnShares` behind a timelock (`MorphoMarketV1AdapterV2.sol:162-167`).

---

## 2. Files and functions worth adapting (with license headers)

| File | Functions / items | SPDX header (line 1) | Use in OBP |
|---|---|---|---|
| `ido-contracts/contracts/EasyAuction.sol` | stage modifiers `:22-57`; `_placeSellOrders` escrow-on-bid pattern; `cancelSellOrders` cutoff; `settleAuction` marginal-fill logic; `claimFromParticipantOrder` claim/refund split; `minFundingThreshold` all-or-nothing | **none** (starts with `pragma solidity >=0.6.8`) | RateAuction lifecycle, rounding proof style |
| `ido-contracts/contracts/libraries/IterableOrderedOrderSet.sol` | `insert` (hinted, history-following), `removeKeepHistory`, `smallerThan` | **none** | only if a linked-list book is kept (not recommended, see section 4) |
| `ido-contracts/contracts/libraries/SafeCast.sol` | `toUint96/64` | `MIT` | not needed on 0.8 (use OZ SafeCast) |
| `ido-contracts/contracts/libraries/IdToAddressBiMap.sol` | user-id registry | **none** | drop |
| `ido-contracts/contracts/interfaces/AllowListVerifier.sol` | `isAllowed(user, auctionId, data)` returning a magic value | `LGPL-3.0-or-later` | idea for an IdentityGate hook |
| `ido-contracts/security-considerations.md` | rounding and solvency proofs | (repo LICENSE) | template for OBP's written proof |
| `morpho-blue/src/libraries/SharesMathLib.sol` | `toSharesDown/Up`, `toAssetsDown/Up`, `VIRTUAL_SHARES/ASSETS` | `GPL-2.0-or-later` | LenderVault share math (OZ ERC4626 MIT does the same, so prefer OZ) |
| `morpho-blue/src/libraries/MathLib.sol` | `mulDivDown/Up`, `wTaylorCompounded` | `GPL-2.0-or-later` | only if continuous compounding is wanted |
| `morpho-blue/src/Morpho.sol` | `liquidate` bad-debt block `:390-403`; `_accrueInterest` `:483-509`; rounding directions in `supply/withdraw/borrow/repay` | `GPL-2.0-or-later` | loss realisation pattern for per-loan lender pools |
| `morpho-blue/src/interfaces/IIrm.sol` | `borrowRate`, `borrowRateView` | `GPL-2.0-or-later` | drop (the auction sets the rate) |
| `morpho-blue/test/invariant/DynamicInvariantTest.sol` | invariant list | `GPL-2.0-or-later` | test ideas |
| `metamorpho/src/MetaMorpho.sol` | `submitCap`/`acceptCap`/`revokePendingCap`, `afterTimelock`, `_supplyMorpho` capped queue fill, `_accruedFeeShares`, `DECIMALS_OFFSET` | `GPL-2.0-or-later` | cap timelock pattern |
| `metamorpho/src/libraries/PendingLib.sol` | `PendingUint192`, `update` | `GPL-2.0-or-later` | pending-value struct for cap increases |
| `metamorpho/src/libraries/ConstantsLib.sol` | timelock bounds, queue limit | `GPL-2.0-or-later` | parameter ideas |
| `vault-v2/src/VaultV2.sol` | `allocateInternal`/`deallocateInternal` id caps `:582-631`; `submit`/`timelocked`/`revoke` `:349-381`; `increase/decrease*Cap` `:528-566`; `accrueInterestView` loss realisation `:670-699`; `firstTotalAssets` | `GPL-2.0-or-later` + `// Copyright (c) 2025 Morpho Association` (line 2) | LenderVault caps and loss realisation |
| `vault-v2/src/interfaces/IAdapter.sol` | `allocate`, `deallocate`, `realAssets` | `GPL-2.0-or-later` + copyright | idea for a per-loan position valuation interface |
| `vault-v2/src/adapters/MorphoMarketV1AdapterV2.sol` | `ids()` risk-factor ids `:268-274`; `realAssets` `:276`; `SharePriceAboveOne` guard `:191` | `GPL-2.0-or-later` | id scheme for exposure caps |

**License flags.**
- **No GPL-2.0-only or GPL-3.0-only file** in `src/` of any of the four repos. Every Morpho `src` file is `GPL-2.0-or-later`, which is acceptable for OBP's AGPL-3.0-or-later. Morpho Blue's README (`:34-37`) notes an earlier **BUSL-1.1** license: only copy from the pinned GPL commit.
- Vault V2 files carry a copyright line (`Copyright (c) 2025 Morpho Association`) that must be kept on any adapted file. Morpho Blue and MetaMorpho files have no copyright line.
- **EasyAuction.sol, IterableOrderedOrderSet.sol, IdToAddressBiMap.sol, DepositAndPlaceOrder.sol and AllowListOffChainManaged.sol have no SPDX header at all.** The repo `LICENSE` is the LGPL v3 text, and it does not by itself say "or later". Only `interfaces/AllowListVerifier.sol` and `test/StateChangingAllowListVerifier.sol` say `LGPL-3.0-or-later`, and `test/IterableOrderedOrderSetWrapper.sol` uses the non-standard `LGPL-3.0-or-newer`. UPSTREAM.md's "LGPL-3.0-or-later" is therefore an inference. Treat the header-less files as **LGPL-3.0 (version unclear)**. LGPLv3 is GPLv3 plus extra permissions, so combining it with AGPLv3 should be possible via GPLv3 section 13, but the founder's lawyer should confirm. Since the section 4 design differs enough from EasyAuction that nothing needs to be copied, the simplest course is to **write RateAuction from scratch** and cite EasyAuction only as a reference in NOTICE.md.
- The EasyAuction code is Solidity 0.6 with SafeMath and uint96 packing, so it would need a full port anyway.
- Not examined: `vault-v2/lib/morpho-blue-irm` (AdaptiveCurveIrmLib, imported by the adapter). Check its header if the adapter is ever adapted.

---

## 3. Known pitfalls and past audit findings

### EasyAuction
- **Order-book DoS via small orders.** The only defence is `minimumBiddingAmountPerOrder` (`EasyAuction.sol:310-315`; test "throws, if DDOS attack with small order amounts is started", `test/contract/EasyAuction.spec.ts:643`). Settlement gas grows with the number of orders better than the clearing price, so a low minimum makes settlement need several `precalculateSellAmountSum` transactions (tests `:720-805`, "too many orders summed up").
- **Silent drop of orders.** `insert` returns `false` for a duplicate or an invalid hint, and `_placeSellOrders` then skips the order with no revert and no event (`:316-333`). Funds are not taken, but the user may believe the bid was placed.
- **Stale hints.** A front-run cancellation can invalidate a hint. This is handled by following the `prevMap` history (`IterableOrderedOrderSet.sol:71-80`), which only stays correct because cancel uses `removeKeepHistory` and claim uses `remove`. The invariant is fragile.
- **Tie-breaking.** Orders at the same price are ordered by smaller `buyAmount`, then by `userId` (`smallerThan`). Test "case 10: it shows an example why userId should always be given: 2 orders with the same price" (`EasyAuction.spec.ts:1508`). The marginal fill therefore goes to whichever tied order sorts first, not pro rata.
- **Spoofing.** A bidder can show large demand and cancel it before `orderCancellationEndDate`. Orders placed after the cutoff are binding. Choose the cutoff so that the last window is binding (tests `:2856-2990`).
- **Atomic closure** (`settleAuctionAtomically`, `:413-448`) gives whoever settles a last look: one order placed after the end, with full knowledge of the book.
- **Fee receiver** can be changed mid-auction (comment `:139`).
- **Limits.** Order amounts are uint96, so auctions raising more than 2^96 units cannot be settled (`:145-148`, README "Warnings"). `claimFromParticipantOrder` reads `orders[0]` without checking that the array is non-empty.
- **Rounding.** Solvency depends on every division rounding down in a specific direction (`security-considerations.md`). Any port must re-prove it.
- **Audits.** G0 Group, Feb and Mar 2021, linked in README:140-142. They are not vendored in the repo and were not read here.

### Morpho Blue (`morpho-blue/audits/`, finding titles extracted from the PDFs)
- Cantina managed review 2023-11-13, High: "First borrower of a market can stop other users from borrowing by inflating totalBorrowShares". This is still documented as a caveat for markets with less than 1e4 assets borrowed (`IMorpho.sol:129-130`).
- Same review, High: "User's funds will be stuck forever if an enabled IRM breaks". IRMs cannot be disabled, and a reverting IRM freezes the market (`IMorpho.sol:118-127` liveness assumptions).
- Same review, High: "Withdrawal or borrowing of loan tokens can be griefed".
- Same review, Informational: "There might not be enough incentives for liquidators to realise bad debt". Bad debt only lands when someone liquidates the last collateral (`Morpho.sol:392`). Until then suppliers can exit at the un-written-down price.
- Cantina competition 2024-01-05, Medium: "Virtual supply shares steal interest" and "Virtual borrow shares accrue interest and lead to bad debt" (the cost of the virtual-share defence, `SharesMathLib.sol:15-19`). Also Medium: liquidation rounding issues, "Users can take advantage of low liquidity markets to inflate the interest rate", and oracle sandwiching.
- Test encoding an edge case: `testBadDebtOverTotalBorrowAssets` (`test/integration/LiquidateIntegrationTest.sol:338`) is why `min(totalBorrowAssets, …)` appears at `Morpho.sol:394-397`.

### MetaMorpho (`metamorpho/audits/`)
- Cantina 2023-11-14, High: "The vault will stop working if one of the Morpho Blue markets used by the vault stops working because of the IRM". `totalAssets()` loops over every market, so one reverting market bricks deposits and withdrawals. The fix was try/catch in the queues plus the timelocked `submitMarketRemoval` write-off (README "Market funds are lost").
- Same review, Medium: "Attackers can redistribute liquidity in MetaMorpho with flashloans and pose threats to smaller markets".
- Same review, Low: "Consider adding slippage protection mechanisms to the MetaMorpho vault" and "Value of underlying markets are not capped and can endanger the whole MetaMorpho". Caps limit only what the vault supplies; interest and donations can push exposure above the cap (README:21-22).
- Same review, Informational: "reallocate can be front-runned by a donation and make it revert because of supply cap exceed".
- ERC-4626 inflation: `deposit` NatSpec (`MetaMorpho.sol:530-533`, `IMetaMorpho.sol:36-40`) says the protection is weak for 18-decimal assets and recommends a non-trivial seed deposit.
- `lastTotalAssets` can exceed `totalAssets()` after socialised bad debt or a forced removal (`IMetaMorpho.sol:80`). The fee then pauses until `lastTotalAssets` is next updated, and there is no high-water mark.
- Re-entrancy: `lastTotalAssets` is written before `_deposit` "to avoid an inconsistent state in a re-entrant context" (`:538-540`), tested with ERC-777 in `test/ReentrancyTest.sol`.

### Vault V2 (`vault-v2/audits/`, 15 reports)
- Spearbit 2025-05-19, High: "Side effects of underlying directly donated to the VaultV2 or adapters positions". This led to `maxRate` and the `SharePriceAboveOne` guard (`MorphoMarketV1AdapterV2.sol:191`).
- Same review, Medium: "forceDeallocate allows user to avoid incurring in losses and dump them on other suppliers", and "Losses across all adapters are not accounted before shares/assets are calculated to deposit/mint/redeem/withdraw". This is the loss front-running class. The adapter still documents that "Burning shares takes time, so reactive depositors might be able to exit before the share price reduction" (`MorphoMarketV1AdapterV2.sol:37`).
- Same review, Medium: "Share to asset exchange rate can be skewed when totalSupply=0 and totalAssets!=0", and "forceDeallocatePenalty should not be set to 0".
- Spearbit 2025-09-15, Low: "firstTotalAssets analysis", "Zero shares could be minted for a non-zero provided asset", and "The allocation upper bound checks are not accurate for aggregated coarse ids".
- Documented caveats (`VaultV2.sol:18-190`):
  - relative caps can be gamed with short-term deposits (`:66`);
  - relative caps make deposits revert when the vault is almost empty (`:109-112`);
  - the `realAssets` loop can cause a gas DoS with many adapters or markets (`:27`);
  - repeated dust losses in a small vault can deflate the share price, so seed the vault (`:43-46`);
  - donations raise the rate and attract dilutive depositors (`:47-48`);
  - gates can lock users out (`:153-164`).

---

## 4. What OBP should change

### RateAuction

**Carry over from EasyAuction:**
- Bids are escrowed at placement: funds move to the contract, never promised. This matches OBP's "locked on-chain up front" principle.
- A cancellation cutoff before the end, so the final window is binding.
- A minimum bid size.
- Settlement is permissionless and callable by anyone after the end.
- Pull-based claims, with refunds for unfilled or partly filled bids.
- An all-or-nothing funding threshold. Kickstarter mode means threshold = P (EasyAuction's `minFundingThreshold`, failure refunds everyone).
- A written rounding and solvency proof in the style of `security-considerations.md`.
- An allow-list hook, replaced by `IdentityGate` (sanctions and KYC attestation) on every bidder.

**Simplify:**
- **No price fractions.** OBP auctions a fixed quantity of one asset, principal P, at a scalar price (APR in bps). The clearing rule becomes: sort bids by rate ascending, and the clearing rate r* is the rate of the first bid at which the cumulative amount reaches P. EasyAuction's synthetic-price cases [14], [15] and [16] do not exist. If demand at rates up to maxRate is below P, the auction fails, with no partial loan in Phase 1: collateral and voucher cover are sized against P.
- **Tick buckets instead of a linked list.** Restrict rates to a grid (for example 5 or 25 bps from 0 to the borrower's `maxRate`) and keep `totalAtTick[t]` plus per-bid records.
  - Settlement scans at most `maxRate/tick` buckets (for example 13% / 25 bps = 52), so gas is constant whatever the number of bids.
  - That removes `precalculateSellAmountSum`, hint handling, `prevMap` history and silent insert failures, and makes the small-order DoS moot.
  - The minimum bid then only limits storage spam and claim-gas griefing.
- **Pro-rata fill at the marginal tick** instead of EasyAuction's arbitrary tie-break. Bids below r* fill fully and bids above are refunded. A bid at the marginal tick fills `amount * (P - sumBelow) / totalAtTick[k]`.
  - **Round the fill up and the refund down**, so the contract never refunds more than it holds.
  - Record each lender's filled amount as their claim, and distribute repayments pro rata to the **sum of recorded fills** rather than to P. The sum of fills can exceed P by at most the number of marginal bids, in wei.
  - Prove this in `progress.md` and cover it with a fuzz or invariant test.
- **Unit and version.** Use a single stablecoin, Solidity 0.8, uint256 amounts, and no uint96 packing or user-id registry.

**Drop:**
- The auctioning-token and fee flow, since the reserve fee is charged elsewhere (in ReserveVault on disbursement).
- `settleAuctionAtomically`, because of the last-look advantage.
- `precalculateSellAmountSum`.
- `IdToAddressBiMap`.
- Anyone-can-open-an-auction. Auctions should be opened only by `LoanRegistry` after the Score and Back steps, with P and maxRate taken from the loan proposal.

**Add for OBP:**
- **Funds in escrow until signing.** After a successful settlement, P stays escrowed until the Insure and Sign steps (lifecycle steps 6-7). If the borrower does not sign by a deadline, or insurance capacity is missing, every filled lender is refunded, a second failure path EasyAuction does not have.
- **Bidder restrictions.** The borrower's address, and ideally vouchers on the same loan, should not be able to bid. A borrower bidding raises no price, but it is a conflict of interest and a wash-funding vector.

### Per-loan lender position (Kickstarter mode)
- Morpho Blue's isolated market maps cleanly to "one loan = one isolated pool". A loss that reaches senior lenders on loan X is spread pro rata only over X's lenders, just as Blue's bad-debt block (`Morpho.sol:390-403`) spreads a loss over one market's suppliers.
- But the lender set is **fixed at settlement**, with no later deposits. So no share math or virtual shares are needed: a lender's weight is `filled_i / sumFilled`. An inflation attack is impossible when shares are minted once, in proportion to cash.
- Use a cumulative "repaid per unit" index for principal, interest and recoveries, so that each lender claims `filled_i * (index - checkpoint_i)`.
- Drop the IRM, oracle/LLTV liquidation, callbacks, flash loans and signature authorisation. The rate is fixed by the auction, and default is by time (missed payments, via `LossWaterfall`), not by price.
- Use simple per-second accrual on the fixed rate, or the repayment schedule from the Huma-derived due manager, instead of `wTaylorCompounded`.
- Loss realisation must not depend on a third party's incentive to liquidate (Cantina "not enough incentives to realise bad debt"). `LossWaterfall` realises the senior loss at a defined default event.

### LenderVault
**Carry over:**
- ERC-4626 with a decimals offset and one virtual asset. Use **OZ `ERC4626` with `_decimalsOffset()`** (MIT, identical formula), rather than copying Morpho, plus a **seed deposit burned at deployment**. Also test the inflation attack and zero-supply/non-zero-assets skew (Spearbit VaultV2 Medium).
- **Vault V2 id-based caps.** The vault's "adapter" becomes the RateAuction and loan positions. Every bid or allocation carries ids for the loan, borrower, risk band, jurisdiction tier, country, sector and origination month. Keep `allocation`, `absoluteCap` and `relativeCap` per id.
  - Check on allocate, which here is bid placement: count the **full escrowed bid** as allocated, because the fill is unknown until settlement. Reduce the allocation on refunds and repayments.
  - Relative caps are checked against total assets at the start of the transaction (Vault V2's `firstTotalAssets`, `:224`), which stops a flash loan inflating the base.
  - This implements CLAUDE.md's concentration limits directly.
- **Asymmetric timelocks.** Cap increases are submit, then accept after a delay. Decreases are instant and can also be made by a guardian or sentinel, who can also revoke pending changes (MetaMorpho `submitCap`/`acceptCap`, Vault V2 `submit`/`timelocked`/`revoke`). In OBP, route submissions through OZ `TimelockController` governance rather than a per-vault curator, since Phase 1 has protocol-run vaults.
- **Immediate loss realisation in share price:** `totalAssets = idle + escrowed bids + sum over loans (outstanding principal + accrued interest - writedown)`. Realise losses at the first transaction after they are known (Vault V2 `accrueInterestView`).

**Change:**
- **Mark down early.** Record the writedown on impairment (the loan is late past a grace period), not only at final default. Otherwise holders who react fast exit at a stale price and leave the loss to others (Vault V2 Spearbit Medium; `MorphoMarketV1AdapterV2.sol:37`).
- **Exit.** Loans are illiquid, so withdrawals can only come from idle cash. Add an epoch-based withdrawal notice, like InsuranceBasket's, so that exits cannot front-run a markdown. `maxWithdraw` should report `min(user assets, idle)` honestly: do not copy Vault V2's always-zero `max*` functions.
- **AI score boundary.** The vault must not bid on a loan purely because `ScoreOracle` put it in band B. That would make the AI score fund a loan by itself, which CLAUDE.md forbids. Suggested gating:
  - the loan's band is confirmed by an allocator or curator role, a human with accountability;
  - and/or required voucher cover is fully staked;
  - and the vault only bids at or above the band's minimum rate.
- **Bounded loops.** Keep the number of open loan positions bounded, or value them with an aggregate updated on each repayment or writedown, so `totalAssets()` stays O(1). Otherwise you inherit the "realAssets loop DoS" and "one reverting market bricks the vault" findings.

**Drop:**
- `supplyQueue`/`withdrawQueue`, `reallocate`, `forceDeallocate` and in-kind redemption: there is no liquid market to reallocate into.
- `maxRate` smoothing, performance and management fees, gates beyond `IdentityGate`, skim/rewards, adapter registry, abdication, and the `multicall`/permit extras. Defer them all to Phase 2 if needed.

---

## 5. Minimal interface sketch (prose / pseudocode, not upstream code)

### RateAuction
Storage per `auctionId`:
- `loanId`, `principal P`, `maxRateBps`, `tickBps`, `minBid`, `cancelEnd`, `end`, `signDeadline`
- `status ∈ {Open, Cleared, Failed, Voided, Finalized}`, `clearingTick`, `sumBelow`, `sumFilled`
- `totalAtTick[tick]`, and `bids[bidId] = {lender, amount, tick, claimed}`

Functions:
- `openAuction(loanId, P, maxRateBps, tickBps, minBid, cancelEnd, end)`, callable only by LoanRegistry. Requires `cancelEnd <= end` and `maxRateBps % tickBps == 0`.
- `placeBid(auctionId, amount, rateBps) returns bidId`, while Open and before `end`.
  - Checks: `IdentityGate.isAllowed(msg.sender)`; sender is not the borrower or a voucher of the loan; `amount >= minBid`; `rateBps <= maxRateBps`; `rateBps % tickBps == 0`.
  - Pulls `amount` in, then `totalAtTick[rate/tick] += amount`.
  - If the sender is a LenderVault, the vault checks its own caps first.
- `cancelBid(bidId)`, only by the lender and before `cancelEnd`. Refunds the amount and reduces `totalAtTick`.
- `settle(auctionId)`, by anyone, after `end`. Scans ticks upward, accumulating `cum`.
  - At the first tick k with `cum >= P`: set `clearingTick = k` and `sumBelow = cum - totalAtTick[k]`, set status Cleared, and hand P to loan escrow, which waits for insurance and signature.
  - If no tick reaches P, set status Failed.
  - Emits the clearing rate `r* = k * tickBps`.
- `claim(bidIds[])`, by anyone, paying each bid's lender.
  - Failed or Voided: full refund.
  - Cleared: `tick < k` fills fully; `tick == k` fills `ceil(amount * (P - sumBelow) / totalAtTick[k])` with the rest refunded; `tick > k` is refunded in full.
  - Each fill registers the lender's position `filled_i` in the loan's lender pool and adds it to `sumFilled`.
- `void(auctionId)`, called by LoanRegistry if the borrower does not sign by `signDeadline` or insurance assignment fails. P returns from escrow and every bid becomes fully refundable.

Invariants and fuzz targets:
- Token balance >= all unclaimed refunds plus unfilled escrow.
- `sumFilled` lies in [P, P + number of marginal bids].
- Every filled bid's rate <= r* <= maxRate.
- No bid below r* is unfilled.
- A cancelled or claimed bid cannot be claimed again.
- A lender's total return equals `filled_i` at r*, whatever order claims happen in.

### Loan lender pool (can live in LoanRegistry or a small `LoanPositions` module)
- `positionOf(loanId, lender) → filled`
- `distribute(loanId, amount, kind)`, called by LoanRegistry on repayment or by LossWaterfall on recovery. Adds `amount / sumFilled` to the loan's cumulative index.
- `withdrawable(loanId, lender) = filled * (index - checkpoint)`, and `withdraw(loanId)`.
- `realizeSeniorLoss(loanId, loss)`, called only by LossWaterfall after layers 1-4 are exhausted. Records the writedown so that vault valuation and lender statements reflect it.

### LenderVault (ERC-4626, one asset, one or more risk bands)
- Standard `deposit/mint/withdraw/redeem` (OZ ERC4626, decimals offset, seeded).
  - `withdraw`/`redeem` are limited to idle cash, optionally with epoch notice via `requestRedeem(shares)` then `redeem` after N days.
  - Accrues and realises losses first, at most once per transaction.
- `totalAssets() = idle + pendingBidEscrow + Σ loanValue`, where `loanValue = outstanding principal share + accrued interest - writedown`. Keep it as an aggregate that repayment and writedown hooks update, to avoid unbounded loops.
- `bid(auctionId, amount, rateBps)`, called only by an allocator. Requires the loan's band to be confirmed (not AI-only) and `rateBps >= bandMinRate[band]`.
  - Computes the ids {loan, borrower, band, tier, country, sector, month}. For each id: `allocation += amount`, then require `allocation <= absoluteCap` and `allocation <= totalAssetsAtTxStart * relativeCap`.
  - Then calls `RateAuction.placeBid`. On refund, claim or repayment, `allocation -= amount returned`.
- `submitCapIncrease(id, abs, rel)` then `acceptCapIncrease(id)` after `timelock`. `decreaseCap(id, abs, rel)` is instant for governance or the guardian. `revokePending(id)` is for the guardian.
- `markDown(loanId, amount)`, callable by LoanRegistry on impairment and by LossWaterfall on default. It lowers `totalAssets`, so the share price falls immediately. `markUp` applies on recovery.

LenderVault tests:
- inflation attack on the first deposit;
- donation does not change caps;
- flash-loan deposit cannot widen relative caps within one transaction;
- the share price only falls through markDown or realised loss;
- the sum of per-id allocations matches the positions held;
- no cap is exceeded after `bid`.
