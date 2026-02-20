import { execSync } from "child_process";
import { writeFileSync, mkdirSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { keccak256, toBeHex } from "ethers";
import { readFileSync } from "fs";
import { dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));

function hashForCircuit(v: bigint | string): string {
  return (BigInt(keccak256(toBeHex(v, 32))) >> 8n).toString();
}

function extractVk(depth = 20): any {
  const vkPath = join(
    __dirname,
    "..",
    "..",
    "node_modules",
    "@semaphore-protocol",
    "proof",
    "src",
    "verification-keys.json"
  );
  const allVks = JSON.parse(readFileSync(vkPath, "utf-8"));
  const idx = depth - 1;
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

export async function encodeCalldata(proof: any): Promise<string[]> {
  // Strategy 1: Garaga WASM (npm)
  try {
    const garaga = await import("garaga");
    await garaga.init();
    const vk = extractVk(20);
    const p = proof.points;
    const garagaProof = {
      a: { x: p[0], y: p[1] },
      b: { x: [p[3], p[2]], y: [p[5], p[4]] },
      c: { x: p[6], y: p[7] },
      publicInputs: [
        proof.merkleTreeRoot,
        proof.nullifier,
        hashForCircuit(proof.message),
        hashForCircuit(proof.scope),
      ],
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
    const result = garaga.getGroth16CallData(
      garagaProof as any,
      garagaVk as any,
      garaga.CurveId.BN254
    );
    const strs = result.map((v: bigint) => v.toString());
    if (strs.length > 1 && strs[0] === String(strs.length - 1)) return strs.slice(1);
    return strs;
  } catch (_e) {
    console.warn("[calldata] WASM failed, trying Python CLI...");
  }

  // Strategy 2: Garaga Python CLI (local dev only, not available on Vercel)
  try {
    const tmpDir = join(tmpdir(), "semaphore-garaga-" + Date.now());
    mkdirSync(tmpDir, { recursive: true });
    const vk = extractVk(20);
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
    writeFileSync(join(tmpDir, "proof.json"), JSON.stringify(snarkjsProof, null, 2));
    writeFileSync(join(tmpDir, "public.json"), JSON.stringify(publicSignals, null, 2));
    writeFileSync(join(tmpDir, "vk.json"), JSON.stringify(vk, null, 2));
    const home = process.env.HOME || "/home/icon";
    const cmd =
      `MAMBA_ROOT_PREFIX="${join(home, ".mamba")}" ` +
      `"${join(home, ".local", "bin", "micromamba")}" run -n garaga ` +
      `garaga calldata --system groth16 ` +
      `--vk "${join(tmpDir, "vk.json")}" ` +
      `--proof "${join(tmpDir, "proof.json")}" ` +
      `--public-inputs "${join(tmpDir, "public.json")}" ` +
      `--format array 2>&1`;
    const output = execSync(cmd, { encoding: "utf-8", timeout: 120_000 }).trim();
    const raw: string[] = JSON.parse(output);
    if (raw.length > 1 && String(raw[0]) === String(raw.length - 1)) return raw.slice(1);
    return raw;
  } catch (_e) {
    throw new Error("Garaga encoding failed (WASM and Python CLI both unavailable)");
  }
}
