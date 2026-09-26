// SPDX-License-Identifier: AGPL-3.0-or-later
// Score one loan and publish the score on-chain.
//   npm run score -- <loanId> <borrowerAddress> <proposalFile>
// Env: RPC_URL (default http://127.0.0.1:8545), DEPLOYMENT (default ../../contracts/deployments/local.json),
//      SCORER_PK (required; keep it in a gitignored .env), UNDERWRITER_MOCK=1 for the deterministic mock scorer,
//      otherwise the Anthropic SDK reads its credentials from the environment.
//      BORROWER_LANGUAGE (default en) sets the language of the borrower_summary, e.g. ar, bn, es.
import { readFileSync } from "node:fs";
import { createPublicClient, createWalletClient, http, type Address, type Hex, type PublicClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { loadDeployment, publishScore, readVerifiedData } from "./chain.js";
import { canonicalScoreJson, toOnChainScore } from "./eip712.js";
import { ClaudeScorer, MockScorer, type Scorer } from "./scorer.js";

async function main() {
  const [loanIdArg, borrowerArg, proposalFile] = process.argv.slice(2);
  if (!loanIdArg || !borrowerArg || !proposalFile) throw new Error("usage: score <loanId> <borrower> <proposalFile>");
  const pk = process.env.SCORER_PK as Hex | undefined;
  if (!pk) throw new Error("SCORER_PK is not set");
  const rpc = process.env.RPC_URL ?? "http://127.0.0.1:8545";
  const d = loadDeployment(process.env.DEPLOYMENT ?? new URL("../../../contracts/deployments/local.json", import.meta.url).pathname);
  const client = createPublicClient({ transport: http(rpc) }) as PublicClient;
  const account = privateKeyToAccount(pk);
  const wallet = createWalletClient({ account, transport: http(rpc), chain: { id: d.chainId } as never });

  const loanId = BigInt(loanIdArg);
  const borrower = borrowerArg as Address;
  const verified = await readVerifiedData(client, d, borrower);
  const scorer: Scorer = process.env.UNDERWRITER_MOCK === "1" ? new MockScorer() : new ClaudeScorer();
  const score = await scorer.score(verified, { loanId, principal: 0n, termDays: 0, proposal: readFileSync(proposalFile, "utf8"), language: process.env.BORROWER_LANGUAGE ?? "en" });
  const block = await client.getBlock();
  const onChain = toOnChainScore(score, loanId, borrower, block.timestamp + 30n * 86400n);
  const { uid } = await publishScore(client, wallet, account, d, onChain);
  // The rationale is published off-chain; its hash is in the attestation.
  console.log(JSON.stringify({ uid, rationaleHash: onChain.rationaleHash, score: JSON.parse(canonicalScoreJson(score)) }, null, 2));
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
