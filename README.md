# Open Banking Protocol (OBP)

**English** · [العربية](README.ar.md) · [বাংলা](README.bn.md) · [Español](README.es.md)

**Community-backed loans for people banks leave out.**

Billions of people have steady work and honest plans but no access to credit. Often they live in countries where inflation eats savings, banks lend only to the well connected, and there is no credit bureau to prove a good record. Egypt, Bangladesh and Argentina are examples. OBP is an open protocol that lets them borrow from anyone in the world, backed by people who know and trust them, with rules written in public code instead of hidden bank policy.

> **Status: Phase 1, testnet only.** Everything runs on a local test chain. There are no real funds, and there will be none until the contracts are audited and a legal structure is in place.

## How a loan works

1. **Verify once.** A borrower proves who they are and what they earn. The proofs stay private and only a yes-or-no attestation goes on-chain.
2. **Ask.** The borrower proposes an amount, a term and a purpose, in their own language.
3. **Get advice.** An AI underwriter reads the verified data, writes a risk score for lenders, and explains the score to the borrower in their language. The score is advice only: it can never fund a loan by itself.
4. **Get backed.** The borrower locks some collateral. Friends, family or community members ("vouchers") lock small stakes too, and earn a fee when the loan is repaid.
5. **Get funded.** Lenders anywhere compete in an auction to offer the lowest interest rate.
6. **Repay and grow.** Each repaid loan raises the borrower's credit limit and lowers the backing they need next time.

If a loan is not repaid, losses fall in a fixed order: the borrower's collateral, then the vouchers' stakes, then an insurance pool, then a protocol reserve, and lenders only last. This order makes default costly for the borrower and survivable for everyone else. The full design is in [CLAUDE.md](CLAUDE.md).

## Get involved

We want OBP to be built by the people it serves, together with engineers, economists, lawyers and translators everywhere. You do not need to be a Solidity expert to help.

- **Translate.** Add your language, or check a machine draft in [`i18n/`](i18n/README.md). Native speakers of Arabic, Bengali and Spanish are especially needed now.
- **Code.** Pick a task from [good first issues](docs/good-first-issues.md) or the [roadmap](docs/ROADMAP.md). Contracts use Solidity and Foundry, the underwriter uses TypeScript, and the simulation uses Python.
- **Test the economics.** Help model currency crashes, country shocks and bad years in [`sim/`](sim/).
- **Know your country.** Tell us how credit, stablecoins and courts actually work where you live. This shapes jurisdiction tiers and legal design.
- **Review for security.** Adversarial review of the contracts is always welcome. See [SECURITY.md](SECURITY.md).

Start with [CONTRIBUTING.md](CONTRIBUTING.md). Everyone is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Quick start

```
git clone https://github.com/Shilpan7298/Open-Bank.git && cd Open-Bank
./init.sh                     # installs tools, builds, runs every test suite
./scripts/fetch-upstream.sh   # optional: upstream reference repos, into upstream/
```

You need git, Node 20+ and Python 3.11+. `init.sh` installs Foundry if it is missing.

Repo layout:

- `contracts/`: the Foundry project, with modules in `src/`, tests in `test/{unit,invariant,e2e}`, and an Anvil deploy script in `script/`
- `services/underwriter/`: the AI underwriter in TypeScript. `UNDERWRITER_MOCK=1` runs it without an API key.
- `sim/`: the Python stress simulation
- `i18n/`: translations of everything users see
- `docs/`: upstream study notes, roadmap and starter tasks
- [progress.md](progress.md): current status, decisions and next steps. [tests.json](tests.json): the test plan.

## License

Licensed under AGPL-3.0-or-later; see [LICENSE](LICENSE). Third-party code is listed in [NOTICE.md](NOTICE.md).
