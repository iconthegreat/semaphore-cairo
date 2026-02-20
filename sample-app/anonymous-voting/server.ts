/**
 * Anonymous Voting Demo — Backend Server
 *
 * Handles:
 *  - Serving static files (index.html, bundle.js, style.css)
 *  - Group state management (persisted to state.json)
 *  - StarkNet interactions (create_group, add_member, send_signal)
 *  - Garaga calldata encoding
 *
 * Run: npx tsx server.ts
 */

import express from "express";
import cors from "cors";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import {
  readFileSync,
  writeFileSync,
  existsSync,
  mkdirSync,
} from "fs";
import { tmpdir } from "os";
import { execSync } from "child_process";
import { RpcProvider, Account, Contract, Signer, json } from "starknet";
import { Group } from "@semaphore-protocol/group";
import { keccak256, toBeHex } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const PUBLIC_DIR = join(__dirname, "public");
if (!existsSync(PUBLIC_DIR)) {
  mkdirSync(PUBLIC_DIR, { recursive: true });
}

// ── Config ────────────────────────────────────────────────────────────────────

const PORT = 3000;
const RPC_URL = "https://api.cartridge.gg/x/starknet/sepolia";
const SEMAPHORE_ADDRESS =
  "0x0002e2b414c453ee2c862d8f9d06fac9817dfff8afe2bde8ba60ddb75585a37b";
const DEPLOYER_ADDRESS =
  "0x5c82627c80815b4760d9e227103a639574905768c8913db7717b6609e367204";
const DEPLOYER_PRIVATE_KEY =
  process.env.DEPLOYER_PRIVATE_KEY ||
  "0x6cf50c95db36ebf25bd2e0e04be6499fea84e3b71ac058706ceded32accafb6";

const GROUP_ID = 42n;
const SCOPE = 1n; // Fixed scope for this vote — each identity can vote once
const VOTE_QUESTION = "Should Semaphore deploy to StarkNet mainnet?";

// ── State ─────────────────────────────────────────────────────────────────────

interface Vote {
  nullifier: string;
  choice: "yes" | "no";
  txHash: string;
  timestamp: number;
}

interface AppState {
  groupCreated: boolean;
  commitments: string[]; // decimal bigint strings
  votes: Vote[];
}

const STATE_FILE = join(__dirname, "state.json");
let _state: AppState | null = null;
let _stateLock = false;

function loadState(): AppState {
  if (_state) return _state;
  if (existsSync(STATE_FILE)) {
    _state = JSON.parse(readFileSync(STATE_FILE, "utf-8"));
    return _state!;
  }
  _state = { groupCreated: false, commitments: [], votes: [] };
  return _state;
}

