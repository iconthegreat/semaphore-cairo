/**
 * Browser bundle entry point.
 * Exposes Semaphore identity + group + proof generation to window.SemaphoreCairo
 */
import { Identity } from "@semaphore-protocol/identity";
import { Group } from "@semaphore-protocol/group";
import { generateProof, verifyProof } from "@semaphore-protocol/proof";

/** Create a random identity, or restore from a secret key string */
export function createIdentity(secretKey?: string): Identity {
  return secretKey ? new Identity(secretKey) : new Identity();
}

/** Get the public commitment (bigint as decimal string) */
export function getCommitment(identity: Identity): string {
  return identity.commitment.toString();
}

/**
 * Rebuild the off-chain group from a list of commitment strings.
 * Uses the same LeanIMT structure as the contracts.
 */
export function createGroup(commitments: string[]): Group {
  return new Group(commitments.map(BigInt));
}

/** Get the current Merkle root of a group as decimal string */
export function getRoot(group: Group): string {
  return group.root.toString();
}

/**
 * Generate a depth-20 Groth16 proof.
 * First call downloads circuit WASM + zkey (~50MB) from CDN.
 */
export async function generateSemaphoreProof(
  identity: Identity,
  group: Group,
  message: bigint,
  scope: bigint
): Promise<any> {
  return await generateProof(identity, group, message, scope, 20);
}

/** Verify a proof off-chain (fast, no network needed) */
export async function verifySemaphoreProof(proof: any): Promise<boolean> {
  return await verifyProof(proof);
}
