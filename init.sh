#!/usr/bin/env bash
# One command from a fresh clone to a green test suite:
# installs toolchains and deps, builds contracts, runs every test suite.
# Upstream reference repos are separate: ./scripts/fetch-upstream.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

FOUNDRY_VERSION=1.7.1
SOLC_VERSION=0.8.35

step() { printf '\n==> %s\n' "$*"; }

step "git submodules (forge-std, openzeppelin-contracts)"
git submodule update --init contracts/lib/forge-std contracts/lib/openzeppelin-contracts

step "Foundry"
if ! command -v forge >/dev/null 2>&1; then
  if curl -fsSL --max-time 20 https://foundry.paradigm.xyz -o /tmp/foundryup.sh 2>/dev/null; then
    bash /tmp/foundryup.sh && "$HOME/.foundry/bin/foundryup" -i "v$FOUNDRY_VERSION"
    export PATH="$HOME/.foundry/bin:$PATH"
  else
    # Installer host unreachable (sandboxed network): Foundry also ships on npm.
    npm install -g "@foundry-rs/forge@$FOUNDRY_VERSION" "@foundry-rs/anvil@$FOUNDRY_VERSION" "@foundry-rs/cast@$FOUNDRY_VERSION"
  fi
fi
forge --version | head -1

step "solc $SOLC_VERSION"
if [ -x "$HOME/.svm/$SOLC_VERSION/solc-$SOLC_VERSION" ] || \
   curl -fsS --max-time 10 -o /dev/null https://binaries.soliditylang.org/linux-amd64/list.json 2>/dev/null; then
  echo "native solc (managed by forge)"
else
  # binaries.soliditylang.org unreachable: fall back to solc-js behind a solc CLI shim.
  (cd tools/solcjs && npm ci --silent)
  export FOUNDRY_SOLC="$ROOT/tools/solcjs/solc"
  # forge also reads contracts/.env (gitignored), so plain `forge` commands keep working in this checkout.
  touch contracts/.env
  grep -q '^FOUNDRY_SOLC=' contracts/.env || echo "FOUNDRY_SOLC=$FOUNDRY_SOLC" >> contracts/.env
  echo "solc-js fallback: $FOUNDRY_SOLC"
fi

step "contracts: build + test"
(cd contracts && forge build && forge test)

step "services/underwriter: install, typecheck, test"
(cd services/underwriter && npm ci --silent && npx tsc -p . --noEmit && npx vitest run)

step "sim: install, test"
(cd sim && { [ -d .venv ] || python3 -m venv .venv; } && .venv/bin/pip install -q -r requirements.txt && .venv/bin/pytest -q)

step "all green"