function saveState(state: AppState) {
  _state = state;
  writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

// ── StarkNet ──────────────────────────────────────────────────────────────────

const provider = new RpcProvider({ nodeUrl: RPC_URL });
const signer = new Signer(DEPLOYER_PRIVATE_KEY);
const account = new Account({ provider, address: DEPLOYER_ADDRESS, signer });

const CONTRACTS_DIR = join(__dirname, "..", "..", "contracts");
const semaphoreSierra = json.parse(
  readFileSync(
    join(
      CONTRACTS_DIR,
      "target",
      "dev",
      "semaphore_Semaphore.contract_class.json"
    ),
    "utf-8"
  )
);
const semaphore = new Contract({
  abi: semaphoreSierra.abi,
  address: SEMAPHORE_ADDRESS,
  providerOrAccount: account,
});

// ── Garaga Encoding ───────────────────────────────────────────────────────────

function hashForCircuit(v: bigint | string): string {
  return (BigInt(keccak256(toBeHex(v, 32))) >> 8n).toString();
}

function extractVk(depth = 20): any {
  const vkPath = join(
    __dirname,
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

async function encodeCalldata(proof: any): Promise<string[]> {
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
    if (strs.length > 1 && strs[0] === String(strs.length - 1)) {
      return strs.slice(1);
    }
    return strs;
  } catch (_e) {
    console.log("[calldata] WASM failed, trying Python CLI...");
  }

  // Strategy 2: Garaga Python CLI (micromamba)
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
  const mambaPrefix = join(home, ".mamba");
  const micromamba = join(home, ".local", "bin", "micromamba");
  const cmd =
    `MAMBA_ROOT_PREFIX="${mambaPrefix}" "${micromamba}" run -n garaga ` +
    `garaga calldata --system groth16 ` +
    `--vk "${join(tmpDir, "vk.json")}" ` +
    `--proof "${join(tmpDir, "proof.json")}" ` +
    `--public-inputs "${join(tmpDir, "public.json")}" ` +
    `--format array 2>&1`;
  const output = execSync(cmd, { encoding: "utf-8", timeout: 120_000 }).trim();
  const raw: string[] = JSON.parse(output);
  if (raw.length > 1 && String(raw[0]) === String(raw.length - 1)) {
    return raw.slice(1);
  }
  return raw;
}

// ── Express App ───────────────────────────────────────────────────────────────

const app = express();
app.use(cors());
app.use(express.json({ limit: "10mb" }));
app.use(express.static(PUBLIC_DIR)); // serves index.html, bundle.js, style.css

// GET /api/state — current group + vote state
app.get("/api/state", (_req, res) => {
  const state = loadState();
  const yesVotes = state.votes.filter((v) => v.choice === "yes").length;
  const noVotes = state.votes.filter((v) => v.choice === "no").length;
  res.json({
    groupCreated: state.groupCreated,
    memberCount: state.commitments.length,
    commitments: state.commitments,
    yesVotes,
    noVotes,
    recentVotes: state.votes.slice(-10).reverse(),
    question: VOTE_QUESTION,
    scope: SCOPE.toString(),
    groupId: GROUP_ID.toString(),
    contractAddress: SEMAPHORE_ADDRESS,
  });
});

// POST /api/join — add a member to the group
app.post("/api/join", async (req, res) => {
  if (_stateLock) {
    return res.status(429).json({ error: "Server busy, try again" });
  }
  const { commitment } = req.body;
  if (!commitment) return res.status(400).json({ error: "commitment required" });

  const state = loadState();

  if (state.commitments.includes(commitment)) {
    return res.json({ alreadyMember: true, commitments: state.commitments });
  }

  _stateLock = true;
  try {
    // Build group with new member to compute new root
    const allMembers = [...state.commitments, commitment].map(BigInt);
    const group = new Group(allMembers);
    const newRoot = group.root;

    const tx = await semaphore.invoke("add_member", [
      GROUP_ID,
      BigInt(commitment),
      newRoot,
    ]);
    await provider.waitForTransaction(tx.transaction_hash);

    state.commitments.push(commitment);
    saveState(state);

    res.json({
      alreadyMember: false,
      txHash: tx.transaction_hash,
      commitments: state.commitments,
      memberCount: state.commitments.length,
    });
  } catch (e: any) {
    res.status(500).json({ error: e?.message || "Failed to join" });
  } finally {
    _stateLock = false;
  }
});

// POST /api/vote — encode proof + submit signal
app.post("/api/vote", async (req, res) => {
  const { proof } = req.body;
  if (!proof) return res.status(400).json({ error: "proof required" });

  const state = loadState();

  // Check local nullifier cache first (fast)
  if (state.votes.find((v) => v.nullifier === proof.nullifier)) {
    return res.status(400).json({ error: "Already voted" });
  }

  try {
    console.log("[vote] Encoding calldata via Garaga...");
    const calldata = await encodeCalldata(proof);
    console.log(`[vote] Calldata encoded (${calldata.length} felts). Submitting...`);

    const tx = await semaphore.invoke("send_signal", [GROUP_ID, calldata]);
    const receipt = await provider.waitForTransaction(tx.transaction_hash);

    if ((receipt as any).statusReceipt === "REJECTED") {
      return res.status(400).json({ error: "Transaction rejected on-chain" });
    }

    const choice =
      String(proof.message) === "1" || BigInt(proof.message) === 1n
        ? "yes"
        : "no";

    state.votes.push({
      nullifier: proof.nullifier,
      choice,
      txHash: tx.transaction_hash,
      timestamp: Date.now(),
    });
    saveState(state);

    res.json({ txHash: tx.transaction_hash, choice });
  } catch (e: any) {
    const msg = e?.message || "Failed to submit vote";
    if (
      msg.includes("Nullifier already used") ||
      msg.includes("REVERTED") ||
      msg.includes("reverted")
    ) {
      return res.status(400).json({ error: "Already voted (on-chain)" });
    }
    res.status(500).json({ error: msg });
  }
});

// POST /api/check-nullifier — check if a nullifier was already used
app.post("/api/check-nullifier", async (req, res) => {
  const { nullifier } = req.body;
  if (!nullifier) return res.status(400).json({ error: "nullifier required" });
  const state = loadState();
  const usedLocally = !!state.votes.find((v) => v.nullifier === nullifier);
  const vote = state.votes.find((v) => v.nullifier === nullifier);
  res.json({ used: usedLocally, choice: vote?.choice ?? null });
});

// ── Startup ───────────────────────────────────────────────────────────────────

async function init() {
  const state = loadState();
  if (!state.groupCreated) {
    try {
      const exists = await semaphore.call("group_exists", [GROUP_ID]);
      if (!exists) {
        console.log(`[init] Creating demo group (id=${GROUP_ID}) on Sepolia...`);
        const tx = await semaphore.invoke("create_group", [GROUP_ID]);
        await provider.waitForTransaction(tx.transaction_hash);
        console.log(`[init] Group created: ${tx.transaction_hash}`);
      } else {
        console.log(`[init] Group ${GROUP_ID} already exists on-chain.`);
      }
      state.groupCreated = true;
      saveState(state);
    } catch (e: any) {
      console.error("[init] Warning: could not verify/create group:", e?.message);
    }
  }
}

app.listen(PORT, async () => {
  console.log(`\nSemaphore Usecase Demo on StarkNet`);
  console.log(`   http://localhost:${PORT}`);
  console.log(`   Network:  Sepolia`);
  console.log(`   Contract: ${SEMAPHORE_ADDRESS.slice(0, 20)}...`);
  console.log(`   Group ID: ${GROUP_ID}\n`);
  await init();
});
