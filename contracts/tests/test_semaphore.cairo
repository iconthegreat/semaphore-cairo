/// Integration tests for Semaphore contract with Garaga Groth16 verifier
use starknet::ContractAddress;
use snforge_std::{declare, ContractClassTrait, DeclareResultTrait, start_cheat_caller_address, stop_cheat_caller_address};

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

// ==================== Root History Tests ====================

#[test]
fn test_old_root_valid_after_new_member() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };

    let group_id: u256 = 1;
    dispatcher.create_group(group_id);

    // Add first member with root_a
    let root_a: u256 = 0xaaa;
    dispatcher.add_member(group_id, 0x111, root_a);

    // Add second member with root_b — root_a should still be valid
    let root_b: u256 = 0xbbb;
    dispatcher.add_member(group_id, 0x222, root_b);

    assert(dispatcher.is_valid_root(group_id, root_a), 'Old root should be valid');
    assert(dispatcher.is_valid_root(group_id, root_b), 'New root should be valid');
}

#[test]
fn test_signal_with_old_root_succeeds() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };

    let group_id: u256 = 1;
    dispatcher.create_group(group_id);

    // Add first member — proof generated against this root
    let root_a: u256 = 0xaaa;
    dispatcher.add_member(group_id, 0x111, root_a);

    // Add second member — root changes to root_b
    let root_b: u256 = 0xbbb;
    dispatcher.add_member(group_id, 0x222, root_b);

    // Signal with proof referencing root_a should still work
    let nullifier: u256 = 0xcafe;
    let proof = build_mock_proof(root_a, nullifier, 0x1234, 0x42);
    dispatcher.send_signal(group_id, proof.span());

    assert(dispatcher.is_nullifier_used(nullifier), 'Nullifier should be used');
}

#[test]
fn test_root_outside_history_window_rejected() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };

    let group_id: u256 = 1;
    dispatcher.create_group(group_id);

    // Add first member with root_old
    let root_old: u256 = 0xfade;
    dispatcher.add_member(group_id, 0x001, root_old);

    // Add 20 more members to push root_old out of the ring buffer (size = 20)
    let mut i: u256 = 1;
    loop {
        if i > 20 {
            break;
        }
        dispatcher.add_member(group_id, 0x100 + i, 0x1000 + i);
        i += 1;
    };

    // root_old should no longer be valid (pushed out of ring buffer)
    assert(!dispatcher.is_valid_root(group_id, root_old), 'Old root should be expired');

    // Latest root should still be valid
    let latest: u256 = 0x1000 + 20;
    assert(dispatcher.is_valid_root(group_id, latest), 'Latest root should be valid');
}

#[test]
fn test_is_valid_root_nonexistent_root() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };

    let group_id: u256 = 1;
    dispatcher.create_group(group_id);
    dispatcher.add_member(group_id, 0x111, 0xaaa);

    // Random root that was never added should be invalid
    assert(!dispatcher.is_valid_root(group_id, 0xdeadbeef), 'Unknown root should be invalid');
}

#[test]
fn test_root_history_independent_between_groups() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };

    dispatcher.create_group(1);
    dispatcher.create_group(2);

    dispatcher.add_member(1, 0x111, 0xaaa);
    dispatcher.add_member(2, 0x222, 0xbbb);

    // Group 1's root should not be valid for group 2
    assert(dispatcher.is_valid_root(1, 0xaaa), 'Group 1 root should be valid');
    assert(!dispatcher.is_valid_root(2, 0xaaa), 'Group 1 root invalid for grp 2');
    assert(dispatcher.is_valid_root(2, 0xbbb), 'Group 2 root should be valid');
}

// ==================== Member Removal Tests ====================

#[test]
fn test_remove_member() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };

    let group_id: u256 = 1;
    dispatcher.create_group(group_id);

    let commitment: u256 = 0xaabbccdd;
    let root_after_add: u256 = 0x1234567890;
    dispatcher.add_member(group_id, commitment, root_after_add);

    let root_after_remove: u256 = 0x9876543210;
    dispatcher.remove_member(group_id, commitment, root_after_remove);

    assert(dispatcher.get_merkle_root(group_id) == root_after_remove, 'Root should update on remove');
}

