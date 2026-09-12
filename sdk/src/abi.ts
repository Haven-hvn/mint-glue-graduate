import factory from "./abi/RoyaltyRouterFactory.js";
import router from "./abi/RoyaltyRouter.js";
import bond from "./abi/IMintClubBond.js";
import hook from "./abi/IGlueHookMin.js";
import type { Abi } from "viem";

export const factoryAbi = factory as unknown as Abi;
export const routerAbi = router as unknown as Abi;
export const bondAbi = [
  ...bond,
  // not in the Solidity interface the contracts use, but handy for pre-flight checks
  { type: "function", name: "exists", stateMutability: "view", inputs: [{ name: "token", type: "address" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "getSteps", stateMutability: "view", inputs: [{ name: "token", type: "address" }], outputs: [{ type: "tuple[]", components: [{ name: "rangeTo", type: "uint128" }, { name: "price", type: "uint128" }] }] },
] as unknown as Abi;
export const poolManagerAbi = [
  { type: "function", name: "extsload", stateMutability: "view", inputs: [{ name: "slot", type: "bytes32" }], outputs: [{ type: "bytes32" }] },
] as const satisfies Abi;
export const hookAbi = hook as unknown as Abi;

export const erc20Abi = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ name: "a", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "allowance", stateMutability: "view", inputs: [{ name: "o", type: "address" }, { name: "s", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "approve", stateMutability: "nonpayable", inputs: [{ name: "s", type: "address" }, { name: "a", type: "uint256" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
  { type: "function", name: "totalSupply", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const satisfies Abi;
