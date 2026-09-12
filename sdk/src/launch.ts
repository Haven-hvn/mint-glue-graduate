import { type Address, type Hex, type PublicClient, type WalletClient, concatHex, encodeAbiParameters, getContractAddress, keccak256, encodePacked, decodeEventLog } from "viem";
import { factoryAbi, bondAbi, erc20Abi } from "./abi.js";
import { ZERO, type Deployment } from "./addresses.js";
import { type Step, validateSteps, freeRange, quoteMint, priceAt } from "./curve.js";
import { fullRangeTicks, getSqrtRatioAtTick, liquidityForAmounts, amountsForLiquidity, sqrtPriceX96FromRatio } from "./math.js";

/** What a launchpad knows. Everything the contract needs is derived from this. */
export interface LaunchIntent {
  name: string;
  symbol: string;
  reserveToken: Address; // mint.club reserve (WETH for a swap-free native pool)
  mintRoyaltyBps: number;
  burnRoyaltyBps: number;
  steps: Step[]; // last rangeTo = maxSupply
  curveMint: bigint; // tokens minted from the curve for the seed (0 = free range only)
  seed: { tokens: bigint; secondary: bigint }; // target seed; the smaller side binds
  secondary?: Address; // pool's other side; default native
  fee?: number; // default 3000
  tickSpacing?: number; // default 60
  compoundShareWad?: bigint; // share of LP fees re-minted into the locked position; default 100%
  feeRecipient: Address; // LP-fee remainder (if compoundShareWad < 100%) and the pot recipient
  minMain?: bigint; // default disarmed
  minSecondary?: bigint;
  swapper?: Address; // default none
  bountyBps?: number; // default 50
  minClaim?: bigint; // default 1e14 reserve wei
  slippageBps?: number; // headroom on maxReserveIn and the native seed value, default 100
}

export interface LaunchStruct {
  name: string; symbol: string;
  bond: { mintRoyalty: number; burnRoyalty: number; reserveToken: Address; maxSupply: bigint; stepRanges: bigint[]; stepPrices: bigint[] };
  curveMint: bigint; maxReserveIn: bigint;
  secondary: Address; fee: number; tickSpacing: number; sqrtPriceX96: bigint; liquidity: bigint; secondarySeed: bigint;
  compoundShareWad: bigint; feeRecipient: Address; minMain: bigint; minSecondary: bigint;
  swapper: Address; bountyBps: number; minClaim: bigint;
}

export interface Approval { token: Address; spender: Address; amount: bigint }

export interface BuiltLaunch {
  args: LaunchStruct;
  value: bigint; // msg.value: creation fee + native seed (+ headroom, refunded)
  approvals: Approval[];
  predictedToken: Address;
  poolKey: { currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address };
  poolId: Hex;
  seedConsumed: { tokens: bigint; secondary: bigint }; // what the hook will actually take
  mintQuote: { reserveAmount: bigint; royalty: bigint };
  ticks: { tickLower: number; tickUpper: number };
}

const MAX = (1n << 256n) - 1n;

/** mint.club token address is a deterministic ERC-1167 clone: salt = keccak(bond ++ symbol). */
export function predictTokenAddress(d: Deployment, symbol: string): Address {
  const salt = keccak256(encodePacked(["address", "string"], [d.bond, symbol]));
  const initCode = concatHex(["0x3d602d80600a3d3981f3363d3d373d3d3d363d73", d.bondTokenImplementation, "0x5af43d82803e903d91602b57fd5bf3"]);
  return getContractAddress({ opcode: "CREATE2", from: d.bond, salt, bytecode: initCode });
}

export function poolKeyFor(d: Deployment, token: Address, secondary: Address, fee: number, tickSpacing: number) {
  const [c0, c1] = BigInt(token) < BigInt(secondary) ? [token, secondary] : [secondary, token];
  return { currency0: c0, currency1: c1, fee, tickSpacing, hooks: d.hook };
}

