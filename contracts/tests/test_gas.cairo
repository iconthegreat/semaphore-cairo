/// Gas benchmark tests for Semaphore contract operations.
///
/// These tests use the MockSemaphoreVerifier (no actual Groth16 pairing).
/// They measure contract logic gas only — not the BN254 pairing cost.
///
/// ## How to measure gas
///
/// Run: `snforge test test_gas --detailed`
///
/// The `--detailed` flag prints gas consumption per test. Look for the
/// `gas_used` field in the output for each test below.
///
/// ## Measured gas (mock verifier, snforge 0.55.0)
///
/// | Operation                     | l2_gas (approx) | l1_data_gas |
/// |-------------------------------|-----------------|-------------|
/// | create_group()                | ~671k           | ~576        |
/// | add_member()                  | ~1.1M           | ~960        |
/// | send_signal() (mock, 1 root)  | ~1.6M           | ~1056       |
/// | send_signal() (mock, 50 roots)| ~23M            | ~5760       |
///
/// ## Known real-verifier gas (Sepolia, garaga==1.0.1, depth-20 VK)
///
/// The full `send_signal()` with BN254 pairing verification costs significantly
/// more than the mock path due to ECIP syscall overhead. Measured on Sepolia
/// (testnet, block ~6.7M), the total transaction fee for `send_signal()` was
/// approximately 0.0005–0.002 STRK depending on network congestion.

use starknet::ContractAddress;
use snforge_std::{declare, ContractClassTrait, DeclareResultTrait};

use semaphore::ISemaphoreDispatcher;
use semaphore::ISemaphoreDispatcherTrait;

fn deploy_semaphore_bench() -> ContractAddress {
    let verifier_class = declare("MockSemaphoreVerifier").unwrap().contract_class();
    let (verifier_address, _) = verifier_class.deploy(@ArrayTrait::new()).unwrap();

    let semaphore_class = declare("Semaphore").unwrap().contract_class();
    let mut constructor_args = ArrayTrait::new();
    constructor_args.append(verifier_address.into());
    constructor_args.append(100); // root_history_size
    let (contract_address, _) = semaphore_class.deploy(@constructor_args).unwrap();
    contract_address
}

fn build_mock_proof_bench(
    merkle_root: u256, nullifier: u256, message: u256, scope: u256,
) -> Array<felt252> {
    let mut proof = ArrayTrait::new();
    proof.append(merkle_root.low.into());
    proof.append(merkle_root.high.into());
    proof.append(nullifier.low.into());
    proof.append(nullifier.high.into());
    proof.append(message.low.into());
    proof.append(message.high.into());
    proof.append(scope.low.into());
    proof.append(scope.high.into());
    proof
}

/// Benchmark: create_group() gas cost (contract logic only)
#[test]
fn bench_create_group() {
    let contract_address = deploy_semaphore_bench();
    let dispatcher = ISemaphoreDispatcher { contract_address };
    dispatcher.create_group(1);
}

/// Benchmark: add_member() gas cost (contract logic only)
#[test]
fn bench_add_member() {
    let contract_address = deploy_semaphore_bench();
    let dispatcher = ISemaphoreDispatcher { contract_address };
    dispatcher.create_group(1);
    dispatcher.add_member(1, 0xdeadbeef, 0xcafebabe);
}

/// Benchmark: send_signal() gas cost via MockVerifier (no BN254 pairing)
///
/// This measures contract logic: root history lookup, nullifier check, storage write.
/// The real verifier adds ~150k–500k additional gas for the BN254 pairing.
#[test]
fn bench_send_signal_mock() {
    let contract_address = deploy_semaphore_bench();
    let dispatcher = ISemaphoreDispatcher { contract_address };
    dispatcher.create_group(1);
    dispatcher.add_member(1, 0x111, 0xabcdef);

    let proof = build_mock_proof_bench(0xabcdef, 0xdeadbeef, 0x1, 0x2);
    dispatcher.send_signal(1, proof.span());
}

/// Benchmark: send_signal() with 50 members in history (ring buffer near capacity)
///
/// Measures root history scan cost as the ring buffer fills up.
/// With root_history_size=100, this exercises ~50% of the buffer.
#[test]
fn bench_send_signal_large_history() {
    let contract_address = deploy_semaphore_bench();
    let dispatcher = ISemaphoreDispatcher { contract_address };
    dispatcher.create_group(1);

    // Add 50 members to populate the root history ring buffer
    let mut i: u256 = 0;
    loop {
        if i >= 50 {
            break;
        }
        dispatcher.add_member(1, 0x1000 + i, 0x2000 + i);
        i += 1;
    };

    // Signal against an older root (not the latest) — worst-case scan path
    let old_root: u256 = 0x2010; // root after 16th member
    let proof = build_mock_proof_bench(old_root, 0xdeadbeef, 0x1, 0x2);
    dispatcher.send_signal(1, proof.span());
}
