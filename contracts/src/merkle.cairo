/// Poseidon Merkle tree utilities
use core::poseidon::PoseidonTrait;
use core::hash::HashStateTrait;
use super::constants::{TREE_DEPTH, get_zero_hash};

/// Compute Poseidon hash of two field elements
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
