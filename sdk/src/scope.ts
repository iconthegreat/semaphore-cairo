/**
 * Scope construction helpers.
 *
 * The `scope` parameter in Semaphore binds a nullifier to a specific context.
 * Unlinkability across applications ONLY holds when each application uses a
 * distinct, unpredictable scope value.
 *
 * Using raw small integers (e.g. scope = 1n) in production allows an adversary
 * observing multiple contracts' nullifier registries to correlate the same
 * identity across protocols.
 *
 * Recommended construction: Hash(contractAddress || domainSeparator)
 */

import { keccak256, toBeHex, getBytes, concat } from "ethers";

/**
 * Compute a safe scope value for a Semaphore group.
 *
 * Produces: keccak256(contractAddress || domainSeparator) >> 8
 * — unique per deployer by default, fits in a felt252.
 *
 * @param contractAddress - The StarkNet contract address (hex string or bigint)
 * @param domainSeparator - An application-specific string (e.g. "my-app-v1", "election-2026")
 * @returns A bigint scope value safe for production use
 *
 * @example
 * const scope = computeScope(
 *   "0x0002e2b414c453ee2c862d8f9d06fac9817dfff8afe2bde8ba60ddb75585a37b",
 *   "anonymous-voting-v1"
 * );
 */
export function computeScope(
  contractAddress: string | bigint,
  domainSeparator: string,
): bigint {
  const addrBytes = getBytes(toBeHex(BigInt(contractAddress), 32));
  const domainBytes = new TextEncoder().encode(domainSeparator);
  const combined = concat([addrBytes, domainBytes]);
  return BigInt(keccak256(combined)) >> 8n;
}

/**
 * Warn if a scope value looks like a raw test integer.
 * Call this before generateSemaphoreProof() in production code.
 */
export function assertProductionScope(scope: bigint): void {
  if (scope < 1000n) {
    throw new Error(
      `Scope value ${scope} looks like a test placeholder. ` +
      `Use computeScope(contractAddress, domainSeparator) to derive a safe production scope. ` +
      `See SECURITY.md for details.`,
    );
  }
}
