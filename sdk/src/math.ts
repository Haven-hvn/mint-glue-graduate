/**
 * Uniswap V4 price / liquidity math in BigInt. Ports of TickMath, SqrtPriceMath and LiquidityAmounts,
 * checked against the amounts the live GlueHook consumed on Base (see test/math.test.ts).
 */
export const Q96 = 1n << 96n;
export const Q192 = 1n << 192n;
export const MAX_UINT256 = (1n << 256n) - 1n;
export const MAX_USABLE_TICK = 887272;

export function isqrt(n: bigint): bigint {
  if (n < 0n) throw new Error("isqrt of negative");
  if (n < 2n) return n;
  let x = BigInt(Math.floor(Math.sqrt(Number(n)))); // seed (may be off for huge n; Newton fixes it)
  if (x === 0n) x = 1n;
  for (;;) {
    const y = (x + n / x) >> 1n;
    if (y >= x) {
      // converge: x is floor sqrt when x*x <= n < (x+1)^2
      while (x * x > n) x -= 1n;
      while ((x + 1n) * (x + 1n) <= n) x += 1n;
      return x;
    }
    x = y;
  }
}

export const mulDiv = (a: bigint, b: bigint, d: bigint): bigint => (a * b) / d;
export const mulDivUp = (a: bigint, b: bigint, d: bigint): bigint => {
  const p = a * b;
  return p / d + (p % d === 0n ? 0n : 1n);
};

/** sqrt(num/den) in Q64.96, where price = currency1 raw units per currency0 raw unit. Exact when the ratio is a perfect square. */
export function sqrtPriceX96FromRatio(num: bigint, den: bigint): bigint {
  if (num <= 0n || den <= 0n) throw new Error("price must be positive");
  return isqrt((num * Q192) / den);
}

/** Spacing-aligned full range, identical to GlueHook's fullRangeTicks. */
export function fullRangeTicks(tickSpacing: number): { tickLower: number; tickUpper: number } {
  if (tickSpacing <= 0) throw new Error("tickSpacing must be > 0");
  const max = Math.floor(MAX_USABLE_TICK / tickSpacing) * tickSpacing;
  return { tickLower: -max, tickUpper: max };
}

const TICK_CONSTS: [number, bigint][] = [
  [0x2, 0xfff97272373d413259a46990580e213an],
  [0x4, 0xfff2e50f5f656932ef12357cf3c7fdccn],
  [0x8, 0xffe5caca7e10e4e61c3624eaa0941cd0n],
  [0x10, 0xffcb9843d60f6159c9db58835c926644n],
  [0x20, 0xff973b41fa98c081472e6896dfb254c0n],
  [0x40, 0xff2ea16466c96a3843ec78b326b52861n],
  [0x80, 0xfe5dee046a99a2a811c461f1969c3053n],
  [0x100, 0xfcbe86c7900a88aedcffc83b479aa3a4n],
  [0x200, 0xf987a7253ac413176f2b074cf7815e54n],
  [0x400, 0xf3392b0822b70005940c7a398e4b70f3n],
  [0x800, 0xe7159475a2c29b7443b29c7fa6e889d9n],
  [0x1000, 0xd097f3bdfd2022b8845ad8f792aa5825n],
  [0x2000, 0xa9f746462d870fdf8a65dc1f90e061e5n],
  [0x4000, 0x70d869a156d2a1b890bb3df62baf32f7n],
  [0x8000, 0x31be135f97d08fd981231505542fcfa6n],
  [0x10000, 0x9aa508b5b7a84e1c677de54f3e99bc9n],
  [0x20000, 0x5d6af8dedb81196699c329225ee604n],
  [0x40000, 0x2216e584f5fa1ea926041bedfe98n],
  [0x80000, 0x48a170391f7dc42444e8fa2n],
];

/** Uniswap TickMath.getSqrtRatioAtTick. */
export function getSqrtRatioAtTick(tick: number): bigint {
  const abs = tick < 0 ? -tick : tick;
  if (abs > MAX_USABLE_TICK) throw new Error("tick out of range");
  let ratio = (abs & 0x1) !== 0 ? 0xfffcb933bd6fad37aa2d162d1a594001n : 0x100000000000000000000000000000000n;
  for (const [bit, c] of TICK_CONSTS) if ((abs & bit) !== 0) ratio = (ratio * c) >> 128n;
  if (tick > 0) ratio = MAX_UINT256 / ratio;
  return (ratio >> 32n) + (ratio % (1n << 32n) === 0n ? 0n : 1n);
}

/** LiquidityAmounts.getLiquidityForAmounts for a position spanning [sqrtA, sqrtB] at current sqrtP. */
export function liquidityForAmounts(sqrtP: bigint, sqrtA: bigint, sqrtB: bigint, amount0: bigint, amount1: bigint): bigint {
  if (sqrtA > sqrtB) [sqrtA, sqrtB] = [sqrtB, sqrtA];
  const l0 = (a0: bigint, lo: bigint, hi: bigint) => mulDiv(a0, mulDiv(lo, hi, Q96), hi - lo);
  const l1 = (a1: bigint, lo: bigint, hi: bigint) => mulDiv(a1, Q96, hi - lo);
  if (sqrtP <= sqrtA) return l0(amount0, sqrtA, sqrtB);
  if (sqrtP >= sqrtB) return l1(amount1, sqrtA, sqrtB);
  const a = l0(amount0, sqrtP, sqrtB);
  const b = l1(amount1, sqrtA, sqrtP);
  return a < b ? a : b;
}

/** Amounts the PoolManager charges to ADD `liquidity` (rounds up, like v4-core). */
export function amountsForLiquidity(sqrtP: bigint, sqrtA: bigint, sqrtB: bigint, liquidity: bigint): { amount0: bigint; amount1: bigint } {
  if (sqrtA > sqrtB) [sqrtA, sqrtB] = [sqrtB, sqrtA];
  const amt0 = (lo: bigint, hi: bigint) => {
    const n = mulDivUp(liquidity << 96n, hi - lo, hi);
    return n / lo + (n % lo === 0n ? 0n : 1n);
  };
  const amt1 = (lo: bigint, hi: bigint) => mulDivUp(liquidity, hi - lo, Q96);
  if (sqrtP <= sqrtA) return { amount0: amt0(sqrtA, sqrtB), amount1: 0n };
  if (sqrtP >= sqrtB) return { amount0: 0n, amount1: amt1(sqrtA, sqrtB) };
  return { amount0: amt0(sqrtP, sqrtB), amount1: amt1(sqrtA, sqrtP) };
}
