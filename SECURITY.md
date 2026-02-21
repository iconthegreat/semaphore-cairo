# Security

## Trusted Setup

This system uses **Groth16** over the BN254 curve, verified on-chain via [Garaga](https://github.com/keep-starknet-strange/garaga). Groth16 requires a circuit-specific **trusted setup ceremony**. The verification key hardcoded in `semaphore_verifier/src/groth16_verifier_constants.cairo` corresponds to the **Semaphore V4 Powers of Tau ceremony** run by Privacy & Scaling Explorations (PSE).

**Security assumption:** The soundness of every ZK proof accepted by this contract depends on at least one ceremony participant having honestly destroyed their secret randomness ("toxic waste"). If all participants colluded or were compromised, an adversary could forge valid Groth16 proofs for arbitrary identities — including valid nullifiers for users who never registered — with no on-chain indication of fraud.

- Ceremony transcript: https://ceremony.pse.dev
- Semaphore audit reports: https://semaphore.pse.dev/audits

**Phase 2 plan:** The Semaphore circuit will be rewritten natively in Cairo using STARKs, eliminating the trusted setup assumption entirely. STARKs are transparent — there is no ceremony, no toxic waste, and no single-point-of-failure in the proof system. This also resolves the BN254/Stark field mismatch, allowing the Merkle tree to move on-chain.

## Scope Design

The `scope` parameter binds a nullifier to a specific context. Two signals with the same identity and scope produce the same nullifier and the second will be rejected as a replay. **Unlinkability across applications only holds if each application uses a distinct, unpredictable scope.**

**Recommended construction:**

```typescript
import { computeScope } from "@semaphore-protocol/cairo-sdk";

const scope = computeScope(contractAddress, "my-app-v1");
```

This hashes `keccak256(contractAddress || domainSeparator) >> 8` to produce a scope that is unique per deployer by default. Using a raw integer (e.g. `scope = 1n`) as scope in production allows cross-protocol nullifier correlation.

## Admin Trust

Each group has a single admin address that can add and remove members without on-chain verification of their inputs. The admin can:
- Submit any Merkle root (including one excluding legitimate members)
- Add arbitrary identity commitments (including for sanctioned actors)

For production use, the admin role should be a multisig or DAO contract. See `transfer_admin()` for key rotation.

## Revocation Window

When a member is removed, any proof they generated against a root in the 20-slot history window **remains valid until that root is evicted**. For compliance-critical groups requiring immediate revocation, set `root_history_size = 1` in the constructor (disables the liveness window) or implement a separate revocation accumulator.

## Front-Running

`send_signal()` is permissionless — anyone can submit a proof on behalf of a group member. A proof observed in the mempool can be front-run: the front-runner's transaction spends the nullifier, forcing the legitimate user to generate a new proof. This is a griefing vector, not a security failure — the front-runner proves nothing about their own identity. If front-running resistance is required, bind the scope to a specific recipient address.

## Reporting Vulnerabilities

Open a GitHub issue or contact the maintainers directly. Do not disclose security vulnerabilities publicly before a fix is available.
