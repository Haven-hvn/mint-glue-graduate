/**
 * Sane defaults from the tokenomics model in ../model (cadcad_routing.py, cadcad_mix.csv).
 *
 * What the sweeps found, in one paragraph: the curve royalty is the only efficient tax (ETH locked per point of
 * trader cost rises with the rate and falls with any pool fee); funding saturates near a 20% royalty in a flat
 * market while the arbitrage band the pool floats in widens fast above it; below ~5% the curve wins most trades
 * and the UI must quote both venues; coarse price steps leak to arbitrageurs at the boundary; pool depth, not the
 * tax, is what buys execution, so seed hard. Hence: 15% royalty both ways, 0.3% pool fee, 100% of LP fees
 * compounding, a smooth geometric curve, and a warning when an intent strays from that.
 */
import type { Address } from "viem";
import { type Step, validateSteps, freeRange, quoteMint, priceAt } from "./curve.js";
import type { LaunchIntent } from "./launch.js";

export const RECOMMENDED = {
  mintRoyaltyBps: 1500,
  burnRoyaltyBps: 1500,
  fee: 3000, // pool fee in pips (0.3%)
  tickSpacing: 60,
  compoundShareWad: 10n ** 18n, // every LP fee re-minted into the locked position
  bountyBps: 50,
  curveSteps: 20, // geometric steps between the first and last paid price
  /** Royalty window the model supports: below it the curve dominates and funding is ~3× lower; above it the band exceeds 50%. */
  royaltyWindowBps: { min: 1000, max: 2000 },
  /** Pool fee above which every extra point costs traders more than it raises. */
  maxUsefulPoolFee: 10_000,
  /** Adjacent step prices further apart than this ratio leak to arbitrageurs when supply crosses the boundary. */
  maxStepRatio: 2,
} as const;

/** Width of the band the pool floats in: curve mint ceiling ÷ burn floor − 1, in bps. 15%/15% → 3529 (35%). */
export function bandBps(mintRoyaltyBps: number, burnRoyaltyBps: number): number {
  return Math.round(((10_000 + mintRoyaltyBps) / (10_000 - burnRoyaltyBps) - 1) * 10_000);
}

export interface GeometricCurve {
  freeRange: bigint; // tokens (wei) minted free to the creator at creation; 0 for none
  maxSupply: bigint; // tokens (wei)
  startPrice: bigint; // reserve wei per 1e18 tokens at the first paid step
  endPrice: bigint; // …at the last step
  steps?: number; // default RECOMMENDED.curveSteps
}

/** A smooth mint.club step curve: supply and price both geometric between the free range and max supply. */
export function geometricSteps(c: GeometricCurve): Step[] {
  const n = c.steps ?? RECOMMENDED.curveSteps;
  if (n < 2) throw new Error("geometricSteps: need at least 2 steps");
  if (c.endPrice <= c.startPrice) throw new Error("geometricSteps: endPrice must exceed startPrice");
  if (c.maxSupply <= c.freeRange) throw new Error("geometricSteps: maxSupply must exceed freeRange");
  const WEI = 10n ** 18n;
  const s0 = Number(c.freeRange / WEI) || 1; // whole tokens; avoid log(0)
  const s1 = Number(c.maxSupply / WEI);
  const p0 = Number(c.startPrice), p1 = Number(c.endPrice);
  const out: Step[] = c.freeRange > 0n ? [{ rangeTo: c.freeRange, price: 0n }] : [];
  let lastRange = c.freeRange, lastPrice = 0n;
  for (let i = 0; i < n; i++) {
    const rangeTo = i === n - 1 ? c.maxSupply : BigInt(Math.round(s0 * Math.pow(s1 / s0, (i + 1) / n))) * WEI;
    const price = i === n - 1 ? c.endPrice : i === 0 ? c.startPrice : BigInt(Math.round(p0 * Math.pow(p1 / p0, i / (n - 1))));
    if (rangeTo <= lastRange || price <= lastPrice) continue; // collapse steps that rounding made degenerate
    out.push({ rangeTo, price });
    lastRange = rangeTo; lastPrice = price;
  }
  validateSteps(out, c.maxSupply);
  return out;
}

export interface RecommendedLaunch {
  name: string;
  symbol: string;
  reserveToken: Address;
  feeRecipient: Address;
  curve: GeometricCurve;
  /** Pool seed. Default: 80% of the free range paired at the opening price. Bigger is better: depth buys execution. */
  seed?: { tokens: bigint; secondary: bigint };
  curveMint?: bigint;
  secondary?: Address;
  swapper?: Address;
  minClaim?: bigint;
}

