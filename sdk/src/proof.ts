import { generateProof, verifyProof } from "@semaphore-protocol/proof";
import type { Identity } from "@semaphore-protocol/identity";
import type { Group } from "@semaphore-protocol/group";
import type { SemaphoreFullProof } from "./types.js";
import { readFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

/**
 * Generate a Semaphore Groth16 proof.
 *
 * This handles:
 * 1. Computing witness from identity + group + message + scope
 * 2. Downloading circuit artifacts (WASM + zkey) for the tree depth
 * 3. Generating the Groth16 proof on BN254
 *
 * @param identity - The Semaphore V4 identity
 * @param group - The off-chain group (BN254-Poseidon Merkle tree)
 * @param message - The signal/message to broadcast (will be hashed by the library)
 * @param scope - The scope/external nullifier (will be hashed by the library)
 * @returns The full proof with public inputs
 */
export async function generateSemaphoreProof(
  identity: Identity,
  group: Group,
  message: bigint | number | string,
  scope: bigint | number | string,
): Promise<SemaphoreFullProof> {
  const proof = await generateProof(identity, group, message, scope);
  return proof as unknown as SemaphoreFullProof;
}

/**
 * Verify a Semaphore Groth16 proof off-chain.
 *
 * @param proof - The full proof object returned by generateSemaphoreProof
 * @returns true if the proof is valid
 */
export async function verifySemaphoreProof(
  proof: SemaphoreFullProof,
): Promise<boolean> {
  return await verifyProof(proof as any);
}

/**
 * Extract the depth-specific verification key from @semaphore-protocol/proof.
 *
 * The VK JSON has shared fields (vk_alpha_1, vk_beta_2, vk_gamma_2) and
 * depth-indexed arrays (vk_delta_2[depth-1], IC[depth-1]).
 *
 * Returns a complete snarkjs-format VK ready for use with Garaga.
 */
export function extractVerificationKey(depth: number = 20): any {
  // Find the VK file by walking up from this file to find node_modules
  const thisDir = dirname(fileURLToPath(import.meta.url));
  // Works from both src/ and dist/
  const vkPath = join(thisDir, "..", "node_modules", "@semaphore-protocol", "proof", "src", "verification-keys.json");
  const allVks = JSON.parse(readFileSync(vkPath, "utf-8"));

  const idx = depth - 1;
  if (idx < 0 || idx >= allVks.vk_delta_2.length) {
    throw new Error(`No verification key found for depth ${depth}`);
  }

  return {
    protocol: allVks.protocol,
    curve: allVks.curve,
    nPublic: allVks.nPublic,
    vk_alpha_1: allVks.vk_alpha_1,
    vk_beta_2: allVks.vk_beta_2,
    vk_gamma_2: allVks.vk_gamma_2,
    vk_delta_2: allVks.vk_delta_2[idx],
    IC: allVks.IC[idx],
  };
}
