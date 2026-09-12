# mint-glue-graduate — pump.fun-style graduation for mint.club curves into locked Uniswap V4 liquidity

> mint.club has no graduate. This is it, via [GlueHook](https://github.com/glue-finance/GlueHook). Launch a bonding-curve token + Uniswap V4 pool + royalty-fed LP program in **one transaction**. Creator royalties auto-compound into **permanently locked** depth — no migration, no custody, curve stays live as floor and funder.
>
> Unofficial. Built on [mint.club](https://mint.club) + GlueHook. Not affiliated with either.

```
mint.club Bond ──royalty (reserve ERC20)──▶ RoyaltyRouter ──┬─ ½ → bond.mint(token)   ┐
                                                 │           └─ ½ → SECONDARY          ┴─▶ hook.addProgramLiquidity (locked forever)
                                        ├─ DAO take  → DAO (in reserve; governed in the factory, capped)
                                        └─ BOUNTY    → keeper (in reserve)
```

Why liquidity and not a buyback pot: see `model/` — under a bonding curve, arbitrage pins the pool inside the royalty band, so a pot can only ever move price a few percent, and every token it buys strands its reserve in the bond. Locked liquidity beat every pot variant on seller execution, buyer execution, depth, and leakage.

Two contracts, composed from two existing legos:

| Contract | Role |
|---|---|
| `RoyaltyRouter` | Holds the bond-creator role AND the LP-program owner/operator roles for **one** token. Public entries: `sweep()` and `heartbeat()`. No withdraw, no `transferProgramOwnership`, no `setProgramConfig`; the only remove path is the dead-token `reclaim()` below. Reads the DAO take from the factory at sweep time and clamps it to a ceiling copied at birth. |
| `RoyaltyRouterFactory` | Deployed once per chain. Its only door is `launch()`: a new token, its pool, and its router in **one transaction**. Holds the **one governed knob**: the DAO address and rate, movable by `governance`, never above the immutable `MAX_DAO_BPS`. |

`src/swappers/UniswapV3Swapper.sol` is an optional reference `ISwapper` for the one route that needs a swap.

## How `sweep(minOut)` works

1. Claim accrued royalties from the bond (skipped when zero).
2. Take `BOUNTY_BPS` for `msg.sender` and the factory's current DAO take for the DAO, both in the reserve token.
3. Buy the token side **on the curve** with `net·(1+r)/(2+r)` of the rest, where `r` is the curve's mint royalty, so both sides carry equal value. No pool swap, no MEV, and 80% of that mint's royalty accrues straight back to the router.
4. Convert the remaining reserve to the pool's SECONDARY: nothing when they are the same asset, unwrap when reserve is WETH and the pool is native, otherwise the immutable `ISwapper` with the caller's `minOut`.
5. Read the pool's sqrt price from the PoolManager, compute full-range liquidity for everything held (stray transfers included), and `addProgramLiquidity`. The hook harvests pending fees first, then pulls exact amounts. Rounding leftovers stay in the router for the next sweep.
6. If the curve is sold out (max supply) the token side cannot be bought; the sweep falls back to donating the SECONDARY to the pot.

Reverts with `BelowMinimum` when the claimable amount is under `MIN_CLAIM`. Anyone can call it.

## One-click launch (new token)

`factory.launch(L)` does everything from a fresh wallet in one transaction:

1. `bond.createToken` — the factory pays the creation fee out of `msg.value` and is the creator for two calls
2. `bond.updateBondCreator(token, predictedRouter)` — before anything else can accrue a royalty
3. `bond.mint` seed tokens from the curve using the caller's reserve (optional, `curveMint`) — that mint's royalty is already the router's
4. `hook.launchPool` — full range, program **owner and operator = the router's predicted address**. The router has no remove, transfer, or config path, so liquidity is locked and rules are frozen by construction. Public harvest on; buyback, burn, and pot shares at zero
5. deploy the router at the predicted address
6. refund leftover tokens, reserve, secondary, and ETH to the caller

The factory becomes the pot admin. It has no `setRecipient` path, so the pot's recipient is frozen too. Nothing about the launched system can be changed afterwards except the DAO take (see Governance). The pot itself is unused unless the curve sells out.

Caller brings: `msg.value` = creation fee + native seed when the pool's other side is ETH; an allowance to the factory for `maxReserveIn` reserve when `curveMint > 0`, and for `secondarySeed` when the other side is an ERC20. A zero-price first curve step mints `stepRanges[0]` tokens for free, which is the cheapest way to fund the token side of the seed.

Economics these defaults encode, from the model in `model/` (a bonding-curve token is not a fixed-supply token):

- The curve pins the pool between its mint and burn prices. Anything a pot does happens inside that band, a few percent wide.
- Every token a pot removes from circulation strands its reserve in the bond and never moves the curve price.
- Locked liquidity compounds: deeper pool, better execution for both buyers and sellers, LP fees re-minted into the same position, nothing leaks to arbitrageurs.
- Buying the token side on the curve instead of the pool avoids swaps and MEV, and recycles most of the royalty.

`sqrtPriceX96` must equal the price the curve currently quotes. Compute it off-chain.

## Choosing launch parameters

The curve royalty is the only knob that matters and it is immutable per token, so pick it from the model, not by feel. `model/cadcad_routing.py` and `model/plot_mix.py` sweep royalty × pool fee × UI routing policy against a pump.fun-style graduation; `model/cadcad_mix.png` is the summary chart.

| Parameter | Recommended | Why |
|---|---|---|
| Curve royalty (mint and burn) | **15%** | ETH locked per point of trader cost rises with the rate; it plateaus near 20% in a flat market, and above that the band the pool floats in (mint ceiling ÷ burn floor) exceeds 50% and the curve stops being a floor. 15% gives 2–3× the locked liquidity of 3% at about the same per-trade cost, with a 35% band. |
| Pool fee | **0.3%** | Every point of pool fee costs traders more than it raises. Its one distinct effect is cutting mint.club's 20% share of the tax; raise it only if that becomes the priority. |
| LP fee compounding | 100% | The depth figures assume every fee re-mints into the position. |
| Curve shape | smooth, ~20 geometric steps | A 10× step hands the pool's reserve to arbitrageurs when supply crosses back below it. |
| Pool seed | as large as you can | Depth, not the tax, is what buys execution. The one thing a graduation dump does better is depth at launch. |

**UI venue rule: quote the curve and the pool, route the whole trade to the better one.** Small trades win on the pool, large ones on the curve, and the boundary depends on live depth and where the pool sits in the band, so it is a per-quote comparison, not a time-based flip. Pool-only costs traders 2–3 points at a low royalty and leaks the difference to arbitrageurs; curve-only collects the most royalty but traders pay for it. At 15%+ the pool wins roughly two thirds of trades and a pool-first screen with the curve shown when it wins is fine. `sdk` ships `recommendedIntent`, `adviseIntent`, `quoteVenues`, and `crossoverSize` for exactly this.

**Why not graduate like pump.fun.** Migrating the curve's reserve into a pool and closing the curve gives the best fills of anything modelled, purely from concentrated depth, and pays for it with no price floor, no ongoing funding, and a binary outcome (most tokens never reach the threshold). At 15% the pool already behaves as the primary venue from the first trade, so the pool-first experience comes without giving up the curve.

**Why not an on-chain venue router.** At a high royalty it is worth about one point of execution and slightly reduces funding, since arbitrageurs stop paying the royalty on traders' behalf. Build it later, as a separate stateless contract, never inside `RoyaltyRouter`.

**Unmodelled.** Order flow is held fixed. Whether a 15% headline rate deters people before they find the pool is cheap is a demand question the simulation cannot answer; two small live launches at 5% and 15% would.

## Existing tokens

Not supported, by design. Both protocols gate their role moves on `msg.sender`, so wiring a pre-existing token would need the creator to hand roles to the factory across several transactions, plus an entry point that accepts arbitrary existing pools and configs. `launch` is the only door, so every launched system has the same frozen shape.

## Constraints

**mint.club's 20% protocol cut** is taken before the router sees anything and is not routable.

**Per-trade atomicity is impossible.** mint.club has no mint or burn hooks, so royalties are batched by `sweep`. Nothing runs on its own: set `BOUNTY_BPS` and `MIN_CLAIM` so a sweep pays for its gas on your chain.

**Pick the reserve token for a swap-free route.** mint.club's reserve is immutable at token creation. Use a WETH reserve with a native-ETH pool, or make the reserve the pool's other asset. Any other combination needs an `ISwapper`, which is exposed to keeper self-sandwiching (see Trust model). `launch` refuses a swapper on a swap-free route and demands one otherwise.

**Glueable main.** The hook wraps the token via the Glue Protocol at pot creation, best effort. A mint.club token is a plain ERC20 clone, so this should succeed. With burn shares at zero the unglue path never runs anyway.

## Dead-token recovery

Liquidity of a token nobody trades anymore is not stuck forever, and nobody can touch liquidity while anyone trades. Both facts come from on-chain evidence, not from an oracle or a vote:

- **Activity** = unclaimed curve royalties on the bond, or pool fees the hook harvests. Any mint, burn, or swap anywhere leaves one of these.
- Every `sweep` stamps `lastActive`. `heartbeat()` is a permissionless read-and-stamp for tokens trading only on the pool; keepers call it when a sweep isn't due.
- After `STALE_PERIOD` (factory immutable, ≥ 90 days; 365 recommended) with no stamp, the DAO may `initiateReclaim()`. It re-checks live activity first; if it finds any it stamps and returns false.
- A `GRACE_PERIOD` (≥ 7 days; 30 recommended) then runs. Any sweep or heartbeat that finds activity cancels the reclaim.
- After the window, `reclaim()` re-checks once more, then removes the whole position, **both sides**, plus any router leftovers, to the DAO treasury. The router stays creator and owner; a revived token simply starts adding liquidity again.

The token side of a dead token can still be burned on the mint.club curve for reserve, so the DAO's recovery is close to full value. Pot funds (sold-out fallback only) are not recoverable.

## Keepers

Nothing calls `sweep` on its own. The bounty makes it a public profit opportunity, so MEV searchers will pick it up once bounty exceeds gas, but at launch you should run one yourself.

- `keeper/sweep.sh` — a `cast`-based cron job. Reads `pending()` and `MIN_CLAIM()`, simulates, then sends. Any funded EOA works; it receives the bounty.
- No-code alternatives: Gelato Automate or Chainlink Automation with a condition of `pending() >= MIN_CLAIM()` and an action of `sweep(0)`.
- On a swap-free route pass `minOut = 0`. On a swapper route the keeper should quote and pass a real floor, since it is the only slippage protection.

Sizing: on Base a 0.5% bounty clears gas at claims of a few dollars. On Ethereum mainnet raise `MIN_CLAIM` so a sweep is worth roughly $50+ before it triggers.

## Governance

The DAO take is the only parameter anyone can change after deploy, and it lives in the factory:

```solidity
factory.setFee(dao, daoBps);        // governance only; daoBps ≤ MAX_DAO_BPS; applies to every router's next sweep
factory.setGovernance(newGov);      // governance only; address(0) renounces and freezes the fee forever
```

`MAX_DAO_BPS` is set at factory deploy, capped at 50%, and immutable. Every router copies it at birth and clamps whatever the factory reports, so even a compromised factory cannot push a router past the ceiling it was deployed under. A governance change or a fee change never touches routers: they hold no fee state.

Deploy order when the DAO is governed by a token this factory will launch: deploy the treasury (a timelock) first with the deployer as proposer, deploy the factory pointing `dao` at it and `governance` at the timelock, launch the token, deploy a Governor over the token, grant it the timelock roles, renounce the deployer. The treasury address never changes, so nothing is misrouted while governance is being attached. Note that mint.club tokens are plain ERC20 without vote checkpoints, so an on-chain Governor needs a vote-wrapper.

## Trust model

| Surface | Trust |
|---|---|
| Router | Value exits only to the locked position, the keeper, the DAO take, or, for a token with zero activity for a year plus a grace month, the DAO via `reclaim`. The DAO cannot shorten those periods or bypass the live activity checks. |
| Factory | `governance` can move the DAO address and rate within `MAX_DAO_BPS`, and can hand over or renounce. Nothing else. It holds funds only inside a `launch` call and refunds everything before returning. As pot admin of launched pools it holds a frozen `setRecipient` power it cannot exercise. |
| `ISwapper` | The only trust surface, and only on the swap route. It is fixed at deploy. The reference V3 swapper relies on the caller's `minOut`, so a keeper can sandwich themselves and skim from the pot. Prefer a swap-free route. |
| mint.club, GlueHook | Inherited. The 20% protocol cut is not routable. |

Constructor caps: bounty ≤ 10% per router, `MAX_DAO_BPS` ≤ 50% per factory.

## SDK and CLI

`sdk/` is a viem-based TypeScript package for browsers, Node, and a CLI. It turns a human launch intent into the contract struct, derives `sqrtPriceX96`, `liquidity`, `maxReserveIn`, `msg.value` and the approvals, predicts the token and router addresses, and refuses bad inputs before you sign. Keeper helpers replace the bash script. See `sdk/README.md`.

## Build

```
forge build
forge test                            # unit tests (mocks)
FOUNDRY_PROFILE=fork forge test -vv   # end-to-end against live mint.club + GlueHook on Base (BASE_RPC to override)
```

Deploy the factory: `script/Deploy.s.sol:DeployFactory` (env: `BOND`, `HOOK`, `GOVERNANCE`, `DAO`, `DAO_BPS`, `MAX_DAO_BPS`).
Launch a token: call `factory.launch(L)` with the struct in `RoyaltyRouterFactory.sol`. Both protocols are live on Base; the hook is at `0x0F41715dc432692b66A5aDF8dCfef6Ac407b20c8` on every supported chain.
