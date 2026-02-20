export const RPC_URL =
  process.env.STARKNET_RPC_URL || "https://api.cartridge.gg/x/starknet/sepolia";

export const SEMAPHORE_ADDRESS =
  "0x0002e2b414c453ee2c862d8f9d06fac9817dfff8afe2bde8ba60ddb75585a37b";

export const DEPLOYER_ADDRESS =
  "0x5c82627c80815b4760d9e227103a639574905768c8913db7717b6609e367204";

export const DEPLOYER_PRIVATE_KEY =
  process.env.DEPLOYER_PRIVATE_KEY ||
  "0x6cf50c95db36ebf25bd2e0e04be6499fea84e3b71ac058706ceded32accafb6";

export const GROUP_ID = 42n;
export const SCOPE = 1n;
export const VOTE_QUESTION = "Should Semaphore deploy to StarkNet mainnet?";

// Block at which the Semaphore contract was deployed (~Feb 2026 Sepolia).
// Used as from_block for event queries to avoid paging through 6M+ empty blocks.
export const DEPLOY_BLOCK = 6_700_900;
