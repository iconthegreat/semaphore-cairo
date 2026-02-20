import { RpcProvider, Account, Contract, Signer } from "starknet";
import { readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { keccak256, toBeHex } from "ethers";
import {
  RPC_URL,
  SEMAPHORE_ADDRESS,
  DEPLOYER_ADDRESS,
  DEPLOYER_PRIVATE_KEY,
  GROUP_ID,
  SCOPE,
  DEPLOY_BLOCK,
} from "./config.js";

function hashForCircuit(v: bigint): bigint {
  return BigInt(keccak256(toBeHex(v, 32))) >> 8n;
}

const __dirname = dirname(fileURLToPath(import.meta.url));
const ABI_PATH = join(__dirname, "abi.json");

export function getProvider() {
  return new RpcProvider({ nodeUrl: RPC_URL });
}

export function getAccount(provider: RpcProvider) {
  const signer = new Signer(DEPLOYER_PRIVATE_KEY);
  return new Account({ provider, address: DEPLOYER_ADDRESS, signer });
}

export function getSemaphoreContract(account: Account) {
  const abi = JSON.parse(readFileSync(ABI_PATH, "utf-8"));
  return new Contract({ abi, address: SEMAPHORE_ADDRESS, providerOrAccount: account });
}

// Parse two consecutive felt252 values as a u256
export function parseU256(low: string, high: string): bigint {
  return BigInt(low) + BigInt(high) * (2n ** 128n);
}

// Read all MemberAdded + SignalProcessed events for group 42 from the chain
export async function readGroupEvents(provider: RpcProvider) {
  const { hash } = await import("starknet");

  const memberAddedKey = hash.getSelectorFromName("MemberAdded");
  const signalKey = hash.getSelectorFromName("SignalProcessed");

  async function fetchAll(key: string) {
    const results: any[] = [];
    let token: string | undefined;
    do {
      const resp: any = await provider.getEvents({
        from_block: { block_number: DEPLOY_BLOCK },
        to_block: "latest",
        address: SEMAPHORE_ADDRESS,
        keys: [[key]],
        chunk_size: 100,
        continuation_token: token,
      });
      results.push(...resp.events);
      token = resp.continuation_token;
    } while (token);
    return results;
  }

  const [memberEvents, signalEvents] = await Promise.all([
    fetchAll(memberAddedKey),
    fetchAll(signalKey),
  ]);

  // MemberAdded: group_id is a #[key] u256 → stored in keys[1] (low) and keys[2] (high)
  // data layout: [identity_commitment.low, identity_commitment.high, index.low, index.high, merkle_root.low, merkle_root.high]
  const commitments: string[] = [];
  for (const ev of memberEvents) {
    const k = ev.keys;
    if (k.length < 3) continue;
    const gid = parseU256(k[1], k[2]);
    if (gid !== GROUP_ID) continue;
    const d = ev.data;
    if (d.length < 2) continue;
    commitments.push(parseU256(d[0], d[1]).toString());
  }

  // SignalProcessed: group_id is a #[key] u256 → stored in keys[1] (low) and keys[2] (high)
  // data layout: [nullifier.low, nullifier.high, message.low, message.high, scope.low, scope.high]
  // message/scope in the event are hashForCircuit(raw_value) converted to u256
  const expectedScope = hashForCircuit(SCOPE);
  const yesHash = hashForCircuit(1n);  // raw message=1 means "yes"
  let yesVotes = 0;
  let noVotes = 0;
  const recentVotes: Array<{ nullifier: string; choice: string }> = [];
  for (const ev of signalEvents) {
    const k = ev.keys;
    if (k.length < 3) continue;
    const gid = parseU256(k[1], k[2]);
    if (gid !== GROUP_ID) continue;
    const d = ev.data;
    if (d.length < 6) continue;
    const sc = parseU256(d[4], d[5]);
    if (sc !== expectedScope) continue;
    const nullifier = parseU256(d[0], d[1]).toString();
    const message = parseU256(d[2], d[3]);
    const choice = message === yesHash ? "yes" : "no";
    if (choice === "yes") yesVotes++;
    else noVotes++;
    recentVotes.push({ nullifier, choice });
  }

  return {
    commitments,
    yesVotes,
    noVotes,
    recentVotes: recentVotes.slice(-10).reverse(),
  };
}