export function poolIdOf(k: BuiltLaunch["poolKey"]): Hex {
  return keccak256(encodeAbiParameters(
    [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
    [k.currency0, k.currency1, k.fee, k.tickSpacing, k.hooks],
  ));
}

/** Pure: intent → contract struct, value, approvals. `creationFee` is read from the bond by {buildLaunch}. */
export function buildLaunchOffline(d: Deployment, intent: LaunchIntent, creationFee: bigint): BuiltLaunch {
  const secondary = intent.secondary ?? ZERO;
  const fee = intent.fee ?? 3000;
  const tickSpacing = intent.tickSpacing ?? 60;
  const slip = BigInt(intent.slippageBps ?? 100);
  const maxSupply = intent.steps[intent.steps.length - 1].rangeTo;
  validateSteps(intent.steps, maxSupply);
  if (intent.mintRoyaltyBps > 5000 || intent.burnRoyaltyBps > 5000) throw new Error("royalty > 50%");
  if (intent.feeRecipient === ZERO) throw new Error("feeRecipient must be live");
  const swapFree = intent.reserveToken === secondary || (secondary === ZERO && intent.reserveToken.toLowerCase() === d.wnative.toLowerCase());
  if (swapFree !== !(intent.swapper && intent.swapper !== ZERO)) throw new Error(swapFree ? "swapper given on a swap-free route" : "route needs a swapper");

  const token = predictTokenAddress(d, intent.symbol);
  const key = poolKeyFor(d, token, secondary, fee, tickSpacing);
  const tokenIs1 = key.currency1.toLowerCase() === token.toLowerCase();

  // price the pool where the curve sits AFTER the seed mint
  const free = freeRange(intent.steps);
  const supplyAfter = free + intent.curveMint;
  const p = priceAt(intent.steps, supplyAfter); // reserve wei per 1e18 token
  if (p === 0n) throw new Error("curve price is zero after the seed mint; mint past the free range");
  // pool price = currency1 per currency0. Reserve is assumed 1:1 with secondary (WETH↔ETH or same asset).
  const sqrtPriceX96 = tokenIs1 ? sqrtPriceX96FromRatio(10n ** 18n, p) : sqrtPriceX96FromRatio(p, 10n ** 18n);

  const ticks = fullRangeTicks(tickSpacing);
  const sqrtA = getSqrtRatioAtTick(ticks.tickLower);
  const sqrtB = getSqrtRatioAtTick(ticks.tickUpper);
  const [a0, a1] = tokenIs1 ? [intent.seed.secondary, intent.seed.tokens] : [intent.seed.tokens, intent.seed.secondary];
  const liquidity = liquidityForAmounts(sqrtPriceX96, sqrtA, sqrtB, a0, a1);
  if (liquidity === 0n) throw new Error("seed too small for any liquidity");
  const c = amountsForLiquidity(sqrtPriceX96, sqrtA, sqrtB, liquidity);
  const seedConsumed = tokenIs1 ? { secondary: c.amount0, tokens: c.amount1 } : { tokens: c.amount0, secondary: c.amount1 };
  const tokensAvailable = free + intent.curveMint;
  if (seedConsumed.tokens > tokensAvailable) throw new Error(`seed needs ${seedConsumed.tokens} tokens but only ${tokensAvailable} exist after the mint`);

  const mintQuote = intent.curveMint > 0n ? quoteMint(intent.steps, free, intent.curveMint, intent.mintRoyaltyBps) : { reserveAmount: 0n, royalty: 0n };
  const maxReserveIn = (mintQuote.reserveAmount * (10_000n + slip)) / 10_000n;
  const nativeSeed = secondary === ZERO ? (seedConsumed.secondary * (10_000n + slip)) / 10_000n : 0n;
  const secondarySeed = secondary === ZERO ? 0n : (seedConsumed.secondary * (10_000n + slip)) / 10_000n;

  const approvals: Approval[] = [];
  if (intent.curveMint > 0n) approvals.push({ token: intent.reserveToken, spender: d.factory!, amount: maxReserveIn });
  if (secondary !== ZERO) approvals.push({ token: secondary, spender: d.factory!, amount: secondarySeed });

  return {
    args: {
      name: intent.name, symbol: intent.symbol,
      bond: { mintRoyalty: intent.mintRoyaltyBps, burnRoyalty: intent.burnRoyaltyBps, reserveToken: intent.reserveToken, maxSupply, stepRanges: intent.steps.map(s => s.rangeTo), stepPrices: intent.steps.map(s => s.price) },
      curveMint: intent.curveMint, maxReserveIn,
      secondary, fee, tickSpacing, sqrtPriceX96, liquidity, secondarySeed,
      compoundShareWad: intent.compoundShareWad ?? 10n ** 18n,
      feeRecipient: intent.feeRecipient, minMain: intent.minMain ?? MAX, minSecondary: intent.minSecondary ?? MAX,
      swapper: intent.swapper ?? ZERO, bountyBps: intent.bountyBps ?? 50, minClaim: intent.minClaim ?? 10n ** 14n,
    },
    value: creationFee + nativeSeed,
    approvals,
    predictedToken: token,
    poolKey: key,
    poolId: poolIdOf(key),
    seedConsumed,
    mintQuote,
    ticks,
  };
}

/** Reads the creation fee and checks the symbol is free on this chain, then builds. */
export async function buildLaunch(client: PublicClient, d: Deployment, intent: LaunchIntent): Promise<BuiltLaunch> {
  if (!d.factory) throw new Error("deployment.factory is not set");
  const creationFee = (await client.readContract({ address: d.bond, abi: bondAbi, functionName: "creationFee" })) as bigint;
  const b = buildLaunchOffline(d, intent, creationFee);
  const taken = (await client.readContract({ address: d.bond, abi: bondAbi, functionName: "exists", args: [b.predictedToken] })) as boolean;
  if (taken) throw new Error(`symbol "${intent.symbol}" is already taken on this chain (token ${b.predictedToken})`);
  return b;
}

/** Send whichever approvals are still missing. Idempotent. */
export async function ensureApprovals(client: PublicClient, wallet: WalletClient, b: BuiltLaunch): Promise<Hex[]> {
  const from = wallet.account!.address;
  const hashes: Hex[] = [];
  for (const a of await missingApprovals(client, from, b)) {
    const h = await wallet.writeContract({ address: a.token, abi: erc20Abi, functionName: "approve", args: [a.spender, a.amount], account: wallet.account!, chain: wallet.chain });
    await client.waitForTransactionReceipt({ hash: h });
    hashes.push(h);
  }
  return hashes;
}

/** Approvals still missing for `owner`. */
export async function missingApprovals(client: PublicClient, owner: Address, b: BuiltLaunch): Promise<Approval[]> {
  const out: Approval[] = [];
  for (const a of b.approvals) {
    const cur = (await client.readContract({ address: a.token, abi: erc20Abi, functionName: "allowance", args: [owner, a.spender] })) as bigint;
    if (cur < a.amount) out.push(a);
  }
  return out;
}

/** eth_call the launch; returns the token and router the real call will produce. */
export async function simulateLaunch(client: PublicClient, d: Deployment, b: BuiltLaunch, from: Address): Promise<{ token: Address; router: Address }> {
  const { result } = await client.simulateContract({ address: d.factory!, abi: factoryAbi, functionName: "launch", args: [b.args], value: b.value, account: from });
  const [token, router] = result as unknown as [Address, Address];
  return { token, router };
}

/** Approve (if needed), simulate, send. Returns the tx hash and, after receipt, the addresses. */
export async function launch(client: PublicClient, wallet: WalletClient, d: Deployment, b: BuiltLaunch) {
  await ensureApprovals(client, wallet, b);
  await simulateLaunch(client, d, b, wallet.account!.address);
  const hash = await wallet.writeContract({ address: d.factory!, abi: factoryAbi, functionName: "launch", args: [b.args], value: b.value, account: wallet.account!, chain: wallet.chain });
  const receipt = await client.waitForTransactionReceipt({ hash });
  for (const log of receipt.logs) {
    try {
      const ev = decodeEventLog({ abi: factoryAbi, data: log.data, topics: log.topics });
      if (ev.eventName === "Launched") {
        const a = ev.args as unknown as { token: Address; poolId: Hex; router: Address };
        return { hash, token: a.token, router: a.router, poolId: a.poolId };
      }
    } catch { /* not ours */ }
  }
  throw new Error("Launched event not found");
}
