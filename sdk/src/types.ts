export interface SemaphoreProofResult {
  proof: SemaphoreFullProof;
  merkleTreeRoot: bigint;
  nullifier: bigint;
  message: bigint;
  scope: bigint;
}

export interface SemaphoreFullProof {
  merkleTreeDepth: number;
  merkleTreeRoot: string;
  nullifier: string;
  message: string;
  scope: string;
  points: string[];
}
