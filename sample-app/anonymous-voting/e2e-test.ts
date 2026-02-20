/**
 * E2E test for the anonymous voting demo.
 * Simulates what the browser does: identity → join → proof → vote → results.
 *
 * Run: node e2e-test.ts
 */

import { Identity } from "@semaphore-protocol/identity";
import { Group } from "@semaphore-protocol/group";
import { generateProof } from "@semaphore-protocol/proof";

const BASE = "http://localhost:3000";

let passed = 0;
let failed = 0;

function assert(cond: boolean, msg: string) {
  if (cond) { console.log(`  [PASS] ${msg}`); passed++; }
  else       { console.error(`  [FAIL] ${msg}`); failed++; }
}

async function api(method: string, path: string, body?: any) {
  const resp = await fetch(`${BASE}${path}`, {
    method,
    headers: { "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await resp.json();
  return { ok: resp.ok, status: resp.status, data };
}

async function main() {
  console.log("=== Anonymous Voting — E2E Test ===\n");

  // ── 1. Server state ────────────────────────────────────────────────────
  console.log("1. Checking server state...");
  const { ok: stateOk, data: state } = await api("GET", "/api/state");
  assert(stateOk, "Server responds to /api/state");
  assert(state.groupCreated === true, "Demo group exists on Sepolia");
  assert(typeof state.question === "string", `Question: "${state.question}"`);
  assert(state.groupId === "42", "Group ID is 42");
  assert(typeof state.scope === "string", `Scope: ${state.scope}`);
  console.log(`  Members: ${state.memberCount}, Votes: YES=${state.yesVotes} NO=${state.noVotes}`);

  // ── 2. Generate identity (browser-side) ───────────────────────────────
  console.log("\n2. Generating Semaphore identity...");
  const identity = new Identity("e2e-test-secret-" + Date.now());
  const commitment = identity.commitment.toString();
  assert(BigInt(commitment) > 0n, `Commitment: ${commitment.slice(0, 20)}...`);

  // ── 3. Join group ──────────────────────────────────────────────────────
  console.log("\n3. Joining group (POST /api/join)...");
  const { ok: joinOk, data: joinData } = await api("POST", "/api/join", { commitment });
  assert(joinOk, "Join request succeeded");
  assert(!joinData.alreadyMember, "Not already a member");
  assert(typeof joinData.txHash === "string", `Join tx: ${joinData.txHash?.slice(0, 18)}...`);
  assert(joinData.commitments.includes(commitment), "Commitment in updated list");
  assert(joinData.memberCount >= 1, `Member count: ${joinData.memberCount}`);
  console.log(`  Group now has ${joinData.memberCount} member(s)`);

  // ── 4. Join again — should be idempotent ──────────────────────────────
  console.log("\n4. Joining again (idempotency check)...");
  const { ok: joinAgainOk, data: joinAgainData } = await api("POST", "/api/join", { commitment });
  assert(joinAgainOk, "Second join request succeeds (HTTP 200)");
  assert(joinAgainData.alreadyMember === true, "Returns alreadyMember=true");

  // ── 5. Generate ZK proof (browser-side) ───────────────────────────────
  console.log("\n5. Generating ZK proof (depth-20, downloading circuit if needed)...");
  console.log("   This may take 30-90s on first run (50MB circuit download)...");

  // Refresh state to get updated commitments
  const { data: freshState } = await api("GET", "/api/state");
  const group = new Group(freshState.commitments.map(BigInt));

  const message = 1n; // YES
  const scope = BigInt(freshState.scope);

  const t0 = Date.now();
  const proof = await generateProof(identity, group, message, scope, 20);
  const elapsed = Date.now() - t0;

  assert(proof.merkleTreeDepth === 20, `Proof depth: ${proof.merkleTreeDepth}`);
  assert(typeof proof.nullifier === "string", `Nullifier: ${proof.nullifier.slice(0, 20)}...`);
  assert(typeof proof.merkleTreeRoot === "string", `Root: ${proof.merkleTreeRoot.slice(0, 20)}...`);
  assert(proof.points.length === 8, `Proof has 8 curve points`);
  console.log(`  Proof generated in ${elapsed}ms`);

  // ── 6. Vote YES ────────────────────────────────────────────────────────
  console.log("\n6. Submitting vote YES (POST /api/vote)...");
  console.log("   Garaga encoding + Sepolia tx (30-120s)...");
  const t1 = Date.now();
  const { ok: voteOk, status: voteStatus, data: voteData } = await api("POST", "/api/vote", { proof });
  const voteElapsed = Date.now() - t1;

  assert(voteOk, `Vote accepted (status ${voteStatus}): ${voteData.txHash?.slice(0, 18) ?? voteData.error}...`);
  assert(voteData.choice === "yes", `Choice recorded as 'yes'`);
  assert(typeof voteData.txHash === "string", `Vote tx: ${voteData.txHash?.slice(0, 18)}...`);
  console.log(`  Vote submitted in ${voteElapsed}ms`);

  // ── 7. Check nullifier used ────────────────────────────────────────────
  console.log("\n7. Checking nullifier is marked used...");
  const { data: nullData } = await api("POST", "/api/check-nullifier", { nullifier: proof.nullifier });
  assert(nullData.used === true, "Nullifier marked as used");
  assert(nullData.choice === "yes", "Choice recorded correctly");

  // ── 8. Double vote rejected ────────────────────────────────────────────
  console.log("\n8. Double vote rejection...");
  const { ok: dvOk, data: dvData } = await api("POST", "/api/vote", { proof });
  assert(!dvOk, "Double vote rejected (non-200 status)");
  assert(dvData.error?.includes("Already voted") || dvData.error?.includes("already"),
    `Error: "${dvData.error}"`);

  // ── 9. Results updated ─────────────────────────────────────────────────
  console.log("\n9. Checking results updated...");
  const { data: finalState } = await api("GET", "/api/state");
  assert(finalState.yesVotes >= 1, `YES votes: ${finalState.yesVotes}`);
  assert(finalState.memberCount >= 1, `Members: ${finalState.memberCount}`);
  assert(finalState.recentVotes.length >= 1, "Recent votes list populated");
  assert(finalState.recentVotes[0].choice === "yes", "Most recent vote is YES");

  // ── Summary ────────────────────────────────────────────────────────────
  console.log(`\n${"─".repeat(50)}`);
  console.log(`Passed: ${passed}  Failed: ${failed}`);
  if (failed > 0) {
    console.error("\nSome tests failed.");
    process.exit(1);
  }
  console.log("\n✓ All tests passed!");
  console.log(`\nFinal state:`);
  console.log(`  YES: ${finalState.yesVotes}  NO: ${finalState.noVotes}  Members: ${finalState.memberCount}`);
}

main().catch((e) => { console.error("Fatal:", e); process.exit(1); });
