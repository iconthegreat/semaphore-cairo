/// Semaphore StarkNet contract — Real ZK privacy via Garaga Groth16
/// No private inputs on-chain. Groth16 proofs verified via external verifier contract.
/// Merkle tree managed off-chain (BN254-Poseidon). Admin submits new root when adding members.

use super::verifier::{ISemaphoreVerifierDispatcher, ISemaphoreVerifierDispatcherTrait};

#[starknet::interface]
pub trait ISemaphore<TContractState> {
    /// Create a new group (caller becomes admin)
    fn create_group(ref self: TContractState, group_id: u256);

    /// Add a member — admin submits commitment (for tracking) and new merkle root (computed off-chain)
    fn add_member(
        ref self: TContractState,
        group_id: u256,
        identity_commitment: u256,
        new_merkle_root: u256,
    );

    /// Send an anonymous signal with a Groth16 proof
    fn send_signal(
        ref self: TContractState, group_id: u256, full_proof_with_hints: Span<felt252>,
    );

    /// Get the current Merkle root for a group
    fn get_merkle_root(self: @TContractState, group_id: u256) -> u256;

    /// Check if a nullifier has been used
    fn is_nullifier_used(self: @TContractState, nullifier: u256) -> bool;

    /// Get the member count for a group
    fn get_group_member_count(self: @TContractState, group_id: u256) -> u256;

    /// Check if a group exists
    fn group_exists(self: @TContractState, group_id: u256) -> bool;

    /// Get the admin of a group
    fn get_group_admin(self: @TContractState, group_id: u256) -> starknet::ContractAddress;
}

#[starknet::contract]
pub mod Semaphore {
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_caller_address};
    use super::{ISemaphoreVerifierDispatcher, ISemaphoreVerifierDispatcherTrait};

    #[storage]
    struct Storage {
        /// Address of the Garaga Groth16 verifier contract
        verifier_address: ContractAddress,
        /// Group admin addresses
        group_admins: Map<u256, ContractAddress>,
        /// Whether a group exists
        group_exists: Map<u256, bool>,
        /// Member count per group
        member_counts: Map<u256, u256>,
        /// Current Merkle root per group (u256 for BN254 field elements)
        merkle_roots: Map<u256, u256>,
        /// Used nullifiers (global)
        used_nullifiers: Map<u256, bool>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        GroupCreated: GroupCreated,
        MemberAdded: MemberAdded,
        SignalProcessed: SignalProcessed,
    }

    #[derive(Drop, starknet::Event)]
    pub struct GroupCreated {
        #[key]
        pub group_id: u256,
        pub admin: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct MemberAdded {
        #[key]
        pub group_id: u256,
        pub identity_commitment: u256,
        pub index: u256,
        pub merkle_root: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SignalProcessed {
        #[key]
        pub group_id: u256,
        pub nullifier: u256,
        pub message: u256,
        pub scope: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState, verifier_address: ContractAddress) {
        self.verifier_address.write(verifier_address);
    }

    #[abi(embed_v0)]
    impl SemaphoreImpl of super::ISemaphore<ContractState> {
        fn create_group(ref self: ContractState, group_id: u256) {
            assert(!self.group_exists.read(group_id), 'Group already exists');

            let caller = get_caller_address();

            self.group_exists.write(group_id, true);
            self.group_admins.write(group_id, caller);
            self.member_counts.write(group_id, 0);
            // Root starts at 0 — no on-chain tree initialization needed
            self.merkle_roots.write(group_id, 0);

            self.emit(GroupCreated { group_id, admin: caller });
        }

        fn add_member(
            ref self: ContractState,
            group_id: u256,
            identity_commitment: u256,
            new_merkle_root: u256,
        ) {
            assert(self.group_exists.read(group_id), 'Group does not exist');

            let caller = get_caller_address();
            let admin = self.group_admins.read(group_id);
            assert(caller == admin, 'Only admin can add members');

            let index = self.member_counts.read(group_id);

            // Update root to admin-provided value (computed off-chain with BN254-Poseidon)
            self.merkle_roots.write(group_id, new_merkle_root);

            // Increment member count
            self.member_counts.write(group_id, index + 1);

            self
                .emit(
                    MemberAdded {
                        group_id, identity_commitment, index, merkle_root: new_merkle_root,
                    },
                );
        }

        fn send_signal(
            ref self: ContractState, group_id: u256, full_proof_with_hints: Span<felt252>,
        ) {
            assert(self.group_exists.read(group_id), 'Group does not exist');

            // Verify proof via Garaga verifier contract
            let verifier = ISemaphoreVerifierDispatcher {
                contract_address: self.verifier_address.read(),
            };

            let public_inputs = match verifier
                .verify_groth16_proof_bn254(full_proof_with_hints) {
                Result::Ok(inputs) => inputs,
                Result::Err(_) => { panic!("Invalid proof") },
            };

            // Extract 4 public inputs from verified proof
            assert(public_inputs.len() >= 4, 'Not enough public inputs');
            let merkle_root = *public_inputs.at(0);
            let nullifier = *public_inputs.at(1);
            let message = *public_inputs.at(2);
            let scope = *public_inputs.at(3);

            // Verify merkle root matches group's stored root
            let stored_root = self.merkle_roots.read(group_id);
            assert(merkle_root == stored_root, 'Merkle root mismatch');

            // Verify nullifier not already used
            assert(!self.used_nullifiers.read(nullifier), 'Nullifier already used');

            // Mark nullifier as used
            self.used_nullifiers.write(nullifier, true);

            // Emit event
            self.emit(SignalProcessed { group_id, nullifier, message, scope });
        }

        fn get_merkle_root(self: @ContractState, group_id: u256) -> u256 {
            self.merkle_roots.read(group_id)
        }

        fn is_nullifier_used(self: @ContractState, nullifier: u256) -> bool {
            self.used_nullifiers.read(nullifier)
        }

        fn get_group_member_count(self: @ContractState, group_id: u256) -> u256 {
            self.member_counts.read(group_id)
        }

        fn group_exists(self: @ContractState, group_id: u256) -> bool {
            self.group_exists.read(group_id)
        }

        fn get_group_admin(self: @ContractState, group_id: u256) -> ContractAddress {
            self.group_admins.read(group_id)
        }
    }
}
