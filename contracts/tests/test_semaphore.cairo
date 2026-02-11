/// Integration tests for Semaphore contract with Garaga Groth16 verifier
use starknet::ContractAddress;
use snforge_std::{declare, ContractClassTrait, DeclareResultTrait};

use semaphore::ISemaphoreDispatcher;
use semaphore::ISemaphoreDispatcherTrait;
use semaphore::ISemaphoreSafeDispatcher;
use semaphore::ISemaphoreSafeDispatcherTrait;

/// Deploy MockSemaphoreVerifier and Semaphore, returning the Semaphore contract address
fn deploy_semaphore() -> ContractAddress {
    // Deploy mock verifier first
    let verifier_class = declare("MockSemaphoreVerifier").unwrap().contract_class();
    let (verifier_address, _) = verifier_class.deploy(@ArrayTrait::new()).unwrap();

    // Deploy Semaphore with verifier address as constructor arg
    let semaphore_class = declare("Semaphore").unwrap().contract_class();
    let mut constructor_args = ArrayTrait::new();
    constructor_args.append(verifier_address.into());
    let (contract_address, _) = semaphore_class.deploy(@constructor_args).unwrap();
    contract_address
}

/// Encode 4 u256 public inputs as 8 felt252 values (low/high pairs) for mock verifier
fn build_mock_proof(merkle_root: u256, nullifier: u256, message: u256, scope: u256) -> Array<felt252> {
    let mut proof = ArrayTrait::new();
    // merkle_root
    proof.append(merkle_root.low.into());
    proof.append(merkle_root.high.into());
    // nullifier
    proof.append(nullifier.low.into());
    proof.append(nullifier.high.into());
    // message
    proof.append(message.low.into());
    proof.append(message.high.into());
    // scope
    proof.append(scope.low.into());
    proof.append(scope.high.into());
    proof
}

// ==================== Group Management Tests ====================

#[test]
fn test_create_group() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };

    let group_id: u256 = 1;
    dispatcher.create_group(group_id);

    assert(dispatcher.group_exists(group_id), 'Group should exist');
    assert(dispatcher.get_group_member_count(group_id) == 0, 'Count should be 0');
}

#[test]
fn test_create_group_sets_admin() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };

    let group_id: u256 = 1;
    dispatcher.create_group(group_id);

    let admin = dispatcher.get_group_admin(group_id);
    let zero_addr: ContractAddress = 0.try_into().unwrap();
    assert(admin != zero_addr, 'Admin should be set');
}

#[test]
fn test_create_group_initial_root_is_zero() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };

    let group_id: u256 = 1;
    dispatcher.create_group(group_id);

    let root = dispatcher.get_merkle_root(group_id);
    assert(root == 0, 'Initial root should be 0');
}

#[test]
#[feature("safe_dispatcher")]
fn test_cannot_create_duplicate_group() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };
    let safe_dispatcher = ISemaphoreSafeDispatcher { contract_address };

    let group_id: u256 = 1;
    dispatcher.create_group(group_id);

    match safe_dispatcher.create_group(group_id) {
        Result::Ok(_) => core::panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == 'Group already exists', *panic_data.at(0));
        },
    };
}

#[test]
fn test_nonexistent_group() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };

    assert(!dispatcher.group_exists(999), 'Should not exist');
}

// ==================== Member Management Tests ====================

#[test]
fn test_add_member() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };

    let group_id: u256 = 1;
    dispatcher.create_group(group_id);

    let commitment: u256 = 0xaabbccdd;
    let new_root: u256 = 0x1234567890;
    dispatcher.add_member(group_id, commitment, new_root);

    assert(dispatcher.get_group_member_count(group_id) == 1, 'Count should be 1');
    assert(dispatcher.get_merkle_root(group_id) == new_root, 'Root should be updated');
}

#[test]
fn test_add_member_changes_root() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };

    let group_id: u256 = 1;
    dispatcher.create_group(group_id);

    let initial_root = dispatcher.get_merkle_root(group_id);

    let commitment: u256 = 0xaabbccdd;
    let new_root: u256 = 0x1234567890;
    dispatcher.add_member(group_id, commitment, new_root);

    let updated_root = dispatcher.get_merkle_root(group_id);
    assert(updated_root != initial_root, 'Root should change');
    assert(updated_root == new_root, 'Root should match new_root');
}

#[test]
fn test_add_multiple_members() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };

    let group_id: u256 = 1;
    dispatcher.create_group(group_id);

    dispatcher.add_member(group_id, 0x111, 0xaaa);
    dispatcher.add_member(group_id, 0x222, 0xbbb);
    dispatcher.add_member(group_id, 0x333, 0xccc);

    assert(dispatcher.get_group_member_count(group_id) == 3, 'Count should be 3');
    assert(dispatcher.get_merkle_root(group_id) == 0xccc, 'Root should be latest');
}

#[test]
#[feature("safe_dispatcher")]
fn test_cannot_add_to_nonexistent_group() {
    let contract_address = deploy_semaphore();
    let safe_dispatcher = ISemaphoreSafeDispatcher { contract_address };

    match safe_dispatcher.add_member(999, 0xaaa, 0xbbb) {
        Result::Ok(_) => core::panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == 'Group does not exist', *panic_data.at(0));
        },
    };
}

// ==================== Signal Processing Tests ====================

