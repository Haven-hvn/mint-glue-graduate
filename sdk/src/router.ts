import type { Address, PublicClient, WalletClient } from "viem";
import { routerAbi } from "./abi.js";

export interface RouterStatus {
  pending: bigint; minClaim: bigint; reserve: Address; secondary: Address; token: Address; bountyBps: number; ready: boolean;
  lastActive: number; reclaimAt: number; stalePeriod: number; gracePeriod: number; staleAt: number; // unix seconds
}

export async function routerStatus(client: PublicClient, router: Address): Promise<RouterStatus> {
  const rd = (fn: string) => client.readContract({ address: router, abi: routerAbi, functionName: fn });
  const [pending, minClaim, reserve, secondary, token, bountyBps, lastActive, reclaimAt, stale, grace] = await Promise.all([
    rd("pending"), rd("MIN_CLAIM"), rd("RESERVE"), rd("SECONDARY"), rd("TOKEN"), rd("BOUNTY_BPS"), rd("lastActive"), rd("reclaimAt"), rd("STALE_PERIOD"), rd("GRACE_PERIOD"),
  ]) as [bigint, bigint, Address, Address, Address, number, bigint, bigint, bigint, bigint];
  return {
    pending, minClaim, reserve, secondary, token, bountyBps: Number(bountyBps), ready: pending > 0n && pending >= minClaim,
    lastActive: Number(lastActive), reclaimAt: Number(reclaimAt), stalePeriod: Number(stale), gracePeriod: Number(grace), staleAt: Number(lastActive) + Number(stale),
  };
}

/** Permissionless: stamps activity if the token traded anywhere. Keepers should call it when a sweep isn't due. */
export async function heartbeat(client: PublicClient, wallet: WalletClient, router: Address) {
  const hash = await wallet.writeContract({ address: router, abi: routerAbi, functionName: "heartbeat", account: wallet.account!, chain: wallet.chain });
  return client.waitForTransactionReceipt({ hash });
}

/** Bounty the keeper would earn (in the reserve token) vs. an ETH gas estimate. Caller converts units. */
export async function sweepEconomics(client: PublicClient, router: Address, from: Address): Promise<{ bounty: bigint; gas: bigint; gasCostWei: bigint }> {
  const s = await routerStatus(client, router);
  const bounty = (s.pending * BigInt(s.bountyBps)) / 10_000n;
  const gas = await client.estimateContractGas({ address: router, abi: routerAbi, functionName: "sweep", args: [0n], account: from });
  const gasPrice = await client.getGasPrice();
  return { bounty, gas, gasCostWei: gas * gasPrice };
}

export async function sweep(client: PublicClient, wallet: WalletClient, router: Address, minOut = 0n) {
  await client.simulateContract({ address: router, abi: routerAbi, functionName: "sweep", args: [minOut], account: wallet.account! });
  const hash = await wallet.writeContract({ address: router, abi: routerAbi, functionName: "sweep", args: [minOut], account: wallet.account!, chain: wallet.chain });
  const receipt = await client.waitForTransactionReceipt({ hash });
  return { hash, status: receipt.status };
}
