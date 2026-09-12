"""
cadCAD wrapper around sim.py: the same mechanisms, expressed as state → policy → state-update so cadCAD can
run parameter sweeps (mode × curve royalty × flow regime) with Monte Carlo runs and give a tidy DataFrame.

    .venv/bin/python cadcad_model.py            # ~2–4 min single-threaded; writes cadcad_results.csv + cadcad_sweep.png

State: one dict `sys` holding every scalar of Curve / Pool / Hook / Router / World (rebuilt each step), plus
flattened metrics for analysis. Randomness is seeded per (run, timestep) so runs are reproducible.
"""
from __future__ import annotations
import itertools, math, random, sys as _sys
from dataclasses import fields
import pandas as pd
_sys.path.insert(0, ".")
from sim import Curve, Pool, Hook, Router, World, STEPS, build, recovery

# ───────────────────────────── snapshot / restore ─────────────────────────────
SCALARS = (int, float, str, bool)

def _dump(obj, skip=()):
    return {f.name: getattr(obj, f.name) for f in fields(obj) if f.name not in skip and isinstance(getattr(obj, f.name), SCALARS)}

def snapshot(w: World) -> dict:
    return {
        "curve": {**_dump(w.curve), "steps": w.curve.steps},
        "pool": _dump(w.pool),
        "hook": _dump(w.hook),
        "router": _dump(w.router) if w.router else None,
        "world": {**_dump(w, skip=("t",)), "t": w.t, "pool_share": w.pool_share,
                  "sell_sum": sum(w.sell_real), "sell_n": len(w.sell_real), "buy_sum": sum(w.buy_real), "buy_n": len(w.buy_real)},
        "L0": w.log[0]["L"] if w.log else w.pool.L,
    }

def restore(d: dict) -> World:
    curve = Curve(d["curve"]["steps"]); [setattr(curve, k, v) for k, v in d["curve"].items() if k != "steps"]
    pool = Pool(L=d["pool"]["L"], sqrt_p=d["pool"]["sqrt_p"]); [setattr(pool, k, v) for k, v in d["pool"].items()]
    hook = Hook(pool); [setattr(hook, k, v) for k, v in d["hook"].items()]
    router = None
    if d["router"] is not None:
        router = Router(hook); [setattr(router, k, v) for k, v in d["router"].items()]
    w = World(curve, pool, hook, router)
    for k, v in d["world"].items():
        if k in ("sell_sum", "sell_n", "buy_sum", "buy_n"): continue
        setattr(w, k, v)
    w.log = [{"L": d["L0"]}]
    return w

# ───────────────────────────── cadCAD blocks ─────────────────────────────
T = 1500
N_RUNS = 6

def p_trade(params, substep, history, s):
    d = s["sys"]
    if d is None:                                        # first step: build the world for this parameter subset
        w = build(params["mode"], royalty=params["royalty"])
        w.log = [{"L": w.pool.L}]
        base = snapshot(w); base["world"]["sell_sum"] = 0.0
    else:
        base = d
    w = restore(base)
    sell_sum, sell_n, buy_sum, buy_n = base["world"]["sell_sum"], base["world"]["sell_n"], base["world"]["buy_sum"], base["world"]["buy_n"]
    if params["die_at"] is not None and s["timestep"] > params["die_at"]:   # dead token: no flow at all
        out = snapshot(w); out["world"].update(sell_sum=sell_sum, sell_n=sell_n, buy_sum=buy_sum, buy_n=buy_n); return {"sys": out}
    rng = random.Random(f"{params['seed']}-{s['run']}-{s['timestep']}")
    phase = s["timestep"] / T
    p_buy = 0.5 + params["drift"] * math.sin(2 * math.pi * phase)
    size_e = rng.lognormvariate(math.log(0.02), 0.9)
    if rng.random() < p_buy:
        w.step("buy", size_e)
    else:
        tk = min(size_e / w.pool.price, w.curve.supply * 0.02)
        w.step("sell", tk)
    out = snapshot(w)
    out["world"].update(sell_sum=sell_sum + sum(w.sell_real), sell_n=sell_n + len(w.sell_real),
                        buy_sum=buy_sum + sum(w.buy_real), buy_n=buy_n + len(w.buy_real))
    return {"sys": out}

