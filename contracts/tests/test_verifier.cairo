/// Tests for MockSemaphoreVerifier
use starknet::ContractAddress;
use snforge_std::{declare, ContractClassTrait, DeclareResultTrait};

use semaphore::ISemaphoreVerifierDispatcher;
use semaphore::ISemaphoreVerifierDispatcherTrait;

fn deploy_mock_verifier() -> ContractAddress {
    let contract = declare("MockSemaphoreVerifier").unwrap().contract_class();
    let (contract_address, _) = contract.deploy(@ArrayTrait::new()).unwrap();
    contract_address
}

#[test]
fn test_mock_verifier_decodes_valid_proof() {
    let contract_address = deploy_mock_verifier();
    let dispatcher = ISemaphoreVerifierDispatcher { contract_address };

    // Encode 4 u256 values as 8 felt252 (low/high pairs)
    let merkle_root: u256 = 0xdeadbeef;
    let nullifier: u256 = 0xcafebabe;
    let message: u256 = 0x1234;
    let scope: u256 = 0x42;

    let mut proof: Array<felt252> = ArrayTrait::new();
    proof.append(merkle_root.low.into());
    proof.append(merkle_root.high.into());
    proof.append(nullifier.low.into());
    proof.append(nullifier.high.into());
    proof.append(message.low.into());
    proof.append(message.high.into());
    proof.append(scope.low.into());
    proof.append(scope.high.into());

    let result = dispatcher.verify_groth16_proof_bn254(proof.span());
    match result {
        Result::Ok(public_inputs) => {
            assert(public_inputs.len() == 4, 'Should have 4 inputs');
            assert(*public_inputs.at(0) == merkle_root, 'Wrong merkle_root');
            assert(*public_inputs.at(1) == nullifier, 'Wrong nullifier');
            assert(*public_inputs.at(2) == message, 'Wrong message');
            assert(*public_inputs.at(3) == scope, 'Wrong scope');
        },
        Result::Err(_) => {
            core::panic_with_felt252('Should not fail');
        },
    };
}

#[test]
fn test_mock_verifier_rejects_malformed_proof() {
    let contract_address = deploy_mock_verifier();
    let dispatcher = ISemaphoreVerifierDispatcher { contract_address };

    // Only 2 elements — too few for 4 u256 values
    let mut bad_proof: Array<felt252> = ArrayTrait::new();
    bad_proof.append(0x1);
    bad_proof.append(0x2);

    let result = dispatcher.verify_groth16_proof_bn254(bad_proof.span());
    match result {
        Result::Ok(_) => {
            core::panic_with_felt252('Should have failed');
        },
        Result::Err(err) => {
            assert(err == 'Invalid proof', 'Wrong error message');
        },
    };
}

#[test]
fn test_mock_verifier_large_u256_values() {
    let contract_address = deploy_mock_verifier();
    let dispatcher = ISemaphoreVerifierDispatcher { contract_address };

    // Test with values that have both low and high parts set
    let val: u256 = u256 { low: 0xffffffffffffffffffffffffffffffff, high: 0xabcdef };

    let mut proof: Array<felt252> = ArrayTrait::new();
    // 4 copies of the same value
    let mut i: u32 = 0;
    loop {
        if i >= 4 {
            break;
        }
        proof.append(val.low.into());
        proof.append(val.high.into());
        i += 1;
    };

    let result = dispatcher.verify_groth16_proof_bn254(proof.span());
    match result {
        Result::Ok(public_inputs) => {
            assert(*public_inputs.at(0) == val, 'Wrong decoded value');
            assert(*public_inputs.at(3) == val, 'Wrong decoded value 4');
        },
        Result::Err(_) => {
            core::panic_with_felt252('Should not fail');
        },
    };
}
