import { describe, it, expect } from "vitest";
import { Q96, getSqrtRatioAtTick, fullRangeTicks, liquidityForAmounts, amountsForLiquidity, sqrtPriceX96FromRatio, isqrt } from "../src/math.js";
import { quoteMint, freeRange, priceAt, type Step } from "../src/curve.js";
import { buildLaunchOffline, predictTokenAddress } from "../src/launch.js";
import { deployments } from "../src/addresses.js";

// Vectors recorded from test/fork/LaunchBase.t.sol against the LIVE GlueHook + PoolManager on Base.
const SQRT_LOWER = 4306310044n; // tick -887220
const SQRT_UPPER = 1457652066949847389969617340386294118487833376468n; // tick 887220
const SQRT_P = 100n * Q96; // 10_000 token per ETH
const L = 40n * 10n ** 18n;
const CONSUMED_ETH = 399999999999999998n;
const CONSUMED_TOKENS = 3999999999999999999998n;

describe("TickMath", () => {
  it("full range for spacing 60 is ±887220", () => expect(fullRangeTicks(60)).toEqual({ tickLower: -887220, tickUpper: 887220 }));
  it("matches the hook's sqrt prices at the full-range ticks", () => {
    expect(getSqrtRatioAtTick(-887220)).toBe(SQRT_LOWER);
    expect(getSqrtRatioAtTick(887220)).toBe(SQRT_UPPER);
  });
  it("tick 0 is Q96", () => expect(getSqrtRatioAtTick(0)).toBe(Q96));
});

describe("liquidity ⇄ amounts", () => {
  it("reproduces the amounts the live PoolManager charged", () => {
    const a = amountsForLiquidity(SQRT_P, SQRT_LOWER, SQRT_UPPER, L);
    expect(a.amount0).toBe(CONSUMED_ETH);
    expect(a.amount1).toBe(CONSUMED_TOKENS);
  });
  it("liquidity for the target seed equals what the fork test used", () => {
    expect(liquidityForAmounts(SQRT_P, SQRT_LOWER, SQRT_UPPER, 4n * 10n ** 17n, 4000n * 10n ** 18n)).toBe(L);
  });
  it("sqrt price from curve price is exact for perfect squares", () => {
    expect(sqrtPriceX96FromRatio(10n ** 18n, 10n ** 14n)).toBe(SQRT_P);
  });
  it("isqrt is floor", () => {
    expect(isqrt(10n ** 40n)).toBe(10n ** 20n);
    expect(isqrt(10n ** 40n - 1n)).toBe(10n ** 20n - 1n);
  });
});

const steps: Step[] = [
  { rangeTo: 1_000n * 10n ** 18n, price: 0n },
  { rangeTo: 100_000n * 10n ** 18n, price: 10n ** 14n },
  { rangeTo: 1_000_000n * 10n ** 18n, price: 10n ** 15n },
];

describe("mint.club curve", () => {
  it("quotes the seed mint like the live bond did (0.515 WETH for 5_000 tokens at 3%)", () => {
    const q = quoteMint(steps, freeRange(steps), 5_000n * 10n ** 18n, 300);
    expect(q.reserveAmount).toBe(515n * 10n ** 15n);
    expect(q.royalty).toBe(15n * 10n ** 15n);
  });
  it("crosses steps with ceil rounding per step", () => {
    const q = quoteMint(steps, 99_999n * 10n ** 18n, 2n * 10n ** 18n, 0);
    expect(q.toBond).toBe(10n ** 14n + 10n ** 15n);
  });
  it("marginal price after the seed mint", () => expect(priceAt(steps, 6_000n * 10n ** 18n)).toBe(10n ** 14n));
});

describe("buildLaunchOffline", () => {
  const d = { ...deployments[8453], factory: "0x0000000000000000000000000000000000000FAC" as const };
  const intent = {
    name: "Test", symbol: "RRT50976907", reserveToken: d.wnative, mintRoyaltyBps: 300, burnRoyaltyBps: 300, steps,
    curveMint: 5_000n * 10n ** 18n, seed: { tokens: 4000n * 10n ** 18n, secondary: 4n * 10n ** 17n },
    feeRecipient: "0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D" as const,
  };
  it("predicts the token address the live bond deployed", () => {
    expect(predictTokenAddress(d, "RRT50976948").toLowerCase()).toBe("0xCb4A3Cbe597B70bE588d1753faA4C143e33d188B".toLowerCase());
  });
  it("derives the exact struct the fork test sent", () => {
    const b = buildLaunchOffline(d, intent, 7n * 10n ** 14n);
    expect(b.args.sqrtPriceX96).toBe(SQRT_P);
    expect(b.args.liquidity).toBe(L);
    expect(b.seedConsumed).toEqual({ secondary: CONSUMED_ETH, tokens: CONSUMED_TOKENS });
    expect(b.mintQuote.reserveAmount).toBe(515n * 10n ** 15n);
    expect(b.args.maxReserveIn).toBe((515n * 10n ** 15n * 10_100n) / 10_000n);
    expect(b.value).toBe(7n * 10n ** 14n + (CONSUMED_ETH * 10_100n) / 10_000n);
    expect(b.approvals).toEqual([{ token: d.wnative, spender: d.factory, amount: b.args.maxReserveIn }]);
    expect(b.poolKey.currency0).toBe("0x0000000000000000000000000000000000000000");
    expect(b.ticks).toEqual({ tickLower: -887220, tickUpper: 887220 });
  });
  it("refuses a swapper on a swap-free route and demands one otherwise", () => {
    expect(() => buildLaunchOffline(d, { ...intent, swapper: "0x0000000000000000000000000000000000000001" }, 0n)).toThrow(/swap-free/);
    expect(() => buildLaunchOffline(d, { ...intent, reserveToken: "0x0000000000000000000000000000000000000002" }, 0n)).toThrow(/needs a swapper/);
  });
  it("refuses a seed that needs more tokens than exist", () => {
    expect(() => buildLaunchOffline(d, { ...intent, seed: { tokens: 10_000n * 10n ** 18n, secondary: 1n * 10n ** 18n } }, 0n)).toThrow(/only/);
  });
});
