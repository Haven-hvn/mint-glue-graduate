import { describe, it, expect } from "vitest";
import { Q96 } from "../src/math.js";
import { quoteBurn, quoteMint, type Step } from "../src/curve.js";
import { poolQuoteBuy, poolQuoteSell, curveQuoteBuy, curveQuoteSell, quoteVenues, crossoverSize, type VenueState } from "../src/venue.js";

const WEI = 10n ** 18n;
// the launch vectors from math.test.ts: 10_000 tokens per ETH, L = 40e18 (0.4 ETH / 4_000 tokens), native pool → token is currency1
const pool = { sqrtPriceX96: 100n * Q96, liquidity: 40n * WEI, fee: 3000, tokenIs1: true };
const steps: Step[] = [{ rangeTo: 1_000n * WEI, price: 0n }, { rangeTo: 100_000n * WEI, price: 10n ** 14n }, { rangeTo: 1_000_000n * WEI, price: 10n ** 15n }];
const curve = { steps, supply: 6_000n * WEI, mintRoyaltyBps: 300, burnRoyaltyBps: 300 };
const v: VenueState = { pool, curve };

describe("pool math (full-range constant product)", () => {
  it("a tiny buy pays ≈ fee + no slippage", () => {
    const out = poolQuoteBuy(pool, 10n ** 12n); // 1e-6 ETH → ~0.01 token
    const ideal = 10n ** 12n * 10_000n;
    expect(Number(out) / Number(ideal)).toBeCloseTo(0.997, 4);
  });
  it("a buy of the whole ETH side has heavy slippage and never returns more than the token reserve", () => {
    const out = poolQuoteBuy(pool, 4n * 10n ** 17n);
    expect(out).toBeLessThan(4_000n * WEI);
    expect(Number(out) / Number(4_000n * WEI)).toBeCloseTo(0.4994, 3); // x·y=k: half the reserve for doubling the other side, less fee
  });
  it("buy then sell round-trips to less than you started with", () => {
    const tokens = poolQuoteBuy(pool, 10n ** 16n);
    expect(poolQuoteSell(pool, tokens)).toBeLessThan(10n ** 16n);
  });
});

describe("curve math", () => {
  it("quoteBurn mirrors MCV2_Bond: floor per step, royalty deducted, walks down across steps", () => {
    const q = quoteBurn(steps, 100_002n * WEI, 4n * WEI, 300);
    expect(q.fromBond).toBe(2n * 10n ** 15n + 2n * 10n ** 14n);
    expect(q.royalty).toBe((q.fromBond * 300n) / 10_000n);
    expect(q.refundAmount).toBe(q.fromBond - q.royalty);
  });
  it("a supply exactly on a boundary belongs to the lower step", () => {
    expect(quoteBurn(steps, 100_000n * WEI, 1n * WEI, 0).fromBond).toBe(10n ** 14n);
  });
  it("curveQuoteBuy inverts quoteMint", () => {
    const n = curveQuoteBuy(curve, 103n * 10n ** 15n); // 0.103 ETH → 1_000 tokens at 1e-4 + 3%
    expect(n).toBe(1_000n * WEI);
    expect(quoteMint(steps, curve.supply, n, 300).reserveAmount).toBeLessThanOrEqual(103n * 10n ** 15n);
  });
  it("curveQuoteSell = burn refund", () => expect(curveQuoteSell(curve, 10n * WEI)).toBe(quoteBurn(steps, curve.supply, 10n * WEI, 300).refundAmount));
});

describe("venue choice", () => {
  it("small trades go to the pool, large trades to the curve; the crossover sits between", () => {
    const small = quoteVenues(v, "buy", 10n ** 15n); // 0.001 ETH
    const large = quoteVenues(v, "buy", 10n ** 17n); // 0.1 ETH
    expect(small.best).toBe("pool");
    expect(large.best).toBe("curve");
    const x = crossoverSize(v, "buy", 10n ** 18n) as bigint;
    expect(x).toBeGreaterThan(10n ** 15n);
    expect(x).toBeLessThan(10n ** 17n);
    expect(quoteVenues(v, "buy", x - 1n).best).toBe("pool");
    expect(quoteVenues(v, "buy", x + 1n).best).toBe("curve");
  });
  it("sell side too", () => {
    expect(quoteVenues(v, "sell", 1n * WEI).best).toBe("pool");
    expect(quoteVenues(v, "sell", 1_000n * WEI).best).toBe("curve");
  });
  it("a wider royalty band moves the crossover up", () => {
    const wide: VenueState = { pool, curve: { ...curve, mintRoyaltyBps: 1500, burnRoyaltyBps: 1500 } };
    expect(crossoverSize(wide, "buy", 10n ** 18n) as bigint).toBeGreaterThan(crossoverSize(v, "buy", 10n ** 18n) as bigint);
  });
});
