import { Group } from "@semaphore-protocol/group";

/** Default tree depth matching Semaphore V4 and our contract constant */
export const DEFAULT_TREE_DEPTH = 20;

/**
 * Create a new off-chain Semaphore group (BN254-Poseidon Merkle tree).
 */
export function createGroup(members?: bigint[]): Group {
  const group = new Group(members);
  return group;
}

/**
 * Add a member (identity commitment) to the group.
 * Returns the new Merkle root after insertion.
 */
export function addMember(group: Group, commitment: bigint): bigint {
  group.addMember(commitment);
  return group.root;
}

/**
 * Add multiple members to the group.
 * Returns the final Merkle root.
 */
export function addMembers(group: Group, commitments: bigint[]): bigint {
  group.addMembers(commitments);
  return group.root;
}

/**
 * Remove a member from the group by index (sets leaf to 0n).
 * Returns the new Merkle root after removal.
 */
export function removeMember(group: Group, index: number): bigint {
  group.removeMember(index);
  return group.root;
}

/**
 * Get the current Merkle root of the group as a bigint.
 */
export function getRoot(group: Group): bigint {
  return group.root;
}

/**
 * Get the Merkle proof for a member at the given index.
 */
export function getMerkleProof(group: Group, index: number) {
  return group.generateMerkleProof(index);
}