#[test]
fn test_remove_member_decrements_count() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };

    let group_id: u256 = 1;
    dispatcher.create_group(group_id);

    dispatcher.add_member(group_id, 0x111, 0xaaa);
    dispatcher.add_member(group_id, 0x222, 0xbbb);
    assert(dispatcher.get_group_member_count(group_id) == 2, 'Count should be 2');

    dispatcher.remove_member(group_id, 0x111, 0xccc);
    assert(dispatcher.get_group_member_count(group_id) == 1, 'Count should be 1');
}

#[test]
fn test_remove_member_root_in_history() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };

    let group_id: u256 = 1;
    dispatcher.create_group(group_id);

    let root_after_add: u256 = 0xaaa;
    dispatcher.add_member(group_id, 0x111, root_after_add);

    let root_after_remove: u256 = 0xbbb;
    dispatcher.remove_member(group_id, 0x111, root_after_remove);

    // Both roots should be valid in history
    assert(dispatcher.is_valid_root(group_id, root_after_add), 'Add root should be in history');
    assert(dispatcher.is_valid_root(group_id, root_after_remove), 'Remove root should be valid');
}

#[test]
#[feature("safe_dispatcher")]
fn test_cannot_remove_from_empty_group() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };
    let safe_dispatcher = ISemaphoreSafeDispatcher { contract_address };

    let group_id: u256 = 1;
    dispatcher.create_group(group_id);

    match safe_dispatcher.remove_member(group_id, 0x111, 0xaaa) {
        Result::Ok(_) => core::panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == 'Group has no members', *panic_data.at(0));
        },
    };
}

#[test]
#[feature("safe_dispatcher")]
fn test_cannot_remove_from_nonexistent_group() {
    let contract_address = deploy_semaphore();
    let safe_dispatcher = ISemaphoreSafeDispatcher { contract_address };

    match safe_dispatcher.remove_member(999, 0x111, 0xaaa) {
        Result::Ok(_) => core::panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == 'Group does not exist', *panic_data.at(0));
        },
    };
}

#[test]
#[feature("safe_dispatcher")]
fn test_only_admin_can_remove() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };
    let safe_dispatcher = ISemaphoreSafeDispatcher { contract_address };

    let group_id: u256 = 1;
    dispatcher.create_group(group_id);
    dispatcher.add_member(group_id, 0x111, 0xaaa);

    // Cheat caller to a non-admin address
    let non_admin: ContractAddress = 0x999.try_into().unwrap();
    start_cheat_caller_address(contract_address, non_admin);

    match safe_dispatcher.remove_member(group_id, 0x111, 0xbbb) {
        Result::Ok(_) => core::panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == 'Only admin can remove members', *panic_data.at(0));
        },
    };

    stop_cheat_caller_address(contract_address);
}

#[test]
fn test_signal_after_remove() {
    let contract_address = deploy_semaphore();
    let dispatcher = ISemaphoreDispatcher { contract_address };

    let group_id: u256 = 1;
    dispatcher.create_group(group_id);

    // Add two members
    let root_1: u256 = 0xaaa;
    dispatcher.add_member(group_id, 0x111, root_1);
    let root_2: u256 = 0xbbb;
    dispatcher.add_member(group_id, 0x222, root_2);

    // Remove first member
    let root_after_remove: u256 = 0xccc;
    dispatcher.remove_member(group_id, 0x111, root_after_remove);

    // Signal with the post-removal root should work
    let nullifier: u256 = 0xddd;
    let proof = build_mock_proof(root_after_remove, nullifier, 0x1234, 0x42);
    dispatcher.send_signal(group_id, proof.span());

    assert(dispatcher.is_nullifier_used(nullifier), 'Nullifier should be used');
}
