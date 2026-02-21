/// Semaphore StarkNet contract — Real ZK privacy via Garaga Groth16
/// No private inputs on-chain. Groth16 proofs verified via external verifier contract.
/// Merkle tree managed off-chain (BN254-Poseidon). Admin submits new root when adding members.

use super::verifier::{ISemaphoreVerifierDispatcher, ISemaphoreVerifierDispatcherTrait};

/// Default root history ring buffer size (used when constructor arg is 0)
pub const DEFAULT_ROOT_HISTORY_SIZE: u8 = 100;

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

    /// Remove a member — admin submits commitment and new merkle root (computed off-chain after zeroing leaf)
    fn remove_member(
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

    /// Check if a root is valid (present in the root history) for a group
    fn is_valid_root(self: @TContractState, group_id: u256, root: u256) -> bool;

    /// Propose a new admin for a group (two-step transfer — proposed admin must call accept_admin)
    fn transfer_admin(
        ref self: TContractState, group_id: u256, proposed_admin: starknet::ContractAddress,
    );

    /// Accept an in-progress admin transfer (caller must be the proposed admin)
    fn accept_admin(ref self: TContractState, group_id: u256);

    /// Get the pending admin for a group (zero address if no transfer in progress)
    fn get_pending_admin(self: @TContractState, group_id: u256) -> starknet::ContractAddress;
}

