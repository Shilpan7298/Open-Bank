#!/usr/bin/env bash
# Clone every repo in docs/UPSTREAM.md into upstream/<repo-name>/ at its pinned commit.
# upstream/ is gitignored, read-only reference material. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p upstream

# owner/repo  full-commit  class
REPOS=(
  "OpenZeppelin/openzeppelin-contracts 4858ab13a5ad897f59753028f6315f9d487c4322 incorporate"
  "unioncredit/union-v2-contracts 67bc59b7ee759783531a198246095f2ae1d980cd incorporate"
  "goldfinch-eng/mono bb251675d8a28d046f4d4763e1cf8874ee7c2723 incorporate"
  "00labs/huma-contracts-v2 21aaad53023eb3f448ff09820fee1a3936b6175d incorporate"
  "NexusMutual/smart-contracts 9e885628e9049025bd625cc4cf02d7a981d5c338 incorporate"
  "morpho-org/morpho-blue 8e26ca6a8dbc5089edcd67fb576248810fd2870a incorporate"
  "morpho-org/vault-v2 1ae84f3552c67011d92c463eecb8ebd15101f190 incorporate"
  "morpho-org/metamorpho ded84e59668155b34d3c24906c4f7461c12828af incorporate"
  "gnosis/ido-contracts e5ec2e696c2e1b68fe79a7ddc792b231d60fdf8c incorporate"
  "volt-protocol/ethereum-credit-guild b1fe220091c8a6394dbef9f62d061c7c4bf20762 incorporate"
  "ethereum-attestation-service/eas-contracts e6e970286ff18bbdfc5d8eff2742c5ece46040e4 incorporate"
  "reclaimprotocol/reclaim-solidity-sdk 3326a4e4b7d747b3f06d027a7c40ec8612bd0b5a incorporate"
  "kleros/kleros-v2 320b23d526c2a5d13cae782e1a53896da83d7010 incorporate"
  # Reference only: read for ideas, copy nothing. No pin in UPSTREAM.md; these are the HEADs cloned on 2026-09-25.
  "aave-dao/aave-v3-origin 8305565ae342f1773c42cd2e4593f175fe5968a0 reference"
  "compound-finance/comet f766f51583c23acc33b2a7824654ef2029a96804 reference"
  "maple-labs/maple-core-v2 f59f30c691fa0b831426d15832ee642f5ce38a42 reference"
  "term-finance/term-finance-contracts cd94ede7544db73f4114c520fb589939f60ea078 reference"
  "centrifuge/protocol-v3 48f7dff6ec83b2f7c044d35139084fb501da5f9a reference"
  "wildcat-finance/v2-protocol f5a26146987926f4811b72a795d662813dedfe85 reference"
  "euler-xyz/euler-vault-kit e88274cc624b9867d3c0197614dc5fe5201377c3 reference"
  "sherlock-protocol/sherlock-v2-core 6d0ad29b504db57304ab74f942fe194e646dddb8 reference"
)

for entry in "${REPOS[@]}"; do
  read -r full sha _ <<<"$entry"
  name=${full#*/}
  dir="upstream/$name"
  if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD)" = "$sha" ]; then
    continue
  fi
  rm -rf "$dir"
  # Partial clone: history without blobs, then check out only the pinned tree.
  git clone -q --filter=blob:none --no-checkout "https://github.com/$full.git" "$dir"
  git -C "$dir" -c advice.detachedHead=false checkout -q "$sha"
  echo "$full @ $sha"
done
