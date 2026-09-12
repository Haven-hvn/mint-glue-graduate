# Tokenomics model

Pure-Python simulation of the three legos together: mint.club step curve (royalties, 20% protocol cut),
Uniswap V4 full-range pool (constant product with liquidity L, 0.3% fee, LP-fee split per ProgramConfig),
GlueHook pot (pump capped at 0.8·min(pot, fee·depth, buy); shield at the pool's own execution price;
compound carry), the RoyaltyRouter (DAO cut, bounty, donate), and rational chunked arbitrage that keeps
the pool inside the curve's band.

```
python3 sim.py                 # scenario tables (12 seeds × 3,000 trades)
.venv/bin/python plot.py       # charts.png   (python3 -m venv .venv && .venv/bin/pip install matplotlib)
```

Modes: `baseline` (creator keeps royalties, plain LP), `compound` (what the contracts do today),
`recycle` (pot recipient burns absorbed tokens on the curve and donates the refund), `lp` (router skips the
pot and mints locked full-range liquidity with the royalties — **what the contracts now do**; on-chain the
token side is bought on the curve rather than the pool, which the model's `lp` mode approximates with a pool buy).

## cadCAD

`cadcad_model.py` wraps the same mechanisms as a cadCAD model: one `sys` state dict (every scalar of Curve /
Pool / Hook / Router, rebuilt each step), a single trade policy per timestep seeded per (run, timestep), and
state-update functions that flatten the metrics. It sweeps mode × curve royalty × flow regime (24 subsets)
with Monte Carlo runs and writes `cadcad_results.csv` and `cadcad_sweep.png`.

```
.venv/bin/pip install cadCAD pandas
.venv/bin/python cadcad_model.py      # ~15 s for 24 subsets × 6 runs × 1,500 trades
```

Read the Monte Carlo spread before the means: execution-quality differences between designs are mostly
inside ±1σ, liquidity-growth differences are not.

## Routing and graduation (`cadcad_routing.py`)

Which venue should the UI point a trader at, and is a pump.fun-style graduation better? Sweeps the UI routing
policy for the current design (`best` = quote curve and pool, take the better; `pool` only; `curve` only; `split` = on-chain aggregator that fills the pool up to the curve price and sends the rest to the curve) against a
`graduate` analog (curve only, 1% fee, no pool until supply hits a threshold, then the curve closes and its reserve
becomes the pool, pool only after, no royalty). Adds `World.venue`, `World.graduate_at`, venue-neutral execution
(`buy_mid`/`sell_mid` = realized ÷ pool mid before the trade) and `crossover_buy()`/`crossover_sell()`, the trade
size at which the curve beats the pool. Writes `cadcad_routing.csv` and `cadcad_routing.png`.

```
.venv/bin/python cadcad_routing.py    # ~10 s, 8 subsets × 6 runs × 2,000 trades
```
