/**
 * Best-of-two venue quoting: the mint.club curve vs the GlueHook Uniswap V4 pool, for one trade.
 *
 * The model (../model/cadcad_routing.py) shows a UI that quotes both and routes the whole trade to the better
 * venue recovers 2–3 points of execution over pool-only at low royalties and ~1 point at 15%+, and keeps the
 * royalty stream coming from traders instead of arbitrageurs. Pool math is the full-range constant-product case
 * (the program position is full range); curve math mirrors MCV2_Bond exactly.
 */
import { type Address, type Hex, type PublicClient, encodePacked, keccak256, numberToHex } from "viem";
import { bondAbi, erc20Abi, poolManagerAbi } from "./abi.js";
import type { Deployment } from "./addresses.js";
import { type Step, quoteMint, quoteBurn, maxSupplyOf } from "./curve.js";
import { Q96, mulDiv, mulDivUp } from "./math.js";
import { poolIdOf, type BuiltLaunch } from "./launch.js";

export type Side = "buy" | "sell";

export interface PoolState {
  sqrtPriceX96: bigint;
  liquidity: bigint;
  fee: number; // pips
  tokenIs1: boolean; // token is currency1 (always true for a native-ETH pool)
}

export interface CurveState {
  steps: Step[];
  supply: bigint;
  mintRoyaltyBps: number;
  burnRoyaltyBps: number;
}

export interface VenueState { pool: PoolState; curve: CurveState }

const PIPS = 1_000_000n;

/** Exact-input swap output on a full-range V4 pool. */
export function poolSwapExactIn(s: PoolState, zeroForOne: boolean, amountIn: bigint): bigint {
  if (amountIn <= 0n || s.liquidity === 0n) return 0n;
  const inNet = (amountIn * (PIPS - BigInt(s.fee))) / PIPS;
  const L = s.liquidity, sp = s.sqrtPriceX96;
  if (zeroForOne) {
    // currency0 in → price falls. Round the new price UP (less movement) so the output is conservative.
    const num = L << 96n;
    const next = mulDivUp(num, sp, num + inNet * sp);
    return mulDiv(L, sp - next, Q96); // amount1 out
  }
  const next = sp + mulDiv(inNet, Q96, L); // price rises; floor = conservative
  return mulDiv(L << 96n, next - sp, next * sp); // amount0 out
}

/** Tokens out for `secondaryIn` on the pool. */
export const poolQuoteBuy = (s: PoolState, secondaryIn: bigint) => poolSwapExactIn(s, !s.tokenIs1 ? false : true, secondaryIn);
/** Secondary out for `tokensIn` on the pool. */
export const poolQuoteSell = (s: PoolState, tokensIn: bigint) => poolSwapExactIn(s, s.tokenIs1 ? false : true, tokensIn);

/** Most tokens `reserveIn` buys on the curve, royalty included (bisection over MCV2_Bond's exact step math). */
export function curveQuoteBuy(c: CurveState, reserveIn: bigint): bigint {
  const room = maxSupplyOf(c.steps) - c.supply;
  if (reserveIn <= 0n || room <= 0n) return 0n;
  const cost = (n: bigint) => { try { return quoteMint(c.steps, c.supply, n, c.mintRoyaltyBps).reserveAmount; } catch { return null; } };
  let lo = 0n, hi = room;
  if ((cost(hi) ?? 0n) <= reserveIn) return hi;
  while (hi - lo > 1n) {
    const mid = (lo + hi) >> 1n;
    const k = cost(mid);
    if (k !== null && k <= reserveIn) lo = mid; else hi = mid;
  }
  return lo;
}

/** Reserve the curve refunds for `tokensIn`, royalty deducted. */
export function curveQuoteSell(c: CurveState, tokensIn: bigint): bigint {
  if (tokensIn <= 0n || tokensIn > c.supply) return 0n;
  try { return quoteBurn(c.steps, c.supply, tokensIn, c.burnRoyaltyBps).refundAmount; } catch { return 0n; }
}

