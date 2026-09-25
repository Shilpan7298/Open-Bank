import { execFileSync, spawn, spawnSync, type ChildProcess } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createPublicClient, createWalletClient, encodeAbiParameters, http, type Address, type PublicClient } from "viem";
import { foundry } from "viem/chains";
import { mnemonicToAccount } from "viem/accounts";
import { abis, loadDeployment, publishScore, readVerifiedData, type Deployment } from "../src/chain.js";
import { toOnChainScore } from "../src/eip712.js";
import { MockScorer } from "../src/scorer.js";

const here = dirname(fileURLToPath(import.meta.url));
const contracts = resolve(here, "../../../contracts");
const PORT = 8547;
const RPC = `http://127.0.0.1:${PORT}`;
const MNEMONIC = "test test test test test test test test test test test junk"; // Anvil's public test mnemonic
const hasFoundry = spawnSync("anvil", ["--version"]).status === 0 && spawnSync("forge", ["--version"]).status === 0;

describe.skipIf(!hasFoundry)("UW-07: score, sign and attest on Anvil; ScoreOracle accepts it", () => {
  let anvil: ChildProcess;
  let d: Deployment;
  let client: PublicClient;
  const chain = { ...foundry, rpcUrls: { default: { http: [RPC] } } };
  const attester = mnemonicToAccount(MNEMONIC, { addressIndex: 1 });
  const scorer = mnemonicToAccount(MNEMONIC, { addressIndex: 2 });
  const borrower = mnemonicToAccount(MNEMONIC, { addressIndex: 3 });

  beforeAll(async () => {
    anvil = spawn("anvil", ["--port", String(PORT), "--silent"], { stdio: "ignore" });
    client = createPublicClient({ chain, transport: http(RPC) }) as PublicClient;
    for (let i = 0; i < 50; i++) {
      try {
        await client.getChainId();
        break;
      } catch {
        await new Promise((r) => setTimeout(r, 200));
      }
    }
    execFileSync("forge", ["script", "script/Deploy.s.sol", "--rpc-url", RPC, "--broadcast"], { cwd: contracts, stdio: "ignore" });
    d = loadDeployment(resolve(contracts, "deployments/local.json"));
  }, 240_000);

  afterAll(() => {
    anvil?.kill();
  });

  it("publishes a score that reaches consensus", async () => {
    const wallet = (account: typeof attester) => createWalletClient({ account, chain, transport: http(RPC) });
    const identitySchema = d.identitySchema as `0x${string}`;

    // Onboard: the KYC attester attests country 1 (tier A), the borrower links it.
    const att = await client.simulateContract({
      account: attester,
      address: d.eas,
      abi: abis.eas,
      functionName: "attest",
      args: [identitySchema, borrower.address, 0n, encodeAbiParameters([{ type: "uint256" }], [1n])],
    });
    await client.waitForTransactionReceipt({ hash: await wallet(attester).writeContract(att.request) });
    const reg = await client.simulateContract({
      account: borrower,
      address: d.identityGate,
      abi: abis.gate,
      functionName: "registerIdentity",
      args: [att.result],
    });
    await client.waitForTransactionReceipt({ hash: await wallet(borrower).writeContract(reg.request) });

    // Propose a loan.
    const prop = await client.simulateContract({
      account: borrower,
      address: d.loanRegistry,
      abi: abis.registry,
      functionName: "propose",
      args: [1_000_000_000n, 180n * 86400n, 6, 1500, 7, `0x${"00".repeat(32)}`],
    });
    await client.waitForTransactionReceipt({ hash: await wallet(borrower).writeContract(prop.request) });
    const loanId = prop.result;

    // Score from verified on-chain data, sign, attest, submit.
    const verified = await readVerifiedData(client, d, borrower.address as Address);
    expect(verified.tier).toBe("A");
    expect(verified.creditLimit).toBe(2_000_000_000n);
    const score = await new MockScorer().score(verified, { loanId, principal: 1_000_000_000n, termDays: 180, proposal: "van" });
    const block = await client.getBlock();
    const onChain = toOnChainScore(score, loanId, borrower.address as Address, block.timestamp + 30n * 86400n);
    await publishScore(client, wallet(scorer), scorer, d, onChain);

    const c = await client.readContract({ address: d.scoreOracle, abi: abis.oracle, functionName: "consensus", args: [loanId, borrower.address] });
    expect(c.ok).toBe(true);
    expect(c.riskBand).toBe(score.risk_band);
    expect(c.minVoucherCoverBps).toBe(onChain.minVoucherCoverBps);
  }, 120_000);
});