def s_sys(params, substep, history, s, _in): return "sys", _in["sys"]
def _m(key):
    def f(params, substep, history, s, _in):
        d = _in["sys"]; w = d["world"]; h = d["hook"]; r = d["router"] or {}
        cp = d["curve"]["price"] if "price" in d["curve"] else None
        val = {
            "pool_over_curve": (d["pool"]["sqrt_p"] ** 2) / max(_curve_price(d), 1e-18),
            "L_growth": d["pool"]["L"] / d["L0"] - 1,
            "pot": h["pot"],
            "locked_frac": (h["carry_t"] + h["burned_t"]) / max(d["curve"]["supply"], 1e-9),
            "sell_real": w["sell_sum"] / max(1, w["sell_n"]),
            "buy_real": w["buy_sum"] / max(1, w["buy_n"]),
            "arb_profit": w["arb_profit"],
            "donated": r.get("donated", 0.0), "dao": r.get("dao_income", 0.0), "creator": w["creator_income"] + h["fee_recipient_e"],
            "lp_added_e": 2 * (d["pool"]["L"] - d["L0"]) * d["pool"]["sqrt_p"],
            "recover_e": recovery(restore(d))["recover_e"], "recover_ratio": recovery(restore(d))["recover_ratio"],
            "invested": recovery(restore(d))["invested"],
        }[key]
        return key, val
    return f

def _curve_price(d):
    s = d["curve"]["supply"]
    for r, p in d["curve"]["steps"]:
        if s < r: return p
    return d["curve"]["steps"][-1][1]

METRICS = ["pool_over_curve", "L_growth", "pot", "locked_frac", "sell_real", "buy_real", "arb_profit", "donated", "dao", "creator", "lp_added_e", "recover_e", "recover_ratio", "invested"]

initial_state = {"sys": None, **{m: 0.0 for m in METRICS}}
psubs = [{"policies": {"trade": p_trade}, "variables": {"sys": s_sys, **{m: _m(m) for m in METRICS}}}]

# cartesian sweep → cadCAD's zipped parameter lists
GRID = [(m, r, d, None) for m, r, d in itertools.product(["baseline", "compound", "recycle", "lp"], [0.01, 0.03, 0.05], [0.25, -0.35])]
GRID += [("lp", 0.03, 0.25, die) for die in (300, 750, 1250)]          # dead-token cases: early / at the peak / after the dump
M = {"mode": [g[0] for g in GRID], "royalty": [g[1] for g in GRID], "drift": [g[2] for g in GRID], "die_at": [g[3] for g in GRID], "seed": [7] * len(GRID)}

def run_experiment() -> pd.DataFrame:
    from cadCAD.configuration import Experiment
    from cadCAD.configuration.utils import config_sim
    from cadCAD.engine import ExecutionMode, ExecutionContext, Executor
    exp = Experiment()
    exp.append_model(initial_state=initial_state, partial_state_update_blocks=psubs,
                     sim_configs=config_sim({"N": N_RUNS, "T": range(T), "M": M}))
    ctx = ExecutionContext(context=ExecutionMode().single_mode)
    raw, _, _ = Executor(exec_context=ctx, configs=exp.configs).execute()
    df = pd.DataFrame(raw).drop(columns=["sys"])
    df["mode"] = df["subset"].map(lambda i: GRID[i][0]); df["royalty"] = df["subset"].map(lambda i: GRID[i][1]); df["drift"] = df["subset"].map(lambda i: GRID[i][2])
    df["die_at"] = df["subset"].map(lambda i: GRID[i][3] if GRID[i][3] is not None else -1)
    return df