export interface VenueQuote {
  side: Side;
  amountIn: bigint;
  curve: bigint; // out via the curve (0 = unavailable, e.g. sold out)
  pool: bigint; // out via the pool
  best: "curve" | "pool";
  edgeBps: number; // how much better the best venue is than the other
}

/** Quote one trade on both venues. Pure. */
export function quoteVenues(v: VenueState, side: Side, amountIn: bigint): VenueQuote {
  const curve = side === "buy" ? curveQuoteBuy(v.curve, amountIn) : curveQuoteSell(v.curve, amountIn);
  const pool = side === "buy" ? poolQuoteBuy(v.pool, amountIn) : poolQuoteSell(v.pool, amountIn);
  const best = pool >= curve ? "pool" : "curve";
  const [hi, lo] = best === "pool" ? [pool, curve] : [curve, pool];
  const edgeBps = lo === 0n ? Infinity : Number(((hi - lo) * 10_000n) / lo);
  return { side, amountIn, curve, pool, best, edgeBps };
}

/**
 * The trade size above which the curve beats the pool (the pool's slippage overtakes the royalty). Returns null
 * when the pool never wins (curve is always better) and Infinity when the pool wins up to `cap`. A UI can show the
 * pool by default and surface the curve only above this size.
 */
export function crossoverSize(v: VenueState, side: Side, cap: bigint): bigint | null | typeof Infinity {
  const poolWins = (a: bigint) => quoteVenues(v, side, a).best === "pool";
  const eps = cap / 1_000_000n || 1n;
  if (!poolWins(eps)) return null;
  if (poolWins(cap)) return Infinity;
  let lo = eps, hi = cap;
  for (let i = 0; i < 64 && hi - lo > 1n; i++) {
    const mid = (lo + hi) >> 1n;
    if (poolWins(mid)) lo = mid; else hi = mid;
  }
  return hi;
}

// ─── live state ───────────────────────────────────────────────────────────────────────────────

const POOLS_SLOT = 6n; // v4-core StateLibrary.POOLS_SLOT
const LIQUIDITY_OFFSET = 3n; // Pool.State: slot0, feeGrowthGlobal0, feeGrowthGlobal1, liquidity

export function poolStateSlot(poolId: Hex): Hex {
  return keccak256(encodePacked(["bytes32", "bytes32"], [poolId, numberToHex(POOLS_SLOT, { size: 32 })]));
}

/** Read both venues' state in one round of calls. */
export async function readVenueState(client: PublicClient, d: Deployment, token: Address, poolKey: BuiltLaunch["poolKey"]): Promise<VenueState> {
  const poolId = poolIdOf(poolKey);
  const slot = poolStateSlot(poolId);
  const liqSlot = numberToHex(BigInt(slot) + LIQUIDITY_OFFSET, { size: 32 });
  const [rawSteps, bond, supply, slot0, liq] = await Promise.all([
    client.readContract({ address: d.bond, abi: bondAbi, functionName: "getSteps", args: [token] }) as Promise<{ rangeTo: bigint; price: bigint }[]>,
    client.readContract({ address: d.bond, abi: bondAbi, functionName: "tokenBond", args: [token] }) as Promise<readonly [Address, number, number, number, Address, bigint]>,
    client.readContract({ address: token, abi: erc20Abi, functionName: "totalSupply" }) as Promise<bigint>,
    client.readContract({ address: d.poolManager, abi: poolManagerAbi, functionName: "extsload", args: [slot] }) as Promise<Hex>,
    client.readContract({ address: d.poolManager, abi: poolManagerAbi, functionName: "extsload", args: [liqSlot] }) as Promise<Hex>,
  ]);
  const sqrtPriceX96 = BigInt(slot0) & ((1n << 160n) - 1n);
  const liquidity = BigInt(liq) & ((1n << 128n) - 1n);
  return {
    pool: { sqrtPriceX96, liquidity, fee: poolKey.fee, tokenIs1: poolKey.currency1.toLowerCase() === token.toLowerCase() },
    curve: { steps: rawSteps.map(s => ({ rangeTo: s.rangeTo, price: s.price })), supply, mintRoyaltyBps: Number(bond[1]), burnRoyaltyBps: Number(bond[2]) },
  };
}