#[test]
fn test_full_signal_flow() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };

    let group_id: u256 = 1;
    dispatcher.create_group(group_id);

    // Add member with a known merkle root
    let merkle_root: u256 = 0xdeadbeef;
    dispatcher.add_member(group_id, 0x111, merkle_root);

    // Build mock proof with matching merkle root
    let nullifier: u256 = 0xcafebabe;
    let message: u256 = 0x1234;
    let scope: u256 = 0x42;
    let proof = build_mock_proof(merkle_root, nullifier, message, scope);

    dispatcher.send_signal(group_id, proof.span());

    // Verify nullifier is now used
    assert(dispatcher.is_nullifier_used(nullifier), 'Nullifier should be used');
}

#[test]
#[feature("safe_dispatcher")]
fn test_double_signal_rejected() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };
    let safe_dispatcher = ISemaphoreSafeDispatcher { contract_address };

    let group_id: u256 = 1;
    dispatcher.create_group(group_id);

    let merkle_root: u256 = 0xdeadbeef;
    dispatcher.add_member(group_id, 0x111, merkle_root);

    let nullifier: u256 = 0xcafebabe;
    let message: u256 = 0x1234;
    let scope: u256 = 0x42;

    // First signal succeeds
    let proof1 = build_mock_proof(merkle_root, nullifier, message, scope);
    dispatcher.send_signal(group_id, proof1.span());

    // Second signal with same nullifier fails
    let proof2 = build_mock_proof(merkle_root, nullifier, message, scope);
    match safe_dispatcher.send_signal(group_id, proof2.span()) {
        Result::Ok(_) => core::panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == 'Nullifier already used', *panic_data.at(0));
        },
    };
}

#[test]
fn test_different_scopes_allow_resignaling() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };

    let group_id: u256 = 1;
    dispatcher.create_group(group_id);

    let merkle_root: u256 = 0xdeadbeef;
    dispatcher.add_member(group_id, 0x111, merkle_root);

    let message: u256 = 0x1234;

    // Signal with scope 1 — different nullifier
    let nullifier1: u256 = 0xaaa;
    let scope1: u256 = 0x111;
    let proof1 = build_mock_proof(merkle_root, nullifier1, message, scope1);
    dispatcher.send_signal(group_id, proof1.span());

    // Signal with scope 2 — different nullifier, should succeed
    let nullifier2: u256 = 0xbbb;
    let scope2: u256 = 0x222;
    let proof2 = build_mock_proof(merkle_root, nullifier2, message, scope2);
    dispatcher.send_signal(group_id, proof2.span());

    assert(dispatcher.is_nullifier_used(nullifier1), 'Null 1 should be used');
    assert(dispatcher.is_nullifier_used(nullifier2), 'Null 2 should be used');
}

#[test]
#[feature("safe_dispatcher")]
fn test_wrong_merkle_root_rejected() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };
    let safe_dispatcher = ISemaphoreSafeDispatcher { contract_address };

    let group_id: u256 = 1;
    dispatcher.create_group(group_id);

    let stored_root: u256 = 0xdeadbeef;
    dispatcher.add_member(group_id, 0x111, stored_root);

    // Build proof with WRONG merkle root
    let wrong_root: u256 = 0xbadbadbad;
    let proof = build_mock_proof(wrong_root, 0xcafe, 0x1234, 0x42);

    match safe_dispatcher.send_signal(group_id, proof.span()) {
        Result::Ok(_) => core::panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == 'Merkle root mismatch', *panic_data.at(0));
        },
    };
}

#[test]
#[feature("safe_dispatcher")]
fn test_invalid_proof_rejected() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };
    let safe_dispatcher = ISemaphoreSafeDispatcher { contract_address };

    let group_id: u256 = 1;
    dispatcher.create_group(group_id);
    dispatcher.add_member(group_id, 0x111, 0xdeadbeef);

    // Build malformed proof (too few elements)
    let mut bad_proof: Array<felt252> = ArrayTrait::new();
    bad_proof.append(0x1);
    bad_proof.append(0x2);

    match safe_dispatcher.send_signal(group_id, bad_proof.span()) {
        Result::Ok(_) => core::panic_with_felt252('Should have panicked'),
        Result::Err(_) => {
            // Expected — invalid proof rejected
        },
    };
}

#[test]
#[feature("safe_dispatcher")]
fn test_signal_nonexistent_group_fails() {
    let contract_address = deploy_semaphore();
    let safe_dispatcher = ISemaphoreSafeDispatcher { contract_address };

    let proof = build_mock_proof(0x1, 0x2, 0x3, 0x4);

    match safe_dispatcher.send_signal(999, proof.span()) {
        Result::Ok(_) => core::panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == 'Group does not exist', *panic_data.at(0));
        },
    };
}

#[test]
fn test_nullifier_initially_unused() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };

    assert(!dispatcher.is_nullifier_used(0xdeadbeef), 'Should be unused');
    assert(!dispatcher.is_nullifier_used(0xcafebabe), 'Should be unused');
}

#[test]
fn test_multiple_groups_independent() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };

    dispatcher.create_group(1);
    dispatcher.create_group(2);

    dispatcher.add_member(1, 0x111, 0xaaa);

    assert(dispatcher.get_group_member_count(1) == 1, 'Group 1 count wrong');
    assert(dispatcher.get_group_member_count(2) == 0, 'Group 2 count wrong');

    // Roots should differ (group 1 has custom root, group 2 has 0)
    let root1 = dispatcher.get_merkle_root(1);
    let root2 = dispatcher.get_merkle_root(2);
    assert(root1 != root2, 'Roots should differ');
}
