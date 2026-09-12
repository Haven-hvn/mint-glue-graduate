import math, random, sys
sys.path.insert(0, ".")
from sim import run
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt

MODES = ["baseline", "compound", "recycle", "lp"]
LABEL = {"baseline": "creator keeps royalties", "compound": "pot → compound (current)", "recycle": "pot → recycle on curve", "lp": "router → locked LP"}
SHORT = {"baseline": "creator keeps", "compound": "pot → compound", "recycle": "pot → recycle", "lp": "router → LP"}
COLOR = {"baseline": "#2a78d6", "compound": "#eb6834", "recycle": "#1baf7a", "lp": "#eda100"}  # fixed order, validated
SURF, INK, INK2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e6e5e1"

worlds = {m: run(m, 3) for m in MODES}
fig, axs = plt.subplots(2, 2, figsize=(12, 8), facecolor=SURF)
fig.suptitle("Where a mint.club creator royalty goes, and what it does — one seed, 3,000 trades", color=INK, fontsize=13, x=0.02, y=0.995, ha="left")
for ax in axs.flat:
    ax.set_facecolor(SURF)
    for sp in ("top", "right"): ax.spines[sp].set_visible(False)
    for sp in ("left", "bottom"): ax.spines[sp].set_color(GRID)
    ax.tick_params(colors=INK2, labelsize=9); ax.yaxis.grid(True, color=GRID, lw=0.8); ax.set_axisbelow(True)

def endlabel(ax, x, y, text, color):
    pass  # identity is carried by the shared legend + fixed colors; end labels collided

# 1. pot balance over time
ax = axs[0, 0]; ax.set_title("Pot balance (ETH)", loc="left", color=INK, fontsize=11)
for m in ("compound", "recycle"):
    lg = worlds[m].log; ys = [r["pot"] for r in lg]
    ax.plot([r["t"] for r in lg], ys, color=COLOR[m], lw=2); endlabel(ax, lg[-1]["t"], ys[-1], LABEL[m], COLOR[m])
ax.set_xlim(0, 3100); ax.set_xlabel("trade #", color=INK2)

# 2. pool price relative to the curve
ax = axs[0, 1]; ax.set_title("Pool price ÷ curve price (band = royalty + pool fee)", loc="left", color=INK, fontsize=11)
w0 = worlds["baseline"]; r_, f_ = w0.curve.mint_royalty, w0.pool.fee
ax.axhspan((1 - r_) * (1 - f_), (1 + r_) / (1 - f_), color=GRID, alpha=0.6, lw=0)
for m in MODES:
    lg = worlds[m].log; ys = [r["pool_price"] / r["curve_price"] if r["curve_price"] > 0 else float("nan") for r in lg]
    # smooth: rolling median of 25 for legibility
    sm = [sorted(ys[max(0, i - 12): i + 13])[len(ys[max(0, i - 12): i + 13]) // 2] for i in range(len(ys))]
    ax.plot([r["t"] for r in lg], sm, color=COLOR[m], lw=2); endlabel(ax, lg[-1]["t"], sm[-1], LABEL[m], COLOR[m])
ax.set_ylim(0.9, 1.1); ax.set_xlim(0, 3100); ax.set_xlabel("trade #", color=INK2)
ax.text(40, 1.092, "spikes = single large trades before arbitrage closes the gap", fontsize=8, color=INK2)

# 3. liquidity growth
ax = axs[1, 0]; ax.set_title("Pool liquidity L (× seed)", loc="left", color=INK, fontsize=11)
for m in MODES:
    lg = worlds[m].log; ys = [r["L"] / lg[0]["L"] for r in lg]
    ax.plot([r["t"] for r in lg], ys, color=COLOR[m], lw=2); endlabel(ax, lg[-1]["t"], ys[-1], LABEL[m], COLOR[m])
ax.set_xlim(0, 3100); ax.set_xlabel("trade #", color=INK2)

# 4. destinations of royalty value (ETH), 12-seed mean
from sim import summary
S = {m: [summary(run(m, s)) for s in range(12)] for m in MODES}
mean = lambda m, k: sum(r[k] for r in S[m]) / len(S[m])
ax = axs[1, 1]; ax.set_title("Where the royalty ETH ends up (mean of 12 seeds)", loc="left", color=INK, fontsize=11)
cats = [("creator", "creator wallet"), ("dao", "DAO"), ("stranded_reserve", "locked tokens (stranded reserve)"),
        ("arb_excess", "arbitrageurs"), ("lp_added_e", "pool depth added"), ("pot", "pot remaining")]
base_arb = mean("baseline", "arb_profit")
vals = {m: {k: (mean(m, "arb_profit") - base_arb if k == "arb_excess" else mean(m, k)) for k, _ in cats} for m in MODES}
shades = ["#2a78d6", "#7fb0e8", "#eb6834", "#eda100", "#1baf7a", "#8ed6bd"]
x = range(len(MODES)); bottoms = [0.0] * len(MODES)
for (k, name), sh in zip(cats, shades):
    hs = [max(0.0, vals[m][k]) for m in MODES]
    ax.bar(x, hs, bottom=bottoms, color=sh, width=0.6, edgecolor=SURF, linewidth=2, label=name)
    bottoms = [b + h for b, h in zip(bottoms, hs)]
ax.set_xticks(list(x)); ax.set_xticklabels([SHORT[m] for m in MODES], fontsize=9, color=INK2)
ax.set_ylabel("ETH", color=INK2); ax.legend(fontsize=8, frameon=False, loc="upper left", bbox_to_anchor=(1.0, 1.0))
from matplotlib.lines import Line2D
fig.legend([Line2D([0], [0], color=COLOR[m], lw=2.5) for m in MODES], [LABEL[m] for m in MODES], loc="upper right", ncol=4, frameon=False, fontsize=9, bbox_to_anchor=(0.98, 0.955))
plt.tight_layout(rect=(0, 0, 0.98, 0.91)); plt.savefig("charts.png", dpi=130, facecolor=SURF); print("charts.png written")
