import type { Address, Hex, PublicClient } from "viem";
import { hookAbi, factoryAbi } from "./abi.js";
import type { Deployment } from "./addresses.js";

export const pot = (client: PublicClient, d: Deployment, poolId: Hex) =>
  client.readContract({ address: d.hook, abi: hookAbi, functionName: "potOf", args: [poolId] }) as Promise<{ admin: Address; main: Address; secondary: Address; recipient: Address; configured: boolean; balance: bigint }>;

export const program = (client: PublicClient, d: Deployment, poolId: Hex) =>
  client.readContract({ address: d.hook, abi: hookAbi, functionName: "programOf", args: [poolId] }) as Promise<Record<string, unknown>>;

export const feeInfo = async (client: PublicClient, d: Deployment) => {
  const [dao, bps] = (await client.readContract({ address: d.factory!, abi: factoryAbi, functionName: "feeInfo" })) as [Address, number];
  const max = (await client.readContract({ address: d.factory!, abi: factoryAbi, functionName: "MAX_DAO_BPS" })) as number;
  return { dao, daoBps: Number(bps), maxDaoBps: Number(max) };
};
