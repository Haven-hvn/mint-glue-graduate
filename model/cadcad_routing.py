"""
Routing / graduation study: what should the UI point a trader at, and when?

Sweeps the UI routing policy for the current design (lp) — `best` (quote curve and pool, take the better one),
`pool` (pool only), `curve` (curve only) — against a pump.fun-style `graduate` analog (curve only until a supply
threshold, then the curve closes, its reserve becomes the pool, pool only afterwards, no royalty). Tracks
venue-neutral execution (realized ÷ pool mid before the trade), what funds the locked position, pool depth, and the
"crossover size": the trade size at which the curve beats the pool, i.e. the boundary the UI should switch at.

    .venv/bin/python cadcad_routing.py     # writes cadcad_routing.csv + cadcad_routing.png
"""
import itertools, math, random, sys as _sys
import pandas as pd
_sys.path.insert(0, ".")
import cadcad_model as base
from sim import build
from cadcad_model import restore, snapshot

T = 2000; N_RUNS = 6; XOVER_EVERY = 25; GRAD_AT = 40_000.0; TYPICAL_E = 0.02
GRID = [("lp", 0.03, v, d, 0.0) for v, d in itertools.product(["best", "pool", "curve"], [0.25, 0.0])]
GRID += [("graduate", 0.01, "curve", d, GRAD_AT) for d in (0.25, 0.0)]
M = {"mode": [g[0] for g in GRID], "royalty": [g[1] for g in GRID], "venue": [g[2] for g in GRID], "drift": [g[3] for g in GRID],
     "graduate_at": [g[4] for g in GRID], "seed": [13] * len(GRID)}
ACC = ("bm_sum", "bm_n", "sm_sum", "sm_n", "xb", "xs")

def p_trade(params, substep, history, s):
    d = s["sys"]
    if d is None:
        w = build(params["mode"], royalty=params["royalty"], venue=params["venue"], graduate_at=params["graduate_at"]); w.log = [{"L": w.pool.L}]
        d = snapshot(w); d["world"].update(sell_sum=0.0, sell_n=0, buy_sum=0.0, buy_n=0, bm_sum=0.0, bm_n=0, sm_sum=0.0, sm_n=0, xb=math.nan, xs=math.nan)
    acc = {k: d["world"][k] for k in ACC}
    w = restore({**d, "world": {k: v for k, v in d["world"].items() if k not in ACC}})
    random.seed(f"{params['seed']}-{s['run']}-{s['timestep']}-route")
    rng = random.Random(f"{params['seed']}-{s['run']}-{s['timestep']}")
    p_buy = 0.5 + params["drift"] * math.sin(2 * math.pi * s["timestep"] / T)
    size_e = rng.lognormvariate(math.log(TYPICAL_E), 0.9)
    if rng.random() < p_buy: w.step("buy", size_e)
    else: w.step("sell", min(size_e / w.pool.price, w.curve.supply * 0.02))
    acc["bm_sum"] += sum(w.buy_mid); acc["bm_n"] += len(w.buy_mid); acc["sm_sum"] += sum(w.sell_mid); acc["sm_n"] += len(w.sell_mid)
    if s["timestep"] % XOVER_EVERY == 1: acc["xb"], acc["xs"] = w.crossover_buy(), w.crossover_sell()
    out = snapshot(w); out["world"].update(sell_sum=0.0, sell_n=0, buy_sum=0.0, buy_n=0, **acc)
    return {"sys": out}

def m(key):
    def f(params, substep, history, s, _in):
        d = _in["sys"]; w = d["world"]; h = d["hook"]; r = d["router"] or {}; c = d["curve"]; p = d["pool"]
        return key, {
            "buy_mid": w["bm_sum"] / max(1, w["bm_n"]), "sell_mid": w["sm_sum"] / max(1, w["sm_n"]),
            "roy_trader": w["roy_trader"], "roy_arb": w["roy_arb"], "lp_fees_e": h["fees_seen_e"],
            "lp_added_e": r.get("lp_e", 0.0), "depth_e": 2 * p["L"] * p["sqrt_p"], "pool_share": w["pool_share"] / max(1, w["t"]),
            "xover_buy": w["xb"], "xover_sell": w["xs"], "graduated": float(w["graduated"]), "supply": c["supply"],
            "platform": c["protocol_income"] + w["creator_income"] + h["fee_recipient_e"] + h["fee_recipient_t"] * p["sqrt_p"] ** 2,
            "arb_profit": w["arb_profit"], "pool_over_curve": (p["sqrt_p"] ** 2) / max(base._curve_price(d), 1e-18),
        }[key]
    return f

