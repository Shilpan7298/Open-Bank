# Open Banking Protocol (OBP)

AI-assisted, community-backed credit protocol on Ethereum. Phase 1: local Anvil testnet MVP only.

- Design, parameters, conventions: [CLAUDE.md](CLAUDE.md)
- Upstream repos and licenses: [docs/UPSTREAM.md](docs/UPSTREAM.md), notes in [docs/upstream-notes/](docs/upstream-notes/)
- Status and next steps: [progress.md](progress.md); test plan: [tests.json](tests.json)

```
./init.sh                     # install, build, run every test suite
./scripts/fetch-upstream.sh   # clone upstream reference repos into upstream/ (gitignored)
```

Layout: `contracts/` (Foundry), `services/underwriter/` (TypeScript), `sim/` (Python).
Licensed AGPL-3.0-or-later; see [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).
