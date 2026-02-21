// Identity
export { createIdentity, createIdentityFromPrivateKey, getCommitment } from "./identity.js";

// Group
export { createGroup, addMember, addMembers, removeMember, getRoot, getMerkleProof, DEFAULT_TREE_DEPTH } from "./group.js";

// Proof
export { generateSemaphoreProof, verifySemaphoreProof, extractVerificationKey } from "./proof.js";

// Calldata
export { encodeForStarknet, validateCalldataLength } from "./calldata.js";

// Scope
export { computeScope, assertProductionScope } from "./scope.js";

// Types
export type {
  SemaphoreProofResult,
  SemaphoreFullProof,
} from "./types.js";
