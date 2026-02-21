/// Poseidon Merkle tree utilities — STARK FIELD ONLY
///
/// WARNING: All hashing in this module uses Poseidon over the STARK field (prime ~2^251).
/// This is INCOMPATIBLE with the BN254-Poseidon Merkle trees used by the Semaphore V4
/// circuit and the @semaphore-protocol/group SDK (which operate over the BN254 scalar
/// field, prime ~2^254). Computing a root here and using it as a proof input will produce
/// silently wrong results — the on-chain root will not match the circuit root.
///
/// These utilities are provided for STARK-native applications only (e.g. on-chain
/// accumulators, non-Semaphore use cases). Do NOT use them to verify or reproduce
/// BN254-Poseidon Merkle proofs from the Semaphore circuit.
use core::poseidon::PoseidonTrait;
use core::hash::HashStateTrait;
use super::constants::{TREE_DEPTH, get_zero_hash};

/// Compute Poseidon hash of two field elements (STARK field — NOT BN254-compatible)
pub fn hash_pair(left: felt252, right: felt252) -> felt252 {
    PoseidonTrait::new().update(left).update(right).finalize()
}

/// Verify a Merkle proof
/// - leaf: The leaf value to verify
/// - index: The index of the leaf (determines left/right at each level)
/// - proof: Array of sibling hashes from leaf to root
/// - root: The expected Merkle root
pub fn verify_merkle_proof(
    leaf: felt252,
    index: u256,
    proof: Span<felt252>,
    root: felt252,
) -> bool {
    if proof.len() != TREE_DEPTH.into() {
        return false;
    }

    let mut current_hash = leaf;
    let mut current_index = index;
    let mut i: u32 = 0;

    loop {
        if i >= TREE_DEPTH.into() {
            break;
        }

        let sibling = *proof.at(i);

        if current_index % 2 == 0 {
            current_hash = hash_pair(current_hash, sibling);
        } else {
            current_hash = hash_pair(sibling, current_hash);
        }

        current_index = current_index / 2;
        i += 1;
    };

    current_hash == root
}

/// Compute the root of a Merkle tree from a single leaf at a given index
/// using zero values for all other positions
pub fn compute_root_from_leaf(leaf: felt252, index: u256) -> felt252 {
    let mut current_hash = leaf;
    let mut current_index = index;
    let mut level: u8 = 0;

    loop {
        if level >= TREE_DEPTH {
            break;
        }

        let sibling = get_zero_hash(level);

        if current_index % 2 == 0 {
            current_hash = hash_pair(current_hash, sibling);
        } else {
            current_hash = hash_pair(sibling, current_hash);
        }

        current_index = current_index / 2;
        level += 1;
    };

    current_hash
}
