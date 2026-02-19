/**
 * Debug script to test Garaga verifier directly and capture raw RPC errors.
 */

import { RpcProvider, Account, Contract, json, CallData, Signer } from "starknet";
import { readFileSync, writeFileSync } from "fs";
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
const VERIFIER_DIR = join(PROJECT_ROOT, "..", "semaphore_verifier");

const DEVNET_URL = "http://127.0.0.1:5050";

function readContractArtifact(dir: string, filename: string): any {
  const path = join(dir, "target", "dev", filename);
  return json.parse(readFileSync(path, "utf-8"));
}

async function main() {
  console.log("=== Garaga Verifier Debug ===\n");

  const provider = new RpcProvider({ nodeUrl: DEVNET_URL });

  // Get account
  const resp = await fetch(DEVNET_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", method: "devnet_getPredeployedAccounts", params: {}, id: 1 }),
  });
  const accJson = (await resp.json()) as any;
  const { address, private_key } = accJson.result[0];
  const account = new Account({ provider, address, signer: new Signer(private_key) });
  console.log("Account:", address);

  // Declare ECIP class
  console.log("\nDeclaring ECIP ops class...");
  const ecipSierra = json.parse(readFileSync(join(VERIFIER_DIR, "ecip_artifacts", "universal_ecip_UniversalECIP.contract_class.json"), "utf-8"));
  const ecipCasm = json.parse(readFileSync(join(VERIFIER_DIR, "ecip_artifacts", "universal_ecip_UniversalECIP.compiled_contract_class.json"), "utf-8"));
  const ecipResult = await account.declareIfNot({ contract: ecipSierra, casm: ecipCasm });
  if (ecipResult.transaction_hash) await provider.waitForTransaction(ecipResult.transaction_hash);
  console.log("ECIP class hash:", ecipResult.class_hash);

  // Deploy verifier
  console.log("\nDeclaring + deploying verifier...");
  const verifierSierra = readContractArtifact(VERIFIER_DIR, "semaphore_verifier_Groth16VerifierBN254.contract_class.json");
  const verifierCasm = readContractArtifact(VERIFIER_DIR, "semaphore_verifier_Groth16VerifierBN254.compiled_contract_class.json");
  const vDeclare = await account.declareIfNot({ contract: verifierSierra, casm: verifierCasm });
  if (vDeclare.transaction_hash) await provider.waitForTransaction(vDeclare.transaction_hash);
  const vDeploy = await account.deployContract({ classHash: vDeclare.class_hash });
  await provider.waitForTransaction(vDeploy.transaction_hash);
  const verifierAddress = vDeploy.contract_address!;
  console.log("Verifier address:", verifierAddress);

  // Generate proof
  console.log("\nGenerating proof...");
  const identity = new Identity("debug-test-secret");
  const group = new Group([identity.commitment]);
  console.log("Group depth:", group.depth);
  const proof = await generateProof(identity, group, 42, 1);
  console.log("merkleTreeDepth:", proof.merkleTreeDepth);
  console.log("merkleTreeRoot:", proof.merkleTreeRoot.toString());
  console.log("nullifier:", proof.nullifier.toString());

  // Encode calldata
  console.log("\nEncoding via Garaga...");
  const vk = extractVerificationKey(proof.merkleTreeDepth);
  const calldata = await encodeForStarknet(proof as unknown as SemaphoreFullProof, vk);
  console.log("Calldata length:", calldata.length);

  if (calldata[0] === "ENCODING_PENDING") {
    console.log("Garaga encoding unavailable, cannot test");
    return;
  }

  // Save calldata for inspection
  writeFileSync("/tmp/garaga-debug-calldata.json", JSON.stringify(calldata, null, 2));
  console.log("Calldata saved to /tmp/garaga-debug-calldata.json");
  console.log("First 5 elements:", calldata.slice(0, 5));

  // Call verifier directly via raw RPC
  console.log("\nCalling verifier directly via raw RPC...");
  const calldataCompiled = CallData.compile({ full_proof_with_hints: calldata });
  console.log("Compiled calldata length:", calldataCompiled.length);
  console.log("First 10 elements:", calldataCompiled.slice(0, 10));

  // Convert calldata to hex strings for raw RPC
  const calldataHex = calldataCompiled.map(v => "0x" + BigInt(v).toString(16));

  const rpcPayload = {
    jsonrpc: "2.0",
    method: "starknet_call",
    params: {
      request: {
        contract_address: verifierAddress,
        entry_point_selector: "0x22de6dd3878da34d58a3bfde31eb6fbb3ea9715cb9a5ce6f665d5e5a5564d7a", // verify_groth16_proof_bn254
        calldata: calldataHex,
      },
      block_id: "latest",
    },
    id: 1,
  };

  const rpcResp = await fetch(DEVNET_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(rpcPayload),
  });

  const rpcResult = await rpcResp.json();
  console.log("\nRaw RPC response:");
  console.log(JSON.stringify(rpcResult, null, 2).substring(0, 5000));

  if ((rpcResult as any).error) {
    console.log("\n=== ERROR DETAILS ===");
    const error = (rpcResult as any).error;
    console.log("Code:", error.code);
    console.log("Message:", error.message);
    if (error.data) {
      console.log("Data:", JSON.stringify(error.data).substring(0, 3000));
    }
  } else {
    console.log("\n=== SUCCESS ===");
    console.log("Result:", JSON.stringify((rpcResult as any).result));
  }
}

main().catch(console.error);
