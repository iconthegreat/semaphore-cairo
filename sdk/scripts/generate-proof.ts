/**
 * Generate a real Semaphore Groth16 proof and encode it as StarkNet calldata.
 *
 * This validates the complete off-chain pipeline:
 * 1. Create identity
 * 2. Create group + add member
 * 3. Generate Groth16 proof
 * 4. Verify proof locally
 * 5. Extract verification key
 * 6. Attempt StarkNet calldata encoding via Garaga
 *
 * Usage: npx tsx scripts/generate-proof.ts
 */
import { Identity } from "@semaphore-protocol/identity";
import { Group } from "@semaphore-protocol/group";
import { generateProof, verifyProof } from "@semaphore-protocol/proof";
import { extractVerificationKey } from "../src/proof.js";
import { encodeForStarknet } from "../src/calldata.js";
import type { SemaphoreFullProof } from "../src/types.js";
import { writeFileSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { keccak256, toBeHex } from "ethers";

const __dirname = dirname(fileURLToPath(import.meta.url));
const MESSAGE = 42n;
const SCOPE = 1n;

async function main() {
  console.log("=== Semaphore Groth16 Proof Generation ===\n");

  // 1. Create identity
  console.log("1. Creating identity...");
  const identity = new Identity();
  console.log(`   Commitment: ${identity.commitment}`);

  // 2. Create group and add member
  console.log("\n2. Creating group and adding member...");
  const group = new Group([identity.commitment]);
  console.log(`   Group size:  ${group.size}`);
  console.log(`   Group depth: ${group.depth}`);
  console.log(`   Group root:  ${group.root}`);

  // 3. Generate Groth16 proof
  console.log("\n3. Generating Groth16 proof (depth-20, downloads ~60MB artifacts on first run)...");
  const startTime = Date.now();
  // Always use depth-20 to match the on-chain verifier's baked-in VK.
  // generateProof pads missing Merkle siblings with zeros for shallow trees.
  const proof = await generateProof(identity, group, MESSAGE, SCOPE, 20);
  const elapsed = Date.now() - startTime;
  console.log(`   Proof generated in ${elapsed}ms`);
  console.log(`   Merkle root: ${proof.merkleTreeRoot}`);
  console.log(`   Nullifier:   ${proof.nullifier}`);
  console.log(`   Message:     ${proof.message}`);
  console.log(`   Scope:       ${proof.scope}`);
  console.log(`   Depth:       ${proof.merkleTreeDepth}`);
  console.log(`   Points:      [${proof.points.map(p => p.slice(0, 10) + "...").join(", ")}]`);

  // 4. Verify proof locally
  console.log("\n4. Verifying proof locally (snarkjs groth16.verify)...");
  const valid = await verifyProof(proof);
  console.log(`   Proof valid: ${valid}`);
  if (!valid) {
    throw new Error("Local proof verification failed!");
  }

  // 5. Extract VK for the proof's tree depth
  const depth = proof.merkleTreeDepth;
  console.log(`\n5. Extracting verification key for depth ${depth}...`);
  const vk = extractVerificationKey(depth);
  console.log(`   IC length: ${vk.IC.length}`);

  // Save proof artifacts
  const artifactDir = join(__dirname, "..", "artifacts");
  mkdirSync(artifactDir, { recursive: true });

  // Save snarkjs-format proof for Garaga CLI use
  const p = proof.points;
  const snarkjsProof = {
    pi_a: [p[0], p[1], "1"],
    pi_b: [[p[3], p[2]], [p[5], p[4]], ["1", "0"]],
    pi_c: [p[6], p[7], "1"],
    protocol: "groth16",
    curve: "bn128",
  };
  // Public signals use hashed message/scope (keccak256 >> 8n), matching what the circuit expects
  const hashForCircuit = (v: bigint | string) =>
    (BigInt(keccak256(toBeHex(v, 32))) >> 8n).toString();
  const publicSignals = [
    proof.merkleTreeRoot,
    proof.nullifier,
    hashForCircuit(proof.message),
    hashForCircuit(proof.scope),
  ];
  console.log(`   Hashed message: ${publicSignals[2]}`);
  console.log(`   Hashed scope:   ${publicSignals[3]}`);

  writeFileSync(join(artifactDir, "proof.json"), JSON.stringify(snarkjsProof, null, 2));
  writeFileSync(join(artifactDir, "public.json"), JSON.stringify(publicSignals, null, 2));
  writeFileSync(join(artifactDir, `semaphore-${depth}-vk.json`), JSON.stringify(vk, null, 2));
  console.log(`   Saved proof.json, public.json, and semaphore-${depth}-vk.json to artifacts/`);

  // 6. Attempt calldata encoding
  console.log("\n6. Encoding as StarkNet calldata via Garaga...");
  const calldata = await encodeForStarknet(proof as unknown as SemaphoreFullProof, vk);

  if (calldata[0] === "ENCODING_PENDING") {
    console.log("   [FALLBACK] Garaga WASM/Python unavailable — proof saved for manual encoding.");
    console.log("   After installing garaga Python (Phase 4), run:");
    console.log(`   garaga calldata --system groth16 --vk artifacts/semaphore-${depth}-vk.json --proof artifacts/proof.json --public-inputs artifacts/public.json --curve-id bn254`);
  } else {
    console.log(`   Calldata length: ${calldata.length} felt252 values`);
    writeFileSync(join(artifactDir, "calldata.json"), JSON.stringify(calldata, null, 2));
    console.log(`   Saved calldata.json to artifacts/`);
  }

  // Summary
  console.log("\n=== Pipeline Summary ===");
  console.log(`   Identity commitment: ${identity.commitment}`);
  console.log(`   Merkle root (u256):  ${proof.merkleTreeRoot}`);
  console.log(`   Nullifier (u256):    ${proof.nullifier}`);
  console.log(`   Proof depth:         ${depth}`);
  console.log(`   Local verification:  PASSED`);
  console.log(`   Calldata encoding:   ${calldata[0] === "ENCODING_PENDING" ? "PENDING (needs garaga Python)" : "COMPLETE"}`);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