METRICS = ["buy_mid", "sell_mid", "roy_trader", "roy_arb", "lp_fees_e", "lp_added_e", "depth_e", "pool_share", "xover_buy", "xover_sell",
           "graduated", "supply", "platform", "arb_profit", "pool_over_curve"]

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
    for i, k in enumerate(["mode", "royalty", "venue", "drift"]): df[k] = df["subset"].map(lambda j: GRID[j][i])
    df["design"] = df.apply(lambda r: f"{r['mode']}/{r['venue']}" if r["mode"] == "lp" else "pump.fun-style graduate", axis=1)
    df.to_csv("cadcad_routing.csv", index=False)
    fin = df[df["timestep"] == T].copy(); fin["roy_total"] = fin.roy_trader + fin.roy_arb
    pd.set_option("display.width", 220); pd.set_option("display.float_format", lambda v: f"{v:.4f}")
    print(f"\nUI routing policy × market regime — final state, mean over {N_RUNS} runs × {T} trades\n")
    print(fin.groupby(["drift", "design"])[["buy_mid", "sell_mid", "depth_e", "lp_added_e", "roy_total", "lp_fees_e", "pool_share", "arb_profit", "platform", "graduated"]].mean().to_string())
    xo = df[(df.design == "lp/best") & (df.timestep % XOVER_EVERY == 1) & (df.timestep > 1)].groupby(["drift", "timestep"])[["xover_buy", "xover_sell", "depth_e"]].median().reset_index()
    print("\nCrossover trade size (E) where the curve beats the pool — lp/best, median over runs (typical trade 0.02 E):")
    print(xo[xo.timestep.isin([26, 251, 501, 1001, 1501, 1976])].to_string(index=False))

    import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
    SURF, INK, INK2, GRID_C = "#fcfcfb", "#0b0b0b", "#52514e", "#e6e5e1"
    C = {"lp/best": "#2a78d6", "lp/pool": "#eb6834", "lp/curve": "#1baf7a", "pump.fun-style graduate": "#eda100"}
    LAB = {"lp/best": "router · UI quotes both, routes to better", "lp/pool": "router · UI shows pool only", "lp/curve": "router · UI shows curve only", "pump.fun-style graduate": "pump.fun-style graduation (no royalty)"}
    def style(ax, title):
        ax.set_facecolor(SURF); ax.set_title(title, loc="left", color=INK, fontsize=10.5)
        for sp in ("top", "right"): ax.spines[sp].set_visible(False)
        for sp in ("left", "bottom"): ax.spines[sp].set_color(GRID_C)
        ax.tick_params(colors=INK2, labelsize=9); ax.yaxis.grid(True, color=GRID_C, lw=0.8); ax.set_axisbelow(True)
    fig, axs = plt.subplots(1, 3, figsize=(17, 4.6), facecolor=SURF)
    fig.suptitle("Where should the UI send a trade? — routing policy × pump.fun-style graduation (6 runs, net-buying regime)", color=INK, fontsize=12, x=0.02, y=0.99, ha="left")
    sub = fin[fin.drift == 0.25]
    ax = axs[0]; style(ax, "Trader execution ÷ pool mid (buys, sells)")
    g = sub.groupby("design")[["buy_mid", "sell_mid"]].agg(["mean", "std"]); order = list(C)
    x = range(len(order)); wd = 0.38
    for k, (col, hatch) in enumerate([("buy_mid", None), ("sell_mid", "////")]):
        ax.bar([i + (k - 0.5) * wd for i in x], g[(col, "mean")].loc[order] - 0.9, bottom=0.9, yerr=g[(col, "std")].loc[order], width=wd - 0.03,
               color=[C[o] for o in order], hatch=hatch, edgecolor=SURF, linewidth=1.5, capsize=3, ecolor=INK2)
    ax.axhline(1.0, color=INK2, lw=0.8, ls=":"); ax.set_xticks(list(x)); ax.set_xticklabels(["quote both", "pool only", "curve only", "graduate"], color=INK2, fontsize=9)
    ax.text(0.02, 0.96, "solid = buys · hatched = sells", transform=ax.transAxes, fontsize=8.5, color=INK2, va="top")
    ax = axs[1]; style(ax, "Pool depth over time (E-equivalent, median run)")
    for dsg in order:
        g = df[(df.drift == 0.25) & (df.design == dsg) & (df.timestep > 0)].groupby("timestep")["depth_e"].median()
        g = g[g > 1e-3]                                            # the pump.fun analog has no pool before graduation
        ax.plot(g.index, g.values, color=C[dsg], lw=2)
    ax.set_xlabel("trade #", color=INK2); ax.set_yscale("log"); ax.set_ylim(0.3, 30)
    ax.text(0.02, 0.06, "graduate: no pool until the curve closes (≈ trade 250–330)", transform=ax.transAxes, fontsize=8.5, color=INK2)
    ax = axs[2]; style(ax, "Trade size where the curve beats the pool (E, lp/best, rolling median)")
    g = xo[xo.drift == 0.25].set_index("timestep").clip(lower=1e-4, upper=10).rolling(7, center=True, min_periods=1).median().reset_index()
    ax.plot(g.timestep, g.xover_buy, color="#2a78d6", lw=2, label="buys")
    ax.plot(g.timestep, g.xover_sell, color="#2a78d6", lw=2, ls="--", label="sells")
    ax.axhline(TYPICAL_E, color=INK2, lw=0.8, ls=":"); ax.text(g.timestep.max(), TYPICAL_E * 1.15, "typical trade", ha="right", fontsize=8.5, color=INK2)
    ax.set_yscale("log"); ax.set_xlabel("trade #", color=INK2); ax.legend(frameon=False, fontsize=9, loc="upper left")
    ax.text(0.02, 0.08, "below the line → show the pool · above → show the curve", transform=ax.transAxes, fontsize=8.5, color=INK2)
    from matplotlib.lines import Line2D
    fig.legend([Line2D([0], [0], color=C[k], lw=2.5) for k in order], [LAB[k] for k in order], loc="upper right", ncol=2, frameon=False, fontsize=9, bbox_to_anchor=(0.99, 0.95))
    plt.tight_layout(rect=(0, 0, 1, 0.85)); plt.savefig("cadcad_routing.png", dpi=130, facecolor=SURF); print("\ncadcad_routing.png written")
