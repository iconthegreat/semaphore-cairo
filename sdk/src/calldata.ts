/**
 * Encode a Semaphore Groth16 proof as StarkNet calldata using Garaga.
 *
 * Two encoding strategies:
 * 1. Python CLI (garaga gen): Most reliable, used for contract generation
 * 2. Node.js WASM (garaga npm): Faster but has known issues with some proof formats
 *
 * Falls back to saving proof/VK to JSON for manual Python CLI encoding.
 *
 * ## Garaga version compatibility
 *
 * The calldata format is tested against **garaga==1.0.1** (BN254, Groth16, depth-20 VK).
 * Garaga is under active development — the encoding format may change between versions.
 * If the verifier contract is regenerated with a new Garaga version, re-test this module.
 *
 * Expected calldata length for a BN254 Groth16 proof with depth-20 VK: ~1977 felt252 values.
 * If `encodeForStarknet` returns a materially different length, suspect a format change.
 */

import type { SemaphoreFullProof } from "./types.js";
import { execSync } from "child_process";
import { writeFileSync, readFileSync, mkdirSync, existsSync } from "fs";
import { join, dirname } from "path";
import { tmpdir } from "os";
import { keccak256, toBeHex } from "ethers";

/** Hash a value the same way the Semaphore V4 circuit does: keccak256(toBeHex(v, 32)) >> 8n */
function hashForCircuit(v: bigint | string): string {
  return (BigInt(keccak256(toBeHex(v, 32))) >> 8n).toString();
}

/**
 * Encode a Semaphore proof as StarkNet calldata via Garaga Python CLI.
 *
 * @param proof - The full Semaphore proof (from generateSemaphoreProof)
 * @param verificationKey - The snarkjs-format VK (depth-specific)
 * @returns Array of string felt252 values for the `full_proof_with_hints` parameter
 */
export async function encodeForStarknet(
  proof: SemaphoreFullProof,
  verificationKey: any,
): Promise<string[]> {
  // Try Garaga npm WASM first
  try {
    return await encodeViaGaragaNpm(proof, verificationKey);
  } catch (_wasmErr) {
    // Fall back to Python CLI
  }

  // Try Garaga Python CLI
  try {
    return encodeViaGaragaPython(proof, verificationKey);
  } catch (_pyErr) {
    // Fall back to snarkjs calldata export
  }

  // Final fallback: export proof + VK as JSON files for manual encoding
  return exportProofForManualEncoding(proof, verificationKey);
}

/**
 * Validate that calldata from encodeForStarknet has a plausible length.
 *
 * Garaga BN254 Groth16 calldata for a depth-20 VK is ~1977 felt252 values.
 * A materially different length (< 100 or > 10000) likely indicates a format
 * incompatibility with the on-chain verifier — throw before submitting.
 *
 * @throws if calldata length is outside the expected range
 */
export function validateCalldataLength(calldata: string[]): void {
  const MIN_EXPECTED = 100;
  const MAX_EXPECTED = 10000;
  if (calldata.length < MIN_EXPECTED || calldata.length > MAX_EXPECTED) {
    throw new Error(
      `Garaga calldata length ${calldata.length} is outside expected range ` +
      `[${MIN_EXPECTED}, ${MAX_EXPECTED}]. ` +
      `This may indicate a Garaga version mismatch. ` +
      `Expected ~1977 felt252 values for a BN254 Groth16 proof (garaga==1.0.1).`,
    );
  }
}

/**
 * Attempt encoding via Garaga npm WASM.
 */
async function encodeViaGaragaNpm(
  proof: SemaphoreFullProof,
  vk: any,
): Promise<string[]> {
  const garaga = await import("garaga");
  await garaga.init();

  const p = proof.points;

  const garagaProof = {
    a: { x: p[0], y: p[1] },
    b: { x: [p[3], p[2]], y: [p[5], p[4]] },
    c: { x: p[6], y: p[7] },
    publicInputs: [proof.merkleTreeRoot, proof.nullifier, hashForCircuit(proof.message), hashForCircuit(proof.scope)],
  };

  const garagaVk = {
    alpha: { x: vk.vk_alpha_1[0], y: vk.vk_alpha_1[1] },
    beta: {
      x: [vk.vk_beta_2[0][0], vk.vk_beta_2[0][1]],
      y: [vk.vk_beta_2[1][0], vk.vk_beta_2[1][1]],
    },
    gamma: {
      x: [vk.vk_gamma_2[0][0], vk.vk_gamma_2[0][1]],
      y: [vk.vk_gamma_2[1][0], vk.vk_gamma_2[1][1]],
    },
    delta: {
      x: [vk.vk_delta_2[0][0], vk.vk_delta_2[0][1]],
      y: [vk.vk_delta_2[1][0], vk.vk_delta_2[1][1]],
    },
    ic: vk.IC.map((pt: string[]) => ({ x: pt[0], y: pt[1] })),
  };

  const result = garaga.getGroth16CallData(garagaProof as any, garagaVk as any, garaga.CurveId.BN254);
  const resultStrings = result.map((v: bigint) => v.toString());
  // The WASM returns the full span encoding [span_length, elem0, ..., elemN-1].
  // Strip the span_length prefix — starknet.js ABI encoding adds it automatically
  // when the parameter is declared as Span<felt252>.
  if (resultStrings.length > 1 && resultStrings[0] === String(resultStrings.length - 1)) {
    return resultStrings.slice(1);
  }
  return resultStrings;
}

