# semaphore-cairo

Anonymous group signaling on StarkNet using Groth16 zero-knowledge proofs.

A Cairo/StarkNet port of [Semaphore V4](https://semaphore.pse.dev/), enabling on-chain anonymous signals: prove you are a member of a group and broadcast a message — without revealing *which* member you are. Replay protection is enforced via nullifiers, so no member can signal twice in the same scope.

---

## Live Deployment (Sepolia)

| Contract | Address |
|---|---|
| Groth16 Verifier (depth-20) | `0x004ca3c4b5711210408d1433086a525a5249c38d05ce072f3b1dbd870cb58a77` |
| Semaphore | `0x0002e2b414c453ee2c862d8f9d06fac9817dfff8afe2bde8ba60ddb75585a37b` |

---

## How It Works

1. **Create an identity** — a keypair whose public half (the *commitment*) can be published
2. **Join a group** — the group admin adds your commitment to an off-chain Merkle tree and stores the root on-chain
3. **Generate a proof** — locally prove you know the secret behind a commitment in the tree, and that you intend to signal a specific message in a specific scope
4. **Send a signal** — submit the proof on-chain; the Groth16 verifier checks the BN254 pairing, the contract verifies the Merkle root, records the nullifier, and emits a `SignalProcessed` event

Nobody can tell which member sent the signal. The same member cannot signal twice in the same scope (the nullifier prevents it).

### Architecture

```
  Off-chain                             On-chain (StarkNet)
  ─────────────────────────             ───────────────────────────────────────
  Identity                              Semaphore Contract
    secret_key ──┐                        create_group()
    commitment ◄─┘ (BN254-Poseidon)       add_member(commitment, new_root)
                                          send_signal(group_id, proof_calldata)
  Group (BN254-Poseidon Merkle tree)        │
    [commitment₀, commitment₁, ...]         │ calls
    root ──────────────────────────► verifies root in root_history
                                          │
  Groth16 Proof (snarkjs / BN254)         │ calls
    secret + Merkle path ──► proof ──────► Garaga Verifier Contract
    public outputs:                          verify_groth16_proof_bn254()
      merkle_root                              MSM via ECIP ops class
      nullifier                                BN254 pairing check
      hash(message)                          returns [root, nullifier, msg, scope]
      hash(scope)                          │
                                          check !used_nullifiers[nullifier]
  Garaga CLI                              mark nullifier used
    proof + VK ──► 1977 felt252s          emit SignalProcessed
```

**Why the tree is off-chain:** StarkNet's native Poseidon operates on the Stark field, while Semaphore's circuit uses BN254-Poseidon (a different prime). On-chain hashes would diverge from the proof. The admin manages the tree off-chain and anchors roots on-chain.

---

## Repository Structure

```
semaphore-cairo/
├── contracts/               Cairo smart contracts (Scarb 2.15.1, snforge 0.55.0)
│   ├── src/
│   │   ├── semaphore.cairo  Main contract: groups, members, signal submission
│   │   ├── verifier.cairo   ISemaphoreVerifier trait + MockSemaphoreVerifier
│   │   ├── merkle.cairo     Stark-field Poseidon Merkle utilities
│   │   ├── identity.cairo   Stark-field identity helpers
│   │   └── constants.cairo  Tree depth, zero hashes (Stark field)
│   └── tests/               55 unit + integration tests
│
├── semaphore_verifier/      Garaga-generated BN254 Groth16 verifier (Scarb 2.14.0)
│   ├── src/
│   │   ├── groth16_verifier.cairo           Pairing check + ECIP syscall
│   │   └── groth16_verifier_constants.cairo Hardcoded VK (depth-20, 4171 lines)
│   └── ecip_artifacts/      Pre-compiled ECIP ops class (declared on Sepolia)
│
├── sdk/                     TypeScript SDK (Node.js ≥ 20)
│   ├── src/
│   │   ├── identity.ts      Identity creation / restoration
│   │   ├── group.ts         Group / Merkle tree management
│   │   ├── proof.ts         Groth16 proof generation + VK extraction
│   │   └── calldata.ts      Garaga encoding → felt252 array
│   └── scripts/
│       ├── e2e-integration.ts  Full devnet integration test (15 assertions)
│       ├── e2e-sepolia.ts      Sepolia smoke test (12 assertions)
│       └── generate-proof.ts  Standalone proof demo
│
└── scripts/
    └── deploy.sh            Build + declare + deploy (devnet or Sepolia)
```

---

## Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| [Scarb](https://docs.swmansion.com/scarb/) | 2.15.1 | Build Cairo contracts |
| Scarb | 2.14.0 | Build Garaga verifier (separate install) |
| [snforge](https://foundry-rs.github.io/starknet-foundry/) | 0.55.0 | Run Cairo tests |
| [sncast](https://foundry-rs.github.io/starknet-foundry/) | 0.55.0 | Deploy contracts |
| Node.js | ≥ 20 | Run the SDK |
| Python | 3.10.x | Garaga Python CLI (via micromamba) |
| [micromamba](https://mamba.readthedocs.io/) | any | Manage Python 3.10 env for Garaga |
| starknet-devnet | 0.7.1 | Local devnet for integration tests |

### Install Scarb 2.14.0 alongside 2.15.1

```bash
# Using asdf
asdf install scarb 2.14.0
# Verify
/path/to/.asdf/installs/scarb/2.14.0/bin/scarb --version
```

The verifier's `groth16_verifier_constants.cairo` (4171 lines of array literals) hangs indefinitely with Scarb 2.15.1 — use 2.14.0 for that package only.

### Install Garaga Python CLI

```bash
micromamba create -n garaga python=3.10
micromamba run -n garaga pip install garaga==1.0.1
# Usage:
MAMBA_ROOT_PREFIX=~/.mamba micromamba run -n garaga garaga --help
```

---

## Building

```bash
# 1. Build Cairo contracts
cd contracts
scarb build

# 2. Build Garaga verifier (must use Scarb 2.14.0)
cd semaphore_verifier
/path/to/scarb-2.14.0 build

# 3. Install SDK dependencies
cd sdk
npm install
```

---

## Testing

### Cairo unit tests (55 tests)

```bash
cd contracts
snforge test
```

Expected output: `Tests: 55 passed, 0 failed`.

What's covered:

| Suite | Tests | Covers |
|---|---|---|
| `test_semaphore.cairo` | 21 | Groups, members, signal flow, root history ring buffer, nullifiers, admin auth |
| `test_identity.cairo` | 11 | Commitment determinism, uniqueness, nullifier hash ordering |
| `test_merkle.cairo` | 12 | Zero hashes, Merkle proof verification, root computation |
| `test_verifier.cairo` | 3 | Mock verifier proof decoding, malformed input rejection |

### SDK off-chain pipeline (no network required)

```bash
cd sdk
npx tsx scripts/e2e-test.ts
```

Tests identity creation → group management → Groth16 proof generation → local verification → Garaga calldata encoding. No blockchain connection needed.

### Devnet integration test (15 assertions)

Requires devnet running:

```bash
starknet-devnet --port 5050 --seed 0
```

Then:

```bash
cd sdk
npx tsx scripts/e2e-integration.ts
```

Covers the full lifecycle: deploy contracts → create group → add member → generate proof → send signal → verify nullifier → reject duplicate signal.

### Sepolia smoke test

```bash
cd sdk
npx tsx scripts/e2e-sepolia.ts
```

Connects to the live Sepolia deployment and runs the same flow against real contracts.

---

## Deploying

### Local devnet

```bash
# Start devnet (separate terminal)
starknet-devnet --port 5050 --seed 0

# Deploy
./scripts/deploy.sh devnet
```

The script:
1. Builds the verifier with Scarb 2.14.0 and contracts with 2.15.1
2. Declares the Garaga ECIP ops class on devnet
3. Declares + deploys the Groth16 verifier
4. Declares + deploys the Semaphore contract (with verifier address as constructor arg)
5. Writes addresses to `scripts/deployed-addresses.json`

### Sepolia testnet

```bash
# Set up your account (one-time)
sncast account create --url https://api.cartridge.gg/x/starknet/sepolia --name my-deployer
# Fund it with testnet STRK at https://starknet-faucet.vercel.app
sncast account deploy --url https://api.cartridge.gg/x/starknet/sepolia --name my-deployer

# Deploy
export STARKNET_ACCOUNT=my-deployer
./scripts/deploy.sh sepolia
```

The ECIP ops class (`0x312d1dd5...`) is already declared on Sepolia by Garaga — the script skips that step automatically.

---

## Using the SDK

### Create an identity

```typescript
import { Identity } from "@semaphore-protocol/identity";

const identity = new Identity();
console.log(identity.commitment.toString()); // Public — share this
// Keep identity.secretScalar private
```

### Create a group and add members

```typescript
import { Group } from "@semaphore-protocol/group";

const group = new Group([identity.commitment]);
console.log(group.root.toString()); // Merkle root — store this on-chain
```

### Generate a proof

```typescript
import { generateProof } from "@semaphore-protocol/proof";

const MESSAGE = 42n;  // What you're signaling
const SCOPE   = 1n;   // e.g. election ID — nullifier scoped to this

// Always use depth-20 to match the on-chain verifier VK
const proof = await generateProof(identity, group, MESSAGE, SCOPE, 20);
// proof.merkleTreeDepth === 20
// proof.nullifier  — unique per (identity, scope)
// proof.points     — 8 BN254 curve point coordinates
```

### Encode for StarkNet

```typescript
import { encodeForStarknet } from "./src/calldata.js";
import { extractVerificationKey } from "./src/proof.js";

const vk = extractVerificationKey(20);
const calldata = await encodeForStarknet(proof, vk);
// calldata: string[] of ~1977 felt252 values
```

### Send the signal on-chain

```typescript
import { RpcProvider, Account, Contract, CallData } from "starknet";

const provider = new RpcProvider({ nodeUrl: "https://api.cartridge.gg/x/starknet/sepolia" });
const account  = new Account({ provider, address, signer });
const semaphore = new Contract({ abi, address: SEMAPHORE_ADDRESS, providerOrAccount: account });

const tx = await semaphore.invoke("send_signal", [
  GROUP_ID,
  calldata.map(v => v.toString()),
]);
await provider.waitForTransaction(tx.transaction_hash);
```

---

## Contract Interface

### Semaphore (main contract)

```cairo
trait ISemaphore {
    // Group management (admin only after creation)
    fn create_group(ref self, group_id: u256);
    fn add_member(ref self, group_id: u256, identity_commitment: u256, new_merkle_root: u256);
    fn remove_member(ref self, group_id: u256, identity_commitment: u256, new_merkle_root: u256);

    // Signal submission (any caller with valid proof)
    fn send_signal(ref self, group_id: u256, full_proof_with_hints: Span<felt252>);

    // Read-only queries
    fn get_merkle_root(self: @ContractState, group_id: u256) -> u256;
    fn is_nullifier_used(self: @ContractState, nullifier: u256) -> bool;
    fn get_group_member_count(self: @ContractState, group_id: u256) -> u256;
    fn group_exists(self: @ContractState, group_id: u256) -> bool;
    fn get_group_admin(self: @ContractState, group_id: u256) -> ContractAddress;
    fn is_valid_root(self: @ContractState, group_id: u256, root: u256) -> bool;
}
```

**Events emitted:**

```cairo
GroupCreated   { group_id: u256, admin: ContractAddress }
MemberAdded    { group_id: u256, identity_commitment: u256, index: u256, merkle_root: u256 }
MemberRemoved  { group_id: u256, identity_commitment: u256, merkle_root: u256 }
SignalProcessed{ group_id: u256, nullifier: u256, message: u256, scope: u256 }
```

**Root history:** The contract stores the 20 most recent Merkle roots per group. `send_signal` accepts a proof against any root in this window, so in-flight transactions remain valid even if new members are added concurrently.

### Groth16 Verifier

```cairo
trait IGroth16VerifierBN254 {
    fn verify_groth16_proof_bn254(
        full_proof_with_hints: Span<felt252>
    ) -> Result<Span<u256>, felt252>;
    // Ok([merkle_root, nullifier, message_hash, scope_hash]) on success
    // Err(reason) on failure
}
```

The `full_proof_with_hints` input (~1977 felt252 values) is produced by the Garaga Python CLI or npm package. It encodes the BN254 proof points, public inputs, and precomputed Miller loop hints required for efficient on-chain pairing verification.

---

## Regenerating the Verifier

The Garaga verifier is generated from a Semaphore V4 verification key for a specific tree depth. The repo ships with the depth-20 VK (supports groups up to ~1 million members).

To regenerate (e.g. after a Garaga upgrade):

```bash
# 1. Extract the depth-20 VK
cd sdk && npx tsx scripts/extract-vk.ts  # writes sdk/artifacts/semaphore-20-vk.json

# 2. Generate new verifier project
mkdir /tmp/regen && cp sdk/artifacts/semaphore-20-vk.json /tmp/regen/vk.json
cd /tmp/regen
MAMBA_ROOT_PREFIX=~/.mamba micromamba run -n garaga \
  bash -c 'export PATH="/path/to/scarb-2.14.0/bin:$PATH" && \
           garaga gen --system groth16 --vk vk.json --project-name semaphore_verifier'

# 3. Copy new constants
cp /tmp/regen/semaphore_verifier/src/groth16_verifier_constants.cairo \
   /path/to/semaphore-cairo/semaphore_verifier/src/

# 4. Rebuild
cd semaphore_verifier
/path/to/scarb-2.14.0 build
```

**Why depth-20?** Semaphore's `generateProof` function accepts an explicit `merkleTreeDepth` parameter and zero-pads shorter Merkle paths. Passing `merkleTreeDepth: 20` works for any group size and matches the on-chain VK.

---

## Key Design Decisions

**Groth16 over STARK proofs (Phase 1)** — Semaphore V4's reference implementation uses Circom + BN254 Groth16. Reusing the same circuit and VK means the off-chain SDK is identical to the EVM version; only the on-chain verifier changes. This is a pragmatic Phase 1 choice — Groth16 requires a [trusted setup ceremony](SECURITY.md#trusted-setup) and creates the BN254/Stark field mismatch that forces the Merkle tree off-chain.

**Phase 2 — STARK-native circuit:** The Semaphore circuit (identity commitment, Merkle proof, nullifier derivation) will be rewritten natively in Cairo using STARKs. This eliminates the trusted setup entirely, removes the BN254/Stark field split (the Merkle tree can move on-chain), and simplifies the proof pipeline — no Garaga, no snarkjs, no Python dependency. The on-chain verifier becomes a native STARK verifier at a fraction of the current calldata size.

**Off-chain Merkle tree** — StarkNet's Poseidon uses a different prime than BN254-Poseidon. A tree computed on-chain would produce different roots than the off-chain tree the proof is generated against. The admin manages the tree off-chain and anchors roots on-chain.

**u256 for BN254 scalars** — BN254 field elements are ~254 bits, which can exceed Cairo's felt252 (~252 bits). Roots, nullifiers, and public inputs are stored as u256 to avoid silent overflow.

**Single admin per group** — The current design has one admin address per group. Upgrading to multisig or DAO control is possible by replacing the admin address check with a contract call.

**Root history ring buffer** — 20 recent roots are stored per group. Transactions that were submitted before a root update (but confirmed after) remain valid as long as they reference a root within the last 20 updates.

---

## Limitations & Roadmap

### Phase 1 — Groth16 (current)

| Item | Status |
|---|---|
| Core contracts + 63 tests | ✅ Complete |
| Garaga verifier (depth-20) | ✅ Complete |
| TypeScript SDK | ✅ Complete |
| Sepolia deployment | ✅ Live |
| SECURITY.md + audit hardening | ✅ Complete |
| Frontend / wallet integration | ⬜ Not started |
| Multisig group admin | ⬜ Not started |
| Batch member addition | ⬜ Not started |
| Security audit | ⬜ Required before mainnet |

### Phase 2 — STARK-native circuit (planned)

Rewrite the Semaphore circuit in Cairo/STARKs. This is the long-term architecture:

| Item | Notes |
|---|---|
| Cairo Semaphore circuit | Identity commitment, Merkle proof, nullifier — all in STARK field |
| On-chain Merkle tree | BN254/Stark mismatch gone — tree can live on-chain |
| No trusted setup | STARKs are transparent — no ceremony, no toxic waste |
| No Garaga / snarkjs dependency | Proof generation fully in Cairo toolchain |
| Smaller calldata | ~1977 felt252s → native STARK proof format |
| Recursive proofs | Native Cairo recursion enables aggregation |

---

## Acknowledgements

- [Semaphore](https://semaphore.pse.dev/) by Privacy & Scaling Explorations — original protocol and circuits
- [Garaga](https://github.com/keep-starknet-strange/garaga) by Keep Starknet Strange — BN254 Groth16 verifier generation for Cairo
- [snarkjs](https://github.com/iden3/snarkjs) — off-chain proof generation
