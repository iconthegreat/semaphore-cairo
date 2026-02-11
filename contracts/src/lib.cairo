// Module declarations
pub mod constants;
pub mod identity;
pub mod merkle;
pub mod verifier;
pub mod semaphore;

// Re-export Semaphore contract interface for external use
pub use semaphore::{ISemaphore, ISemaphoreDispatcher, ISemaphoreDispatcherTrait};
pub use semaphore::{ISemaphoreSafeDispatcher, ISemaphoreSafeDispatcherTrait};

// Re-export verifier interface and dispatchers
pub use verifier::{ISemaphoreVerifier, ISemaphoreVerifierDispatcher, ISemaphoreVerifierDispatcherTrait};

// Re-export identity utilities
pub use identity::{generate_identity_commitment, generate_nullifier_hash, hash_signal};

// Re-export merkle utilities
pub use merkle::{hash_pair, verify_merkle_proof, compute_root_from_leaf};
