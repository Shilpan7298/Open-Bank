# Open Banking Protocol (OBP)

AI-assisted, community-backed credit protocol on Ethereum. Phase 1: local Anvil testnet MVP only.

- Design, parameters, conventions: [CLAUDE.md](CLAUDE.md)
- Upstream repos and licenses: [docs/UPSTREAM.md](docs/UPSTREAM.md), notes in [docs/upstream-notes/](docs/upstream-notes/)
- Status and next steps: [progress.md](progress.md); test plan: [tests.json](tests.json)

```
./init.sh                     # install, build, run every test suite
./scripts/fetch-upstream.sh   # clone upstream reference repos into upstream/ (gitignored)
```

Layout:
- `contracts/` Foundry project: `src/` modules, `test/{unit,invariant,e2e}`, `script/` (`DeployLib.sol`, `Deploy.s.sol` for Anvil)
- `services/underwriter/` TypeScript AI underwriter (mock mode: `UNDERWRITER_MOCK=1`)
- `sim/` Python stress simulation (Prompt 2)
- `tools/solcjs/` solc-js fallback used only when native solc cannot be downloaded
Licensed AGPL-3.0-or-later; see [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).