#[starknet::contract]
pub mod Semaphore {
    use core::poseidon::PoseidonTrait;
    use core::hash::HashStateTrait;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_caller_address};
    use super::{ISemaphoreVerifierDispatcher, ISemaphoreVerifierDispatcherTrait};
    use super::DEFAULT_ROOT_HISTORY_SIZE;

    #[storage]
    struct Storage {
        /// Address of the Garaga Groth16 verifier contract
        verifier_address: ContractAddress,
        /// Root history ring buffer size (set at construction, applies to all groups)
        root_history_size: u8,
        /// Group admin addresses
        group_admins: Map<u256, ContractAddress>,
        /// Pending admin during a two-step admin transfer
        pending_admins: Map<u256, ContractAddress>,
        /// Whether a group exists
        group_exists: Map<u256, bool>,
        /// Member count per group
        member_counts: Map<u256, u256>,
        /// Current Merkle root per group (u256 for BN254 field elements)
        merkle_roots: Map<u256, u256>,
        /// Used nullifiers (global)
        used_nullifiers: Map<u256, bool>,
        /// Ring buffer of recent roots per group: composite_key(group_id, index) -> root
        root_history: Map<felt252, u256>,
        /// Current write index in the ring buffer per group
        root_history_index: Map<u256, u8>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        GroupCreated: GroupCreated,
        MemberAdded: MemberAdded,
        MemberRemoved: MemberRemoved,
        SignalProcessed: SignalProcessed,
        AdminTransferProposed: AdminTransferProposed,
        AdminTransferAccepted: AdminTransferAccepted,
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
    pub struct MemberRemoved {
        #[key]
        pub group_id: u256,
        pub identity_commitment: u256,
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

    #[derive(Drop, starknet::Event)]
    pub struct AdminTransferProposed {
        #[key]
        pub group_id: u256,
        pub current_admin: ContractAddress,
        pub proposed_admin: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AdminTransferAccepted {
        #[key]
        pub group_id: u256,
        pub new_admin: ContractAddress,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        verifier_address: ContractAddress,
        root_history_size: u8,
    ) {
        self.verifier_address.write(verifier_address);
        let size = if root_history_size == 0 { DEFAULT_ROOT_HISTORY_SIZE } else { root_history_size };
        self.root_history_size.write(size);
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

            // Update latest root
            self.merkle_roots.write(group_id, new_merkle_root);

            // Write new root to ring buffer
            let history_idx = self.root_history_index.read(group_id);
            let key = composite_root_key(group_id, history_idx);
            self.root_history.write(key, new_merkle_root);
            // Advance ring buffer index (mod root_history_size)
            let rhs = self.root_history_size.read();
            let next_idx = (history_idx + 1) % rhs;
            self.root_history_index.write(group_id, next_idx);

            // Increment member count
            self.member_counts.write(group_id, index + 1);

            self
                .emit(
                    MemberAdded {
                        group_id, identity_commitment, index, merkle_root: new_merkle_root,
                    },
                );
        }

        fn remove_member(
            ref self: ContractState,
            group_id: u256,
            identity_commitment: u256,
            new_merkle_root: u256,
        ) {
            assert(self.group_exists.read(group_id), 'Group does not exist');

            let caller = get_caller_address();
            let admin = self.group_admins.read(group_id);
            assert(caller == admin, 'Only admin can remove members');

            let count = self.member_counts.read(group_id);
            assert(count > 0, 'Group has no members');

            // Update latest root
            self.merkle_roots.write(group_id, new_merkle_root);

            // Write new root to ring buffer
            let history_idx = self.root_history_index.read(group_id);
            let key = composite_root_key(group_id, history_idx);
            self.root_history.write(key, new_merkle_root);
            // Advance ring buffer index (mod root_history_size)
            let rhs = self.root_history_size.read();
            let next_idx = (history_idx + 1) % rhs;
            self.root_history_index.write(group_id, next_idx);

            // Decrement member count
            self.member_counts.write(group_id, count - 1);

            self
                .emit(
                    MemberRemoved {
                        group_id, identity_commitment, merkle_root: new_merkle_root,
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

            // Verify merkle root matches any root in the group's history
            assert(check_root_history(@self, group_id, merkle_root), 'Merkle root mismatch');

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

        fn is_valid_root(self: @ContractState, group_id: u256, root: u256) -> bool {
            check_root_history(self, group_id, root)
        }

        fn transfer_admin(
            ref self: ContractState, group_id: u256, proposed_admin: ContractAddress,
        ) {
            assert(self.group_exists.read(group_id), 'Group does not exist');
            let caller = get_caller_address();
            let admin = self.group_admins.read(group_id);
            assert(caller == admin, 'Only admin can transfer');

            self.pending_admins.write(group_id, proposed_admin);
            self.emit(AdminTransferProposed { group_id, current_admin: caller, proposed_admin });
        }

        fn accept_admin(ref self: ContractState, group_id: u256) {
            assert(self.group_exists.read(group_id), 'Group does not exist');
            let caller = get_caller_address();
            let pending = self.pending_admins.read(group_id);
            let zero_addr: ContractAddress = 0.try_into().unwrap();
            assert(pending != zero_addr, 'No pending admin transfer');
            assert(caller == pending, 'Only pending admin can accept');

            self.group_admins.write(group_id, caller);
            self.pending_admins.write(group_id, zero_addr);
            self.emit(AdminTransferAccepted { group_id, new_admin: caller });
        }

        fn get_pending_admin(self: @ContractState, group_id: u256) -> ContractAddress {
            self.pending_admins.read(group_id)
        }
    }

    /// Check if a root is in the group's root history or is the current root
    fn check_root_history(self: @ContractState, group_id: u256, root: u256) -> bool {
        // Check latest root first (fast path)
        if root == self.merkle_roots.read(group_id) {
            return true;
        }
        // Search ring buffer
        let rhs = self.root_history_size.read();
        let mut i: u8 = 0;
        loop {
            if i >= rhs {
                break false;
            }
            let key = composite_root_key(group_id, i);
            let stored = self.root_history.read(key);
            if stored == root && stored != 0 {
                break true;
            }
            i += 1;
        }
    }

    /// Compute a composite storage key from group_id and ring buffer index
    fn composite_root_key(group_id: u256, index: u8) -> felt252 {
        PoseidonTrait::new()
            .update(group_id.low.into())
            .update(group_id.high.into())
            .update(index.into())
            .finalize()
    }
}
