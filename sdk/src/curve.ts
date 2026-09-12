/** mint.club bonding-curve math (MCV2_Bond.getReserveForToken), exact including ceil rounding. */
export interface Step {
  rangeTo: bigint; // cumulative supply this step covers up to
  price: bigint; // reserve wei per 1e18 token wei (0 = free)
}

const ceilDiv = (a: bigint, b: bigint) => a / b + (a % b === 0n ? 0n : 1n);

export function validateSteps(steps: Step[], maxSupply: bigint): void {
  if (steps.length === 0) throw new Error("steps: empty");
  if (steps[steps.length - 1].rangeTo !== maxSupply) throw new Error("steps: last rangeTo must equal maxSupply");
  steps.forEach((s, i) => {
    if (s.rangeTo === 0n) throw new Error(`steps[${i}]: rangeTo = 0`);
    if (s.price > 0n && s.rangeTo * s.price < 10n ** 18n) throw new Error(`steps[${i}]: rangeTo * price < 1e18`);
    if (i > 0) {
      if (s.rangeTo <= steps[i - 1].rangeTo) throw new Error(`steps[${i}]: rangeTo not increasing`);
      if (s.price <= steps[i - 1].price) throw new Error(`steps[${i}]: price not increasing`);
    }
  });
}

/** Tokens minted to the creator for free at creation. */
export const freeRange = (steps: Step[]): bigint => (steps[0].price === 0n ? steps[0].rangeTo : 0n);

/** Cost to mint `n` tokens starting at `currentSupply`, royalty INCLUDED (as the bond charges). */
export function quoteMint(steps: Step[], currentSupply: bigint, n: bigint, mintRoyaltyBps: number): { reserveAmount: bigint; royalty: bigint; toBond: bigint } {
  let left = n;
  let supply = currentSupply;
  let toBond = 0n;
  for (const s of steps) {
    if (s.rangeTo <= supply) continue;
    const room = s.rangeTo - supply;
    const take = room < left ? room : left;
    toBond += ceilDiv(take * s.price, 10n ** 18n);
    supply += take;
    left -= take;
    if (left === 0n) break;
  }
  if (left > 0n) throw new Error("quoteMint: exceeds max supply");
  if (toBond === 0n) throw new Error("quoteMint: zero cost (all inside the free range?)");
  const royalty = (toBond * BigInt(mintRoyaltyBps)) / 10_000n;
  return { reserveAmount: toBond + royalty, royalty, toBond };
}

/** The curve's marginal price (reserve wei per 1e18 tokens) at `supply`. */
export function priceAt(steps: Step[], supply: bigint): bigint {
  for (const s of steps) if (supply < s.rangeTo) return s.price;
  return steps[steps.length - 1].price;
}

export const maxSupplyOf = (steps: Step[]): bigint => steps[steps.length - 1].rangeTo;

/** Refund for burning `n` tokens from `currentSupply`, royalty DEDUCTED (mirrors MCV2_Bond.getRefundForTokens: floor per step). */
export function quoteBurn(steps: Step[], currentSupply: bigint, n: bigint, burnRoyaltyBps: number): { refundAmount: bigint; royalty: bigint; fromBond: bigint } {
  if (n === 0n) throw new Error("quoteBurn: zero");
  if (n > currentSupply) throw new Error("quoteBurn: exceeds supply");
  let i = steps.findIndex(s => currentSupply <= s.rangeTo); // MCV2_Bond.getCurrentStep
  if (i < 0) throw new Error("quoteBurn: supply above max");
  let left = n, supply = currentSupply, fromBond = 0n;
  while (left > 0n) {
    const supplyLeft = i === 0 ? supply : supply - steps[i - 1].rangeTo;
    const take = left < supplyLeft ? left : supplyLeft;
    fromBond += (take * steps[i].price) / 10n ** 18n;
    left -= take; supply -= take;
    if (i > 0) i -= 1;
    else if (left > 0n) throw new Error("quoteBurn: below zero supply");
  }
  const royalty = (fromBond * BigInt(burnRoyaltyBps)) / 10_000n;
  return { refundAmount: fromBond - royalty, royalty, fromBond };
}
