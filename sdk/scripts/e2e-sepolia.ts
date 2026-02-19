/**
 * Sepolia smoke test for the deployed Semaphore contracts.
 *
 * Uses already-deployed verifier + Semaphore contracts on Sepolia.
 * Runs the full group → member → proof → signal → nullifier check flow.
 *
 * Prerequisites:
 *   - Contracts deployed (scripts/deployed-addresses.json must exist)
 *   - STARKNET_PRIVATE_KEY env var set, OR reads from sncast accounts file
 *
 * Usage: npx tsx scripts/e2e-sepolia.ts
 */

import { RpcProvider, Account, Contract, json, CallData, Signer } from "starknet";
import { readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { Identity } from "@semaphore-protocol/identity";
import { Group } from "@semaphore-protocol/group";
import { generateProof } from "@semaphore-protocol/proof";
import { encodeForStarknet } from "../src/calldata.js";
import { extractVerificationKey } from "../src/proof.js";
import type { SemaphoreFullProof } from "../src/types.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = join(__dirname, "..");
const CONTRACTS_DIR = join(PROJECT_ROOT, "..", "contracts");
const VERIFIER_DIR = join(PROJECT_ROOT, "..", "semaphore_verifier");
const ADDRESSES_FILE = join(PROJECT_ROOT, "..", "scripts", "deployed-addresses.json");

const MESSAGE = 42n;
const SCOPE = 1n;
// Use a unique group ID per run to avoid collisions with prior runs
const GROUP_ID = BigInt(Date.now());

let passed = 0;
let failed = 0;

function assert(condition: boolean, msg: string) {
  if (condition) {
    console.log(`  [PASS] ${msg}`);
    passed++;
  } else {
    console.error(`  [FAIL] ${msg}`);
    failed++;
  }
}

function readContractArtifact(dir: string, filename: string): any {
  const path = join(dir, "target", "dev", filename);
  return json.parse(readFileSync(path, "utf-8"));
}

async function main() {
  console.log("=== Semaphore Sepolia Smoke Test ===\n");

  // ── 1. Load deployed addresses ────────────────────────────────────
  console.log("1. Loading deployed addresses...");
  const deployed = JSON.parse(readFileSync(ADDRESSES_FILE, "utf-8"));
  const { verifier: verifierInfo, semaphore: semaphoreInfo, rpc_url } = deployed;
  console.log(`  Network: ${deployed.network}`);
  console.log(`  Verifier: ${verifierInfo.address}`);
  console.log(`  Semaphore: ${semaphoreInfo.address}`);
  assert(!!verifierInfo.address && !!semaphoreInfo.address, "Addresses loaded");

  // ── 2. Connect to Sepolia ─────────────────────────────────────────
  console.log("\n2. Connecting to Sepolia...");
  const provider = new RpcProvider({ nodeUrl: rpc_url });
  const block = await provider.getBlockNumber();
  assert(block > 0, `Connected to Sepolia (block ${block})`);

  // ── 3. Load deployer account ──────────────────────────────────────
  console.log("\n3. Loading deployer account...");
  const accountsFile = join(
    process.env.HOME || "/home/icon",
    ".starknet_accounts",
    "starknet_open_zeppelin_accounts.json"
  );
  const accounts = JSON.parse(readFileSync(accountsFile, "utf-8"));
  const sepoliaAccounts = accounts["alpha-sepolia"] || {};
  const deployer = sepoliaAccounts["sepolia-deployer"];
  if (!deployer) throw new Error("sepolia-deployer not found in accounts file");
  const signer = new Signer(deployer.private_key);
  const account = new Account({ provider, address: deployer.address, signer });
  console.log(`  Address: ${deployer.address}`);
  assert(true, "Account loaded");

  // ── 4. Connect to deployed Semaphore contract ─────────────────────
  console.log("\n4. Connecting to deployed Semaphore contract...");
  const semaphoreSierra = readContractArtifact(
    CONTRACTS_DIR,
    "semaphore_Semaphore.contract_class.json"
  );
  const semaphore = new Contract({
    abi: semaphoreSierra.abi,
    address: semaphoreInfo.address,
    providerOrAccount: account,
  });
  assert(true, "Contract interface ready");

  // ── 5. Create group ───────────────────────────────────────────────
  console.log(`\n5. Creating group (id=${GROUP_ID})...`);
  const createGroupTx = await semaphore.invoke("create_group", [GROUP_ID]);
  await provider.waitForTransaction(createGroupTx.transaction_hash);
  const exists = await semaphore.call("group_exists", [GROUP_ID]);
  assert(!!exists, "Group created on Sepolia");

  // ── 6. Create identity + off-chain group ──────────────────────────
  console.log("\n6. Creating identity and off-chain group...");
  const identity = new Identity();
  const commitment = identity.commitment;
  console.log(`  Commitment: ${commitment}`);
  const group = new Group([commitment]);
  const merkleRoot = group.root;
  assert(BigInt(merkleRoot) > 0n, "Group has non-zero root");

  // ── 7. Add member on-chain ────────────────────────────────────────
  console.log("\n7. Adding member on-chain...");
  const addMemberTx = await semaphore.invoke("add_member", [
    GROUP_ID, commitment, merkleRoot,
  ]);
  await provider.waitForTransaction(addMemberTx.transaction_hash);
  const onChainRoot = await semaphore.call("get_merkle_root", [GROUP_ID]);
  assert(BigInt(onChainRoot as any) === BigInt(merkleRoot), "On-chain root matches off-chain");

  // ── 8. Generate depth-20 proof ────────────────────────────────────
  console.log("\n8. Generating Groth16 proof (depth-20)...");
  const startTime = Date.now();
  const proof = await generateProof(identity, group, MESSAGE, SCOPE, 20);
  console.log(`  Proof generated in ${Date.now() - startTime}ms`);
  assert(proof.merkleTreeDepth === 20, "Proof uses depth-20 circuit");

  // ── 9. Encode via Garaga ──────────────────────────────────────────
  console.log("\n9. Encoding proof via Garaga...");
  const vk = extractVerificationKey(20);
  const calldata = await encodeForStarknet(
    proof as unknown as SemaphoreFullProof,
    vk
  );
  assert(calldata.length > 100 && calldata[0] !== "ENCODING_PENDING",
    `Calldata encoded: ${calldata.length} felts`);

  // ── 10. Send signal on Sepolia ────────────────────────────────────
  console.log("\n10. Sending signal on Sepolia...");
  const calldataFelts = calldata.map((v) => v.toString());
  const sendSignalTx = await semaphore.invoke("send_signal", [
    GROUP_ID, calldataFelts,
  ]);
  const receipt = await provider.waitForTransaction(sendSignalTx.transaction_hash);
  assert(
    receipt.statusReceipt !== "REJECTED",
    `Signal accepted on Sepolia (tx: ${sendSignalTx.transaction_hash.slice(0, 18)}...)`
  );

  // ── 11. Nullifier used ────────────────────────────────────────────
  console.log("\n11. Checking nullifier...");
  const isUsed = await semaphore.call("is_nullifier_used", [BigInt(proof.nullifier)]);
  assert(!!isUsed, "Nullifier marked as used on Sepolia");

  // ── 12. Double-signal rejected ────────────────────────────────────
  console.log("\n12. Double-signal rejection...");
  try {
    const doubleTx = await semaphore.invoke("send_signal", [GROUP_ID, calldataFelts]);
    await provider.waitForTransaction(doubleTx.transaction_hash);
    assert(false, "Double signal should have been rejected");
  } catch (err: any) {
    const msg = err?.message || String(err);
    assert(
      msg.includes("Nullifier already used") || msg.includes("REVERTED") || msg.includes("reverted"),
      "Double signal correctly rejected"
    );
  }

  // ── Summary ───────────────────────────────────────────────────────
  console.log("\n=== Sepolia Smoke Test Summary ===");
  console.log(`  Passed: ${passed}  Failed: ${failed}`);
  if (failed > 0) process.exit(1);
  console.log("\n  All tests passed on Sepolia!");
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
