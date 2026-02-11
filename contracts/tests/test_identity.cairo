/// Tests for identity module
use semaphore::identity::{generate_identity_commitment, generate_nullifier_hash, hash_signal};

#[test]
fn test_commitment_determinism() {
    let secret: felt252 = 0xdeadbeef;
    let nullifier: felt252 = 0xcafebabe;

    let c1 = generate_identity_commitment(secret, nullifier);
    let c2 = generate_identity_commitment(secret, nullifier);
    assert(c1 == c2, 'Commitment not deterministic');
}

#[test]
fn test_commitment_uniqueness() {
    let c1 = generate_identity_commitment(0x111, 0x222);
    let c2 = generate_identity_commitment(0x111, 0x333);
    let c3 = generate_identity_commitment(0x222, 0x222);

    assert(c1 != c2, 'Same secret diff null');
    assert(c1 != c3, 'Diff secret same null');
    assert(c2 != c3, 'Both different');
}

#[test]
fn test_commitment_order_sensitivity() {
    // Poseidon(a, b) != Poseidon(b, a)
    let c1 = generate_identity_commitment(0xaaa, 0xbbb);
    let c2 = generate_identity_commitment(0xbbb, 0xaaa);
    assert(c1 != c2, 'Order should matter');
}

#[test]
fn test_nullifier_hash_determinism() {
    let ext: felt252 = 0x123;
    let id_null: felt252 = 0x456;

    let h1 = generate_nullifier_hash(ext, id_null);
    let h2 = generate_nullifier_hash(ext, id_null);
    assert(h1 == h2, 'Null hash not deterministic');
}

#[test]
fn test_nullifier_hash_uniqueness() {
    let h1 = generate_nullifier_hash(0x111, 0x222);
    let h2 = generate_nullifier_hash(0x111, 0x333);
    let h3 = generate_nullifier_hash(0x222, 0x222);

    assert(h1 != h2, 'Same ext diff null');
    assert(h1 != h3, 'Diff ext same null');
}

#[test]
fn test_different_external_nullifiers_produce_different_hashes() {
    // Core Semaphore property: same identity, different scopes = different nullifier hashes
    let id_null: felt252 = 0xabcdef;
    let ext1: felt252 = 0x111;
    let ext2: felt252 = 0x222;

    let h1 = generate_nullifier_hash(ext1, id_null);
    let h2 = generate_nullifier_hash(ext2, id_null);
    assert(h1 != h2, 'Diff scope should diff hash');
}

#[test]
fn test_hash_signal_determinism() {
    let s1 = hash_signal(0x42);
    let s2 = hash_signal(0x42);
    assert(s1 == s2, 'Signal hash not deterministic');
}

#[test]
fn test_hash_signal_uniqueness() {
    let s1 = hash_signal(0x42);
    let s2 = hash_signal(0x43);
    assert(s1 != s2, 'Diff signals same hash');
}

#[test]
fn test_hash_signal_nonzero() {
    // Verify that hashing a non-zero signal produces non-zero result
    let s = hash_signal(0x1);
    assert(s != 0, 'Signal hash should be nonzero');
}

#[test]
fn test_commitment_and_nullifier_differ() {
    // Commitment and nullifier hash use same inputs but should produce different outputs
    // because they hash different pairs
    let secret: felt252 = 0xaaa;
    let nullifier: felt252 = 0xbbb;
    let ext: felt252 = 0xccc;

    let commitment = generate_identity_commitment(secret, nullifier);
    let null_hash = generate_nullifier_hash(ext, nullifier);
    assert(commitment != null_hash, 'Should differ');
}