if __name__ == "__main__":
    df = run_experiment()
    df.to_csv("cadcad_results.csv", index=False)
    final_all = df[df["timestep"] == T]
    final = final_all[final_all["die_at"] < 0]
    dead = final_all[(final_all["die_at"] >= 0) | ((final_all["mode"] == "lp") & (final_all["royalty"] == 0.03) & (final_all["drift"] > 0))]
    agg = final.groupby(["drift", "royalty", "mode"])[["sell_real", "buy_real", "L_growth", "locked_frac", "arb_profit", "pool_over_curve", "pot"]].agg(["mean", "std"])
    pd.set_option("display.width", 200); pd.set_option("display.float_format", lambda v: f"{v:.4f}")
    print(f"\nFinal-state metrics, mean/std over {N_RUNS} Monte Carlo runs × {T} trades\n")
    print(agg.to_string())
    print(f"\nDead-token reclaim (lp, 3% royalty, accumulation→distribution flow): value the DAO recovers at t={T}")
    print(dead.groupby("die_at")[["invested", "recover_e", "recover_ratio", "L_growth"]].agg(["mean", "std"]).rename(index={-1: "alive"}).to_string())

    # chart: sell/buy realization and depth vs royalty, by mode, accumulation regime; MC spread as band
    import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
    COLOR = {"baseline": "#2a78d6", "compound": "#eb6834", "recycle": "#1baf7a", "lp": "#eda100"}
    LABEL = {"baseline": "creator keeps royalties", "compound": "pot → compound", "recycle": "pot → recycle on curve", "lp": "router → locked LP (current)"}
    SURF, INK, INK2, GRID_C = "#fcfcfb", "#0b0b0b", "#52514e", "#e6e5e1"
    fig, axs = plt.subplots(1, 4, figsize=(17, 4.4), facecolor=SURF)
    fig.suptitle("cadCAD sweep — curve royalty × design (accumulation→distribution flow, 6 runs each, band = ±1σ) · dead-token recovery", color=INK, fontsize=12, x=0.02, y=0.99, ha="left")
    panels = [("sell_real", "Sellers: realized ÷ curve price"), ("buy_real", "Buyers: realized ÷ curve price"), ("L_growth", "Pool liquidity growth (× seed)")]
    for ax, (m, title) in zip(axs, panels):
        ax.set_facecolor(SURF); ax.set_title(title, loc="left", color=INK, fontsize=10.5)
        for sp in ("top", "right"): ax.spines[sp].set_visible(False)
        for sp in ("left", "bottom"): ax.spines[sp].set_color(GRID_C)
        ax.tick_params(colors=INK2, labelsize=9); ax.yaxis.grid(True, color=GRID_C, lw=0.8); ax.set_axisbelow(True)
        sub = final[final["drift"] > 0]
        for mode in COLOR:
            g = sub[sub["mode"] == mode].groupby("royalty")[m].agg(["mean", "std"]).reset_index()
            x = g["royalty"] * 100
            ax.plot(x, g["mean"], color=COLOR[mode], lw=2, marker="o", ms=5)
            ax.fill_between(x, g["mean"] - g["std"], g["mean"] + g["std"], color=COLOR[mode], alpha=0.12, lw=0)
        ax.set_xlabel("curve royalty (%)", color=INK2); ax.set_xticks([1, 3, 5])
        if m != "L_growth": ax.axhline(1.0, color=INK2, lw=0.8, ls=":")
    ax = axs[3]; ax.set_facecolor(SURF); ax.set_title("Dead token: DAO recovers ÷ ETH put in", loc="left", color=INK, fontsize=10.5)
    for sp in ("top", "right"): ax.spines[sp].set_visible(False)
    for sp in ("left", "bottom"): ax.spines[sp].set_color(GRID_C)
    ax.tick_params(colors=INK2, labelsize=9); ax.yaxis.grid(True, color=GRID_C, lw=0.8); ax.set_axisbelow(True)
    g = dead.groupby("die_at")["recover_ratio"].agg(["mean", "std"]).reset_index()
    labels = {300: "dies early\n(t=300)", 750: "dies at peak\n(t=750)", 1250: "dies post-dump\n(t=1250)", -1: "alive\n(t=1500)"}
    order = [300, 750, 1250, -1]; g = g.set_index("die_at").loc[order].reset_index()
    ax.bar(range(4), g["mean"], yerr=g["std"], color=COLOR["lp"], width=0.6, capsize=4, ecolor=INK2)
    ax.axhline(1.0, color=INK2, lw=0.8, ls=":"); ax.set_xticks(range(4)); ax.set_xticklabels([labels[k] for k in order], fontsize=8.5, color=INK2)
    from matplotlib.lines import Line2D
    fig.legend([Line2D([0], [0], color=COLOR[k], lw=2.5) for k in COLOR], [LABEL[k] for k in COLOR], loc="upper right", ncol=4, frameon=False, fontsize=9, bbox_to_anchor=(0.99, 0.93))
    plt.tight_layout(rect=(0, 0, 1, 0.86)); plt.savefig("cadcad_sweep.png", dpi=130, facecolor=SURF); print("\ncadcad_sweep.png written")
