"""Chart for the funding-mix sweep (curve royalty × pool fee). Reads cadcad_mix_summary.csv, writes cadcad_mix.png."""
import pandas as pd, numpy as np
import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
from matplotlib.colors import LinearSegmentedColormap
from matplotlib.patches import Rectangle
from matplotlib.lines import Line2D

g = pd.read_csv("cadcad_mix_summary.csv")
SURF, INK, INK2, GRID_C = "#fcfcfb", "#0b0b0b", "#52514e", "#e6e5e1"
SEQ = ["#a9c9ee", "#7fb0e6", "#4d8fdc", "#2a6ec4", "#123f7a"]           # one hue, light → dark (pool fee 0.3% … 10%)
FEES = [0.003, 0.01, 0.03, 0.05, 0.10]; FEE_C = dict(zip(FEES, SEQ)); FEE_L = {0.003: "0.3%", 0.01: "1%", 0.03: "3%", 0.05: "5%", 0.10: "10%"}
ROY = sorted(g.royalty.unique())
band = lambda r: 100 * ((1 + r) / (1 - r) - 1)

def style(ax, title):
    ax.set_facecolor(SURF); ax.set_title(title, loc="left", color=INK, fontsize=10.5)
    for sp in ("top", "right"): ax.spines[sp].set_visible(False)
    for sp in ("left", "bottom"): ax.spines[sp].set_color(GRID_C)
    ax.tick_params(colors=INK2, labelsize=9); ax.set_axisbelow(True)

fig, axs = plt.subplots(1, 3, figsize=(17.5, 5.2), facecolor=SURF)
fig.suptitle("Funding mix: curve royalty × pool fee — ETH locked per 1% of round-trip trader cost (best-of-two routing, 6 runs × 2,000 trades)",
             color=INK, fontsize=12, x=0.02, y=0.99, ha="left")

# 1. heatmap of efficiency, net-buying regime
ax = axs[0]; style(ax, "Efficiency (net-buying regime)")
s = g[g.drift == 0.25].pivot(index="royalty", columns="pool_fee", values="eff")
fees_all = list(s.columns); cmap = LinearSegmentedColormap.from_list("blue", ["#eef4fc", "#174c8f"])
im = ax.imshow(s.values, cmap=cmap, aspect="auto", origin="lower", vmin=0, vmax=s.values.max())
ax.set_xticks(range(len(fees_all))); ax.set_xticklabels([f"{f*100:g}%" for f in fees_all]); ax.set_xlabel("pool fee", color=INK2)
ax.set_yticks(range(len(s.index))); ax.set_yticklabels([f"{r*100:g}%" for r in s.index]); ax.set_ylabel("curve royalty", color=INK2)
for i, r in enumerate(s.index):
    for j, f in enumerate(fees_all):
        v = s.loc[r, f]; ax.text(j, i, f"{v:.2f}", ha="center", va="center", fontsize=8.5, color=(SURF if v > 0.7 else INK))
ax.grid(False)
i0, i1 = [list(s.index).index(r) for r in (0.10, 0.20)]; j0, j1 = [fees_all.index(f) for f in (0.003, 0.01)]
ax.add_patch(Rectangle((j0 - 0.5, i0 - 0.5), j1 - j0 + 1, i1 - i0 + 1, fill=False, ec="#eb6834", lw=2))
ax.text(j1 + 0.55, (i0 + i1) / 2, "recommended", color="#eb6834", fontsize=8.5, va="center")

# 2. funding vs royalty by pool fee, both regimes
ax = axs[1]; style(ax, "ETH locked in the position by end of run"); ax.yaxis.grid(True, color=GRID_C, lw=0.8)
for f in FEES:
    for d, ls in ((0.25, "-"), (0.0, "--")):
        s = g[(g.drift == d) & (g.pool_fee == f)].sort_values("royalty")
        ax.plot(s.royalty * 100, s.funding, color=FEE_C[f], lw=2, ls=ls, marker="o", ms=4)
    y = g[(g.drift == 0.25) & (g.pool_fee == f) & (g.royalty == 0.5)].funding.iloc[0] + (-0.22 if f == 0.003 else 0.22 if f == 0.01 else 0)
    ax.text(51, y, f"fee {FEE_L[f]}", color=INK2, fontsize=8.5, va="center")
ax.set_xlabel("curve royalty (%)", color=INK2); ax.set_xticks([1, 3, 5, 10, 20, 30, 50]); ax.set_xlim(0, 58)
ax.text(0.02, 0.96, "solid = net-buying market · dashed = flat market", transform=ax.transAxes, fontsize=8.5, color=INK2, va="top")
ax.text(0.02, 0.90, "flat market: funding saturates above 20% royalty", transform=ax.transAxes, fontsize=8.5, color=INK2, va="top")

# 3. what the efficiency metric ignores: the arb band width
ax = axs[2]; style(ax, "The cost the metric ignores: price band width (fee 0.3%)"); ax.yaxis.grid(True, color=GRID_C, lw=0.8)
for d, ls, lab in ((0.25, "-", "net-buying"), (0.0, "--", "flat")):
    s = g[(g.drift == d) & (g.pool_fee == 0.003)].sort_values("royalty")
    ax.plot([band(r) for r in s.royalty], s.eff, color="#2a78d6", lw=2, ls=ls, marker="o", ms=5)
    if d == 0.25:
        for r, e in zip(s.royalty, s.eff): ax.annotate(f"{r*100:g}%", (band(r), e), textcoords="offset points", xytext=(6, -12 if r >= 0.2 else 6), fontsize=8.5, color=INK2)
ax.set_xscale("log"); ax.set_xticks([5, 10, 20, 50, 100, 200]); ax.set_xticklabels(["5%", "10%", "20%", "50%", "100%", "200%"])
ax.set_xlabel("band: curve mint ceiling ÷ burn floor − 1  (the pool floats anywhere inside it)", color=INK2); ax.set_ylabel("ETH locked per 1% round-trip cost", color=INK2)
ax.axvspan(band(0.10), band(0.20), color="#eb6834", alpha=0.08, lw=0)
ax.text(0.02, 0.96, "labels = curve royalty · solid = net-buying · dashed = flat", transform=ax.transAxes, fontsize=8.5, color=INK2, va="top")

fig.legend([Line2D([0], [0], color=FEE_C[f], lw=2.5) for f in FEES], [f"pool fee {FEE_L[f]}" for f in FEES], loc="upper right", ncol=5, frameon=False, fontsize=9, bbox_to_anchor=(0.99, 0.94))
plt.tight_layout(rect=(0, 0, 1, 0.87)); plt.savefig("cadcad_mix.png", dpi=130, facecolor=SURF); print("cadcad_mix.png written")