/** A complete LaunchIntent with the model's recommended parameters filled in. Override anything on the result. */
export function recommendedIntent(r: RecommendedLaunch): LaunchIntent {
  const steps = geometricSteps(r.curve);
  const free = freeRange(steps);
  const curveMint = r.curveMint ?? 0n;
  const p = priceAt(steps, free + curveMint);
  const seedTokens = r.seed?.tokens ?? ((free + curveMint) * 8n) / 10n;
  const seed = r.seed ?? { tokens: seedTokens, secondary: (seedTokens * p) / 10n ** 18n };
  return {
    name: r.name, symbol: r.symbol, reserveToken: r.reserveToken, feeRecipient: r.feeRecipient,
    mintRoyaltyBps: RECOMMENDED.mintRoyaltyBps, burnRoyaltyBps: RECOMMENDED.burnRoyaltyBps,
    steps, curveMint, seed,
    secondary: r.secondary, swapper: r.swapper, minClaim: r.minClaim,
    fee: RECOMMENDED.fee, tickSpacing: RECOMMENDED.tickSpacing,
    compoundShareWad: RECOMMENDED.compoundShareWad, bountyBps: RECOMMENDED.bountyBps,
  };
}

export interface Advice { level: "warn" | "info"; code: string; message: string }

/** Where an intent departs from the model's findings. Empty means it matches the recommendation. */
export function adviseIntent(intent: LaunchIntent): Advice[] {
  const out: Advice[] = [];
  const { min, max } = RECOMMENDED.royaltyWindowBps;
  const roy = Math.min(intent.mintRoyaltyBps, intent.burnRoyaltyBps);
  const band = bandBps(intent.mintRoyaltyBps, intent.burnRoyaltyBps);
  if (roy < 500) out.push({ level: "warn", code: "royalty-low", message: `royalty ${roy / 100}%: the curve beats the pool on most trades, so the UI must quote both venues; locked liquidity is ~3× lower than at 15%` });
  else if (roy < min) out.push({ level: "info", code: "royalty-below-window", message: `royalty ${roy / 100}%: below the ${min / 100}–${max / 100}% window; funding efficiency keeps rising up to ~20%` });
  if (Math.max(intent.mintRoyaltyBps, intent.burnRoyaltyBps) > max) out.push({ level: "warn", code: "royalty-high", message: `royalty above ${max / 100}%: the pool floats in a ${(band / 100).toFixed(0)}% band and the curve stops being a price floor; funding saturates above 20% in a flat market` });
  if (intent.mintRoyaltyBps !== intent.burnRoyaltyBps) out.push({ level: "info", code: "royalty-asymmetric", message: "mint and burn royalties differ; the model assumes equal rates (the band is set by both)" });
  const fee = intent.fee ?? 3000;
  if (fee > RECOMMENDED.maxUsefulPoolFee) out.push({ level: "warn", code: "pool-fee-high", message: `pool fee ${fee / 10_000}%: every point above 1% costs traders more than it raises; its only distinct effect is cutting mint.club's 20% share` });
  if ((intent.compoundShareWad ?? 10n ** 18n) < 10n ** 18n) out.push({ level: "info", code: "compound-partial", message: "LP fees are not fully compounding into the locked position; the model's depth figures assume 100%" });
  const paid = intent.steps.filter(s => s.price > 0n);
  for (let i = 1; i < paid.length; i++) {
    if (Number(paid[i].price) / Number(paid[i - 1].price) > RECOMMENDED.maxStepRatio) {
      out.push({ level: "warn", code: "steps-coarse", message: `step ${i} jumps ${(Number(paid[i].price) / Number(paid[i - 1].price)).toFixed(1)}× in price; coarse steps hand the pool's reserve to arbitrageurs when supply crosses back; use geometricSteps()` });
      break;
    }
  }
  const free = freeRange(intent.steps);
  if (paid.length > 0) {
    const firstEnd = paid[0].rangeTo;
    const reserveToFirstStep = firstEnd > free ? quoteMint(intent.steps, free, firstEnd - free, 0).toBond : 0n;
    if (reserveToFirstStep > 0n && intent.seed.secondary * 10n < reserveToFirstStep) out.push({ level: "warn", code: "seed-small", message: "pool seed is under 10% of the reserve the first paid step will hold; depth buys execution, seed harder" });
  }
  return out;
}
