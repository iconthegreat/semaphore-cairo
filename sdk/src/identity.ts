import { Identity } from "@semaphore-protocol/identity";

/**
 * Create a new Semaphore V4 identity (random private key).
 * Returns the Identity object which contains privateKey, publicKey, and commitment.
 */
export function createIdentity(): Identity {
  return new Identity();
}

/**
 * Recreate an identity from an existing private key.
 */
export function createIdentityFromPrivateKey(privateKey: string): Identity {
  return new Identity(privateKey);
}

/**
 * Get the identity commitment (used for add_member on-chain).
 * Returns the commitment as a bigint.
 */
export function getCommitment(identity: Identity): bigint {
  return identity.commitment;
}
