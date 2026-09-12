"""
Venue study: what happens to the royalty stream when trading migrates to the Uniswap pool?
Sweeps pool_bias (share of traders who use the pool regardless of price) × market regime (net-buying vs
range-bound) for the current design (lp). Tracks who generates curve royalties — traders or arbitrageurs —
and how much the program position earns in LP fees instead.

    .venv/bin/python cadcad_venue.py     # writes cadcad_venue.csv + cadcad_venue.png
"""
import itertools, math, random, sys as _sys
import pandas as pd
_sys.path.insert(0, ".")
import cadcad_model as base
from sim import build
from cadcad_model import restore, snapshot

T = 2000; N_RUNS = 6
GRID = [("lp", 0.03, drift, bias) for drift, bias in itertools.product([0.25, 0.0], [0.0, 0.5, 1.0])]
M = {"mode": [g[0] for g in GRID], "royalty": [g[1] for g in GRID], "drift": [g[2] for g in GRID], "pool_bias": [g[3] for g in GRID],
     "die_at": [None] * len(GRID), "seed": [11] * len(GRID)}

def p_trade(params, substep, history, s):
    d = s["sys"]
    if d is None:
        w = build(params["mode"], royalty=params["royalty"], pool_bias=params["pool_bias"]); w.log = [{"L": w.pool.L}]
        d = snapshot(w); d["world"]["sell_sum"] = 0.0
    w = restore(d)
    random.seed(f"{params['seed']}-{s['run']}-{s['timestep']}-venue")
    rng = random.Random(f"{params['seed']}-{s['run']}-{s['timestep']}")
    p_buy = 0.5 + params["drift"] * math.sin(2 * math.pi * s["timestep"] / T)
    size_e = rng.lognormvariate(math.log(0.02), 0.9)
    if rng.random() < p_buy: w.step("buy", size_e)
    else: w.step("sell", min(size_e / w.pool.price, w.curve.supply * 0.02))
    out = snapshot(w); out["world"].update(sell_sum=0.0, sell_n=0, buy_sum=0.0, buy_n=0)
    return {"sys": out}

def m(key):
    def f(params, substep, history, s, _in):
        d = _in["sys"]; w = d["world"]; h = d["hook"]; r = d["router"] or {}
        return key, {"roy_trader": w["roy_trader"], "roy_arb": w["roy_arb"], "lp_fees_e": h["fees_seen_e"],
                     "donated": r.get("donated", 0.0), "L_growth": d["pool"]["L"] / d["L0"] - 1,
                     "pool_share": w["pool_share"] / max(1, w["t"]), "supply": d["curve"]["supply"]}[key]
    return f

METRICS = ["roy_trader", "roy_arb", "lp_fees_e", "donated", "L_growth", "pool_share", "supply"]

if __name__ == "__main__":
    from cadCAD.configuration import Experiment
    from cadCAD.configuration.utils import config_sim
    from cadCAD.engine import ExecutionMode, ExecutionContext, Executor
    exp = Experiment()
    exp.append_model(initial_state={"sys": None, **{k: 0.0 for k in METRICS}},
                     partial_state_update_blocks=[{"policies": {"trade": p_trade}, "variables": {"sys": base.s_sys, **{k: m(k) for k in METRICS}}}],
                     sim_configs=config_sim({"N": N_RUNS, "T": range(T), "M": M}))
    raw, _, _ = Executor(exec_context=ExecutionContext(context=ExecutionMode().single_mode), configs=exp.configs).execute()
    df = pd.DataFrame(raw).drop(columns=["sys"])
    df["drift"] = df["subset"].map(lambda i: GRID[i][2]); df["pool_bias"] = df["subset"].map(lambda i: GRID[i][3])
    df.to_csv("cadcad_venue.csv", index=False)
    final = df[df["timestep"] == T].copy()
    final["roy_total"] = final["roy_trader"] + final["roy_arb"]
    pd.set_option("display.width", 200); pd.set_option("display.float_format", lambda v: f"{v:.4f}")
    print(f"\nRoyalty stream vs. venue migration (lp mode, 3% royalty, {N_RUNS} runs × {T} trades, ETH)\n")
    print(final.groupby(["drift", "pool_bias"])[["roy_trader", "roy_arb", "roy_total", "lp_fees_e", "L_growth", "pool_share"]].mean().to_string())

    import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
    SURF, INK, INK2, GRID_C = "#fcfcfb", "#0b0b0b", "#52514e", "#e6e5e1"
    C_TR, C_ARB, C_FEE = "#2a78d6", "#eb6834", "#1baf7a"
    fig, axs = plt.subplots(1, 2, figsize=(12, 4.4), facecolor=SURF)
    fig.suptitle("Who funds the position as trading moves to the pool? (lp mode, 3% royalty, 6 runs)", color=INK, fontsize=12, x=0.02, y=0.99, ha="left")
    for ax, drift, title in zip(axs, [0.25, 0.0], ["Net-buying market (accumulation → distribution)", "Range-bound market (no net new demand)"]):
        ax.set_facecolor(SURF); ax.set_title(title, loc="left", color=INK, fontsize=10.5)
        for sp in ("top", "right"): ax.spines[sp].set_visible(False)
        for sp in ("left", "bottom"): ax.spines[sp].set_color(GRID_C)
        ax.tick_params(colors=INK2, labelsize=9); ax.yaxis.grid(True, color=GRID_C, lw=0.8); ax.set_axisbelow(True)
        g = final[final["drift"] == drift].groupby("pool_bias")[["roy_trader", "roy_arb", "lp_fees_e"]].mean()
        x = range(len(g)); b = [0.0] * len(g)
        for col, c, lab in [("roy_trader", C_TR, "royalty: traders on the curve"), ("roy_arb", C_ARB, "royalty: arbitrageurs"), ("lp_fees_e", C_FEE, "LP fees on the position")]:
            ax.bar(x, g[col], bottom=b, color=c, width=0.6, edgecolor=SURF, linewidth=2, label=lab); b = [bi + v for bi, v in zip(b, g[col])]
        ax.set_xticks(list(x)); ax.set_xticklabels([f"{int(p*100)}% of traders\nalways use the pool" for p in g.index], fontsize=8.5, color=INK2)
        ax.set_ylabel("ETH over the run", color=INK2)
    h, l = axs[0].get_legend_handles_labels()
    fig.legend(h, l, loc="upper right", ncol=3, frameon=False, fontsize=9, bbox_to_anchor=(0.99, 0.94))
    plt.tight_layout(rect=(0, 0, 1, 0.88)); plt.savefig("cadcad_venue.png", dpi=130, facecolor=SURF); print("\ncadcad_venue.png written")
