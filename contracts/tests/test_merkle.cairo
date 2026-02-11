/// Tests for merkle module
use core::poseidon::PoseidonTrait;
use core::hash::HashStateTrait;
use semaphore::merkle::{hash_pair, verify_merkle_proof, compute_root_from_leaf};
use semaphore::constants::{TREE_DEPTH, ZERO_VALUE, get_zero_hash};

#[test]
fn test_bootstrap_zero_hashes() {
    // Compute actual Poseidon zero hashes and verify they match hardcoded values
    let mut prev = ZERO_VALUE;
    let mut level: u8 = 1;

    loop {
        if level > TREE_DEPTH {
            break;
        }

        let computed = PoseidonTrait::new().update(prev).update(prev).finalize();
        let hardcoded = get_zero_hash(level);
        assert(computed == hardcoded, 'Zero hash mismatch');
        prev = computed;
        level += 1;
    };
}

#[test]
fn test_hash_pair_consistency() {
    let a: felt252 = 0x111;
    let b: felt252 = 0x222;

    let h1 = hash_pair(a, b);
    let h2 = hash_pair(a, b);
    assert(h1 == h2, 'Hash pair not deterministic');
}

#[test]
fn test_hash_pair_order_matters() {
    let a: felt252 = 0x111;
    let b: felt252 = 0x222;

    let h1 = hash_pair(a, b);
    let h2 = hash_pair(b, a);
    assert(h1 != h2, 'Order should matter');
}

#[test]
fn test_hash_pair_matches_poseidon() {
    let a: felt252 = 0xaaa;
    let b: felt252 = 0xbbb;

    let expected = PoseidonTrait::new().update(a).update(b).finalize();
    let result = hash_pair(a, b);
    assert(result == expected, 'Should match raw Poseidon');
}

#[test]
fn test_verify_merkle_proof_single_leaf() {
    // Insert a single leaf at index 0, build proof with zero hashes
    let leaf: felt252 = 0xdeadbeef;

    // Build proof: all siblings are zero hashes
    let mut proof = ArrayTrait::new();
    let mut level: u8 = 0;
    loop {
        if level >= TREE_DEPTH {
            break;
        }
        proof.append(get_zero_hash(level));
        level += 1;
    };

    // Compute expected root
    let expected_root = compute_root_from_leaf(leaf, 0);

    assert(verify_merkle_proof(leaf, 0, proof.span(), expected_root), 'Valid proof rejected');
}

#[test]
fn test_verify_merkle_proof_wrong_root() {
    let leaf: felt252 = 0xdeadbeef;

    let mut proof = ArrayTrait::new();
    let mut level: u8 = 0;
    loop {
        if level >= TREE_DEPTH {
            break;
        }
        proof.append(get_zero_hash(level));
        level += 1;
    };

    let wrong_root: felt252 = 0x999999;
    assert(!verify_merkle_proof(leaf, 0, proof.span(), wrong_root), 'Wrong root accepted');
}

#[test]
fn test_verify_merkle_proof_wrong_leaf() {
    let leaf: felt252 = 0xdeadbeef;
    let wrong_leaf: felt252 = 0xbadbeef;

    let mut proof = ArrayTrait::new();
    let mut level: u8 = 0;
    loop {
        if level >= TREE_DEPTH {
            break;
        }
        proof.append(get_zero_hash(level));
        level += 1;
    };

    let root = compute_root_from_leaf(leaf, 0);
    assert(!verify_merkle_proof(wrong_leaf, 0, proof.span(), root), 'Wrong leaf accepted');
}

#[test]
fn test_verify_merkle_proof_wrong_index() {
    let leaf: felt252 = 0xdeadbeef;

    let mut proof = ArrayTrait::new();
    let mut level: u8 = 0;
    loop {
        if level >= TREE_DEPTH {
            break;
        }
        proof.append(get_zero_hash(level));
        level += 1;
    };

    let root = compute_root_from_leaf(leaf, 0);
    // Using index 1 instead of 0 should fail
    assert(!verify_merkle_proof(leaf, 1, proof.span(), root), 'Wrong index accepted');
}

#[test]
fn test_verify_merkle_proof_wrong_length() {
    let leaf: felt252 = 0xdeadbeef;

    // Proof with wrong length (only 5 elements instead of TREE_DEPTH)
    let mut proof = ArrayTrait::new();
    let mut i: u32 = 0;
    loop {
        if i >= 5 {
            break;
        }
        proof.append(0x0);
        i += 1;
    };

    assert(!verify_merkle_proof(leaf, 0, proof.span(), 0x0), 'Wrong length accepted');
}

#[test]
fn test_compute_root_determinism() {
    let leaf: felt252 = 0x42;
    let r1 = compute_root_from_leaf(leaf, 0);
    let r2 = compute_root_from_leaf(leaf, 0);
    assert(r1 == r2, 'Root not deterministic');
}

#[test]
fn test_different_leaves_different_roots() {
    let r1 = compute_root_from_leaf(0x111, 0);
    let r2 = compute_root_from_leaf(0x222, 0);
    assert(r1 != r2, 'Diff leaves same root');
}

#[test]
fn test_different_indices_different_roots() {
    let leaf: felt252 = 0xdeadbeef;
    let r1 = compute_root_from_leaf(leaf, 0);
    let r2 = compute_root_from_leaf(leaf, 1);
    assert(r1 != r2, 'Diff indices same root');
}

#[test]
fn test_zero_hash_chain_consistency() {
    // Verify level 0 is ZERO_VALUE
    assert(get_zero_hash(0) == ZERO_VALUE, 'Level 0 wrong');

    // Verify each level is hash of previous level with itself
    let mut level: u8 = 1;
    loop {
        if level > TREE_DEPTH {
            break;
        }
        let prev = get_zero_hash(level - 1);
        let expected = hash_pair(prev, prev);
        let actual = get_zero_hash(level);
        assert(actual == expected, 'Zero hash chain broken');
        level += 1;
    };
}
