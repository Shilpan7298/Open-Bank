# Upstream open-source repos

Checked on 2026-09-24 by shallow-cloning each repo and reading its LICENSE file and the SPDX headers in its `.sol` files. Pin to the commits below; re-check the license at the pinned commit before copying anything. This is an engineering triage, not legal advice.

## Incorporate (license allows adapting the code)

| Repo | Commit | License | What OBP takes from it | Maps to |
|---|---|---|---|---|
| [OpenZeppelin/openzeppelin-contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | 4858ab13a5 | MIT | ERC20, ERC4626, AccessControl, TimelockController, Pausable, ReentrancyGuard, SafeERC20, EIP712 | everything |
| [unioncredit/union-v2-contracts](https://github.com/unioncredit/union-v2-contracts) | 67bc59b7ee | MIT | Vouching and staking: `user/UserManager.sol` (stake, vouch, locked stake, frozen stake on default, write-off), `market/UToken.sol` (credit-line borrowing against vouches), `asset/AssetManager.sol` (stakes earning yield while locked) | VouchingModule, CreditRegistry, yield vault for stakes |
| [goldfinch-eng/mono](https://github.com/goldfinch-eng/mono) | bb251675d8 | MIT (a few GPL-3.0-only files; avoid those) | `protocol/core/TranchedPool.sol` + `TranchingLogic.sol` (per-loan backers, the Kickstarter mode), `SeniorPool.sol` + `FixedLeverageRatioStrategy.sol` (automated lending into loans), `Accountant.sol` (lateness, writedowns), `UniqueIdentity.sol` (KYC-gated identity token) | LoanRegistry, LenderVault, IdentityGate |
| [00labs/huma-contracts-v2](https://github.com/00labs/huma-contracts-v2) | 21aaad5302 | AGPL-3.0-or-later | `liquidity/TrancheVault.sol`, `FirstLossCover*.sol`, `RiskAdjustedTranchesPolicy.sol`, `EpochManager.sol` (epoch-based withdrawal queue), `credit/CreditDueManager.sol` (due dates, late fees) | InsuranceBasket tranches and withdrawal notice, repayment schedule |
| [NexusMutual/smart-contracts](https://github.com/NexusMutual/smart-contracts) | 9e885628e9 | GPL-3.0-only | `modules/staking/StakingPool.sol`, `StakingProducts.sol` (capacity allocation, per-product pricing, bucketed expiries), cover assessment flow | InsuranceBasket capacity and pricing |
| [morpho-org/morpho-blue](https://github.com/morpho-org/morpho-blue) | 8e26ca6a8d | GPL-2.0-or-later | Isolated-market design, share accounting, IRM interface, minimal immutable core | LenderVault accounting, market isolation |
| [morpho-org/vault-v2](https://github.com/morpho-org/vault-v2) and [metamorpho](https://github.com/morpho-org/metamorpho) | 1ae84f3552 / ded84e5966 | GPL-2.0-or-later | Allocator vault routing deposits across markets with caps, timelocked risk changes | LenderVault automated mode, exposure caps |
| [gnosis/ido-contracts](https://github.com/gnosis/ido-contracts) | e5ec2e696c | LGPL-3.0-or-later | `EasyAuction.sol` uniform-clearing batch auction and ordered order book | RateAuction (bid = rate, clearing rate for all fills) |
| [volt-protocol/ethereum-credit-guild](https://github.com/volt-protocol/ethereum-credit-guild) | b1fe220091 | MIT (license.md) plus GPL-3.0 / AGPL files | `loan/LendingTerm.sol`, `loan/AuctionHouse.sol` (default handling), `governance/LendingTermOnboarding/Offboarding.sol` (governed risk terms), `ProfitManager.sol` (loss socialization order) | Governance of risk parameters, LossWaterfall ideas |
| [ethereum-attestation-service/eas-contracts](https://github.com/ethereum-attestation-service/eas-contracts) | e6e970286f | MIT | EAS + SchemaRegistry, use deployed instances where they exist on the target chain | IdentityGate, ScoreOracle |
| [reclaimprotocol/reclaim-solidity-sdk](https://github.com/reclaimprotocol/reclaim-solidity-sdk) | 3326a4e4b7 | MIT per SPDX headers (no LICENSE file; confirm) | `Reclaim.sol` on-chain verification of zkTLS proofs | attestation issuer / IdentityGate |
| [kleros/kleros-v2](https://github.com/kleros/kleros-v2) | 320b23d526 | MIT | Arbitrable interface for small disputes | dispute hook in LoanRegistry (Phase 2+) |

External interfaces only (no code to fork): Chainalysis sanctions oracle, Chainlink price feeds.

## Reference only (read for ideas, copy nothing)

| Repo | License | Why it is still worth reading |
|---|---|---|
| aave-dao/aave-v3-origin | BUSL-1.1 | Reserve factor, isolation mode, risk parameters |
| compound-finance/comet | BUSL-1.1 | Single-asset market design, absorb/reserve mechanics |
| maple-labs/maple-core-v2 | BUSL-1.1 | Pool delegate cover, loan manager, impairment flow |
| term-finance/term-finance-contracts | CC-BY-NC-ND-4.0 / BUSL-1.1 | Sealed-bid fixed-rate auctions |
| centrifuge/protocol-v3 | BUSL-1.1 | Tranched RWA pools, ERC-7540 async vaults |
| wildcat-finance/v2-protocol | Commons Clause | Undercollateralized credit markets with borrower-set terms |
| euler-xyz/euler-vault-kit | LICENSE file is BUSL-1.1 though many files are GPL headers | Modular vaults, hooks; treat as reference until clarified |
| sherlock-protocol/sherlock-v2-core | no LICENSE file | Staker-backed coverage pools |

Not found as public repos: 3Jane (study its whitepaper instead), TrueFi (repos moved or private).