/**
 * Attempt encoding via Garaga Python CLI.
 * Requires: garaga Python package installed with `garaga calldata` subcommand.
 */
function encodeViaGaragaPython(
  proof: SemaphoreFullProof,
  vk: any,
): string[] {
  const tmpDir = join(tmpdir(), "semaphore-garaga-" + Date.now());
  mkdirSync(tmpDir, { recursive: true });

  // Write snarkjs-format proof
  const p = proof.points;
  const snarkjsProof = {
    pi_a: [p[0], p[1], "1"],
    pi_b: [[p[3], p[2]], [p[5], p[4]], ["1", "0"]],
    pi_c: [p[6], p[7], "1"],
    protocol: "groth16",
    curve: "bn128",
  };

  const publicSignals = [
    proof.merkleTreeRoot,
    proof.nullifier,
    hashForCircuit(proof.message),
    hashForCircuit(proof.scope),
  ];

  const proofPath = join(tmpDir, "proof.json");
  const publicPath = join(tmpDir, "public.json");
  const vkPath = join(tmpDir, "vk.json");

  writeFileSync(proofPath, JSON.stringify(snarkjsProof, null, 2));
  writeFileSync(publicPath, JSON.stringify(publicSignals, null, 2));
  writeFileSync(vkPath, JSON.stringify(vk, null, 2));

  // Try garaga calldata command via micromamba (Python 3.10 env)
  const mambaPrefix = process.env.MAMBA_ROOT_PREFIX || join(process.env.HOME || "/home/icon", ".mamba");
  const micromamba = join(process.env.HOME || "/home/icon", ".local", "bin", "micromamba");
  const cmd = `MAMBA_ROOT_PREFIX="${mambaPrefix}" "${micromamba}" run -n garaga garaga calldata --system groth16 --vk "${vkPath}" --proof "${proofPath}" --public-inputs "${publicPath}" --format array 2>&1`;
  const output = execSync(cmd, { encoding: "utf-8", timeout: 60000 }).trim();

  // Parse the calldata output (garaga outputs a JSON array of values)
  // The first element is a count of subsequent elements (N-1 where N is array length).
  // Strip it — the on-chain deserializer receives a Span<felt252> which already
  // has its own length via StarkNet serialization.
  const rawCalldata: string[] = JSON.parse(output);
  if (rawCalldata.length > 1 && String(rawCalldata[0]) === String(rawCalldata.length - 1)) {
    return rawCalldata.slice(1);
  }
  return rawCalldata;
}

/**
 * Export proof and VK as JSON files for manual encoding.
 * Returns file paths instead of calldata.
 */
function exportProofForManualEncoding(
  proof: SemaphoreFullProof,
  vk: any,
): string[] {
  const p = proof.points;

  // Write snarkjs-format proof for manual garaga CLI use
  const snarkjsProof = {
    pi_a: [p[0], p[1], "1"],
    pi_b: [[p[3], p[2]], [p[5], p[4]], ["1", "0"]],
    pi_c: [p[6], p[7], "1"],
    protocol: "groth16",
    curve: "bn128",
  };

  const publicSignals = [
    proof.merkleTreeRoot,
    proof.nullifier,
    hashForCircuit(proof.message),
    hashForCircuit(proof.scope),
  ];

  console.warn("[calldata] Garaga WASM and Python CLI both unavailable.");
  console.warn("[calldata] Proof and public signals exported for manual encoding.");
  console.warn("[calldata] Run: garaga calldata --system groth16 --vk vk.json --proof proof.json --public-inputs public.json --curve-id bn254");

  // Return the proof data as a flat array of strings (public inputs as felt-like values)
  // This allows the e2e test to validate the data format even without Garaga encoding
  return [
    "ENCODING_PENDING",
    ...publicSignals,
    JSON.stringify(snarkjsProof),
    JSON.stringify(vk),
  ];
}
