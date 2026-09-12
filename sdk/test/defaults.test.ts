import { describe, it, expect } from "vitest";
import { RECOMMENDED, bandBps, geometricSteps, recommendedIntent, adviseIntent } from "../src/defaults.js";
import { buildLaunchOffline } from "../src/launch.js";
import { deployments } from "../src/addresses.js";
import { validateSteps } from "../src/curve.js";

const WEI = 10n ** 18n;
const d = { ...deployments[8453], factory: "0x000000000000000000000000000000000000dEaD" as const };
const base = { name: "T", symbol: "T-1", reserveToken: d.wnative, feeRecipient: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as const,
  curve: { freeRange: 1_000n * WEI, maxSupply: 1_000_000n * WEI, startPrice: 10n ** 14n, endPrice: 10n ** 15n } };

describe("defaults", () => {
  it("band: 15%/15% ≈ 35%, 3%/3% ≈ 6%, 50%/50% = 200%", () => {
    expect(bandBps(1500, 1500)).toBe(3529);
    expect(bandBps(300, 300)).toBe(619);
    expect(bandBps(5000, 5000)).toBe(20000);
  });
  it("geometricSteps is a valid, smooth curve with the requested endpoints", () => {
    const s = geometricSteps(base.curve);
    validateSteps(s, base.curve.maxSupply);
    expect(s[0]).toEqual({ rangeTo: 1_000n * WEI, price: 0n });
    expect(s[1].price).toBe(10n ** 14n);
    expect(s[s.length - 1]).toEqual({ rangeTo: 1_000_000n * WEI, price: 10n ** 15n });
    expect(s.length).toBe(RECOMMENDED.curveSteps + 1);
    for (let i = 2; i < s.length; i++) expect(Number(s[i].price) / Number(s[i - 1].price)).toBeLessThan(RECOMMENDED.maxStepRatio);
  });
  it("recommendedIntent builds a launch and draws no advice", () => {
    const intent = recommendedIntent(base);
    expect(intent.mintRoyaltyBps).toBe(1500);
    expect(intent.fee).toBe(3000);
    expect(adviseIntent(intent)).toEqual([]);
    const b = buildLaunchOffline(d, intent, 0n);
    expect(b.args.liquidity).toBeGreaterThan(0n);
    expect(b.seedConsumed.tokens).toBeLessThanOrEqual(intent.seed.tokens);
  });
  it("advises on the repo's original 3% / 10×-step intent", () => {
    const codes = adviseIntent({
      ...recommendedIntent(base), mintRoyaltyBps: 300, burnRoyaltyBps: 300,
      steps: [{ rangeTo: 1_000n * WEI, price: 0n }, { rangeTo: 100_000n * WEI, price: 10n ** 14n }, { rangeTo: 1_000_000n * WEI, price: 10n ** 15n }],
      seed: { tokens: 4_000n * WEI, secondary: 4n * 10n ** 17n },
    }).map(a => a.code);
    expect(codes).toContain("royalty-low");
    expect(codes).toContain("steps-coarse");
    expect(codes).toContain("seed-small");
  });
  it("flags a high royalty, a high pool fee, and partial compounding", () => {
    const codes = adviseIntent({ ...recommendedIntent(base), mintRoyaltyBps: 3000, burnRoyaltyBps: 3000, fee: 30_000, compoundShareWad: 5n * 10n ** 17n }).map(a => a.code);
    expect(codes).toEqual(expect.arrayContaining(["royalty-high", "pool-fee-high", "compound-partial"]));
  });
});
