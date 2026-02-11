/// Semaphore Groth16 verifier interface (Garaga-compatible, Garaga-generated BN254 Groth16 verifier contract WOULD BE DEPLOYED in production).

#[starknet::interface]
pub trait ISemaphoreVerifier<TContractState> {
    fn verify_groth16_proof_bn254(
        self: @TContractState,
        full_proof_with_hints: Span<felt252>,
    ) -> Result<Span<u256>, felt252>;
}

/// Mock verifier for testing.
/// Decodes the first 8 felt252 values as 4 u256 public inputs (low/high pairs)
/// and returns them. If fewer than 8 elements are provided, returns Err.
#[starknet::contract]
pub mod MockSemaphoreVerifier {
    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl MockVerifierImpl of super::ISemaphoreVerifier<ContractState> {
        fn verify_groth16_proof_bn254(
            self: @ContractState,
            full_proof_with_hints: Span<felt252>,
        ) -> Result<Span<u256>, felt252> {
            // Require at least 8 felt252 values (4 u256 as low/high pairs)
            if full_proof_with_hints.len() < 8 {
                return Result::Err('Invalid proof');
            }

            let mut public_inputs: Array<u256> = ArrayTrait::new();

            // Decode 4 u256 values from consecutive low/high felt252 pairs
            let mut i: u32 = 0;
            loop {
                if i >= 8 {
                    break;
                }
                let low: u128 = (*full_proof_with_hints.at(i)).try_into().unwrap();
                let high: u128 = (*full_proof_with_hints.at(i + 1)).try_into().unwrap();
                public_inputs.append(u256 { low, high });
                i += 2;
            };

            Result::Ok(public_inputs.span())
        }
    }
}
