import type { Address } from "viem";

export interface Deployment {
  bond: Address; // mint.club MCV2_Bond
  bondTokenImplementation: Address; // MCV2_Token clone target (for off-chain token address prediction)
  hook: Address; // GlueHook (same on every chain)
  poolManager: Address; // Uniswap V4 PoolManager
  wnative: Address;
  factory?: Address; // RoyaltyRouterFactory, once deployed
}

export const GLUE_HOOK: Address = "0x0F41715dc432692b66A5aDF8dCfef6Ac407b20c8";

export const deployments: Record<number, Deployment> = {
  8453: {
    bond: "0xc5a076cad94176c2996B32d8466Be1cE757FAa27",
    bondTokenImplementation: "0xAa70bC79fD1cB4a6FBA717018351F0C3c64B79Df",
    hook: GLUE_HOOK,
    poolManager: "0x498581fF718922c3f8e6A244956aF099B2652b2b",
    wnative: "0x4200000000000000000000000000000000000006",
  },
};

export const ZERO: Address = "0x0000000000000000000000000000000000000000";
