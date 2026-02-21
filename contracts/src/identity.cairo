/// Identity helpers — STARK FIELD ONLY
///
/// WARNING: These functions use Poseidon over the STARK field (prime ~2^251).
/// They are INCOMPATIBLE with the identity commitments and nullifiers produced
/// by the Semaphore V4 circuit and @semaphore-protocol/identity SDK, which use
/// Poseidon over the BN254 scalar field (prime ~2^254).
///
/// These are provided as reference implementations for STARK-native identity
/// schemes. They cannot be used to reproduce or verify Semaphore V4 credentials.
use core::poseidon::PoseidonTrait;
use core::hash::HashStateTrait;

/// Generate an identity commitment from secret and nullifier
/// commitment = Poseidon(secret, nullifier)
pub fn generate_identity_commitment(secret: felt252, nullifier: felt252) -> felt252 {
    PoseidonTrait::new().update(secret).update(nullifier).finalize()
}

/// Generate a nullifier hash for a specific scope
/// nullifier_hash = Poseidon(external_nullifier, identity_nullifier)
pub fn generate_nullifier_hash(external_nullifier: felt252, identity_nullifier: felt252) -> felt252 {
    PoseidonTrait::new().update(external_nullifier).update(identity_nullifier).finalize()
}

/// Hash a signal value
/// signal_hash = Poseidon(signal)
pub fn hash_signal(signal: felt252) -> felt252 {
    PoseidonTrait::new().update(signal).finalize()
}
