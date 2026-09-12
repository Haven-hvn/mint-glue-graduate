# @royalty-router/sdk

Launch a mint.club token with a GlueHook Uniswap V4 pool and a trustless royalty router in one transaction, from a browser, Node, or the `rr` CLI. Built on viem. Every later `sweep` turns the creator royalty into permanently locked pool liquidity.

## Install

```
npm i @royalty-router/sdk viem
```

## Launch from a browser or Node

```ts
import { createPublicClient, createWalletClient, custom, http } from "viem";
import { base } from "viem/chains";
import { deployments, buildLaunch, launch, type LaunchIntent } from "@royalty-router/sdk";

const d = { ...deployments[base.id], factory: "0x..." }; // your factory
const client = createPublicClient({ chain: base, transport: http() });
const wallet = createWalletClient({ chain: base, transport: custom(window.ethereum) });

const intent: LaunchIntent = {
  name: "My Token", symbol: "MYT",
  reserveToken: d.wnative,                // WETH reserve + native pool = swap-free route
  mintRoyaltyBps: 300, burnRoyaltyBps: 300,
  steps: [                                // mint.club curve; last rangeTo = maxSupply
    { rangeTo: 1_000n * 10n ** 18n, price: 0n },              // free range → seeds the token side
    { rangeTo: 100_000n * 10n ** 18n, price: 10n ** 14n },    // 0.0001 ETH per token
    { rangeTo: 1_000_000n * 10n ** 18n, price: 10n ** 15n },
  ],
  curveMint: 5_000n * 10n ** 18n,         // extra seed tokens minted from the curve
  seed: { tokens: 4_000n * 10n ** 18n, secondary: 4n * 10n ** 17n }, // 4000 tokens / 0.4 ETH; smaller side binds
  feeRecipient: "0x...",                  // LP-fee remainders
};

const built = await buildLaunch(client, d, intent);
// built.args         → the Launch struct
// built.value        → msg.value (creation fee + native seed + 1% headroom, refunded)
// built.approvals    → ERC20 approvals the caller must grant the factory
// built.predictedToken, built.poolId, built.seedConsumed, built.mintQuote

const { token, router, poolId } = await launch(client, wallet, d, built);
```

`buildLaunch` derives everything the contract needs and refuses bad inputs before you sign: wrong swapper for the route, a seed that needs more tokens than exist, a symbol already taken on this chain, an invalid curve.

## Recommended defaults

The tokenomics model in `../model` (see `cadcad_routing.py`, `cadcad_mix.png`) picked the launch parameters that
lock the most liquidity per point of trader cost while keeping the curve a credible floor: **15% royalty both
ways, 0.3% pool fee, 100% of LP fees compounding, a smooth 20-step geometric curve, and a hard seed.**
`recommendedIntent` fills all of that in; you supply only what the model cannot know.

```ts
import { recommendedIntent, adviseIntent, buildLaunch } from "@royalty-router/sdk";

const intent = recommendedIntent({
  name: "My Token", symbol: "MYT", reserveToken: d.wnative, feeRecipient: "0x...",
  curve: { freeRange: 1_000n * 10n ** 18n, maxSupply: 1_000_000n * 10n ** 18n, startPrice: 10n ** 14n, endPrice: 10n ** 15n },
  // seed defaults to 80% of the free range paired at the opening price; pass your own to seed harder
});
adviseIntent(intent);            // [] — or a list of {level, code, message} when you override something the model warns about
const built = await buildLaunch(client, d, intent);
```

`adviseIntent` flags: a royalty under 5% (the UI must then quote both venues; funding is ~3× lower), a royalty over
20% (the pool floats in a >50% band and the curve stops being a floor), a pool fee over 1% (costs traders more
than it raises; only cuts mint.club's share), coarse price steps (>2× between neighbours leak the pool's reserve to
arbitrageurs at the boundary), a seed under 10% of the first step's reserve, and partial fee compounding.
`bandBps(mint, burn)` gives the band width the pool will float in.

## Venue quoting (curve vs pool)

The same model shows a UI should **quote both venues and route the whole trade to the better one**: never pool
only, never curve only. Small trades win on the pool, large ones on the curve, and the boundary depends on live
depth and where the pool sits inside the band, so it is a per-quote comparison, not a switch you flip at a time.

```ts
import { readVenueState, quoteVenues, crossoverSize, poolKeyFor } from "@royalty-router/sdk";

const key = poolKeyFor(d, token, ZERO, 3000, 60);                 // as launched
const v = await readVenueState(client, d, token, key);            // bond steps + supply + royalties, pool sqrtPrice + liquidity
const q = quoteVenues(v, "buy", 10n ** 16n);                      // { curve, pool, best: "pool" | "curve", edgeBps }
const x = crossoverSize(v, "buy", 10n ** 18n);                    // trade size above which the curve wins; show the pool below it
```

Pool math is the full-range constant-product case the program position creates (conservative rounding); curve math
mirrors `MCV2_Bond.getReserveForToken` / `getRefundForTokens` exactly, including per-step rounding. Execution
goes through mint.club (`bond.mint` / `bond.burn`) or your Uniswap V4 swap path; the SDK only decides which.

## What it computes for you

| Derived | From |
|---|---|
| `sqrtPriceX96` | the curve's marginal price after the seed mint, so the pool opens exactly where the curve sits |
| `liquidity` | your target seed amounts via Uniswap's `getLiquidityForAmounts` at the spacing-aligned full range |
| `seedConsumed` | what the PoolManager will actually charge (rounds up like v4-core) |
| `maxReserveIn` | mint.club's exact step math including per-step ceil rounding, plus headroom |
| `predictedToken` | mint.club's deterministic ERC-1167 clone address for the symbol |

All of it is checked against values recorded from the live GlueHook and PoolManager on Base (`test/math.test.ts`).

## Keepers

```ts
import { routerStatus, sweepEconomics, sweep } from "@royalty-router/sdk";
const s = await routerStatus(client, router);      // pending, minClaim, ready
const e = await sweepEconomics(client, router, me); // bounty vs gas
if (s.ready) await sweep(client, wallet, router);
```

## CLI

```
RPC=https://mainnet.base.org FACTORY=0x... rr quote  intent.json     # offline: struct, value, approvals, predicted addresses
                                          rr advise intent.json     # offline: where the intent departs from the recommended defaults
RPC=...                                   rr venue  0xToken buy 10000000000000000   # live: curve vs pool quote and crossover size
RPC=... PK=0x... FACTORY=0x...            rr launch intent.json     # approve → simulate → send; prints token, router, poolId
RPC=...                                   rr status 0xRouter
RPC=... PK=0x...                          rr sweep  0xRouter [0xRouter...]
```

Intent JSON uses decimal strings for bigints; see `example.intent.json` (the original 3% launch, which `rr advise` flags) and `example.recommended.intent.json`.

## Development

```
npm run abi     # regenerate src/abi/*.ts from ../out after `forge build`
npm test
npm run build
```
