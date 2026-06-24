"""Step 10 - Plot the benchmark results produced by benchmark.py.

Reads outputs/benchmarks.csv (raw per-run rows), aggregates to the median execution
time per (variant, K, H) cell, and writes three figures to outputs/:

  * plot_euclidean.png  - Variant A scaling: time vs H, vs K, vs K·H
  * plot_network.png    - Variant B scaling: time vs H, vs K, vs K·H
  * plot_comparison.png - A vs B on shared axes (vs K·H and vs K)

Median (not mean) is used per standard query-benchmarking practice: it is robust to the
occasional slow run from background OS/DB activity. Log scales are used because the times
span several orders of magnitude.

Usage:
    python scripts/plot_performance.py
"""

from __future__ import annotations

import os
import sys

import matplotlib

matplotlib.use("Agg")  # headless: write files, no display
import matplotlib.pyplot as plt
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(os.path.join(HERE, "..", "outputs"))
CSV = os.path.join(OUT, "benchmarks.csv")

LABEL = {"euclidean": "Variant A (Euclidean)", "network": "Variant B (road network)"}
COLOR = {"euclidean": "tab:blue", "network": "tab:red"}


def load():
    if not os.path.exists(CSV):
        sys.exit(f"Missing {CSV}; run scripts/benchmark.py first.")
    df = pd.read_csv(CSV)
    agg = (
        df.groupby(["variant", "K", "H"], as_index=False)["exec_ms"]
        .median()
        .rename(columns={"exec_ms": "median_ms"})
    )
    agg["KH"] = agg["K"] * agg["H"]
    return agg


def plot_variant(agg, variant, outpath):
    sub = agg[agg["variant"] == variant]
    if sub.empty:
        print(f"  (no data for {variant}, skipping {os.path.basename(outpath)})")
        return
    color = COLOR[variant]
    fig, axes = plt.subplots(1, 3, figsize=(15, 4.6))
    fig.suptitle(f"{LABEL[variant]} - query execution time scaling", fontsize=13)

    # (a) time vs H, one line per K
    for k in sorted(sub["K"].unique()):
        d = sub[sub["K"] == k].sort_values("H")
        axes[0].plot(d["H"], d["median_ms"], marker="o", label=f"K={k}")
    axes[0].set(xlabel="H (number of candidates)", ylabel="median execution time (ms)",
                title="(a) time vs H")
    axes[0].set_xscale("log"); axes[0].set_yscale("log")
    axes[0].legend(fontsize=8, title="people"); axes[0].grid(True, which="both", alpha=0.3)

    # (b) time vs K, one line per H
    for h in sorted(sub["H"].unique()):
        d = sub[sub["H"] == h].sort_values("K")
        axes[1].plot(d["K"], d["median_ms"], marker="s", label=f"H={h}")
    axes[1].set(xlabel="K (number of people)", ylabel="median execution time (ms)",
                title="(b) time vs K")
    axes[1].set_xscale("log"); axes[1].set_yscale("log")
    axes[1].legend(fontsize=8, title="candidates"); axes[1].grid(True, which="both", alpha=0.3)

    # (c) time vs K·H (the work proxy), with a linear-in-K·H reference slope
    d = sub.sort_values("KH")
    axes[2].scatter(d["KH"], d["median_ms"], color=color, zorder=3)
    kh = d["KH"].to_numpy()
    ms = d["median_ms"].to_numpy()
    ref = ms[0] * (kh / kh[0])  # slope-1 (linear in K·H) reference through the first point
    axes[2].plot(kh, ref, ls="--", color="gray", label="linear in K·H (ref)")
    axes[2].set(xlabel="K · H (person-candidate pairs)",
                ylabel="median execution time (ms)", title="(c) time vs K·H")
    axes[2].set_xscale("log"); axes[2].set_yscale("log")
    axes[2].legend(fontsize=8); axes[2].grid(True, which="both", alpha=0.3)

    fig.tight_layout(rect=(0, 0, 1, 0.95))
    fig.savefig(outpath, dpi=150)
    plt.close(fig)
    print(f"  wrote {outpath}")


def plot_comparison(agg, outpath):
    fig, axes = plt.subplots(1, 2, figsize=(11, 4.6))
    fig.suptitle("Variant A vs Variant B - execution time", fontsize=13)

    # (a) vs K·H, both variants
    for variant in ("euclidean", "network"):
        sub = agg[agg["variant"] == variant].sort_values("KH")
        if sub.empty:
            continue
        axes[0].scatter(sub["KH"], sub["median_ms"], color=COLOR[variant],
                        label=LABEL[variant], alpha=0.8)
    axes[0].set(xlabel="K · H (person-candidate pairs)",
                ylabel="median execution time (ms)", title="(a) time vs K·H")
    axes[0].set_xscale("log"); axes[0].set_yscale("log")
    axes[0].legend(fontsize=8); axes[0].grid(True, which="both", alpha=0.3)

    # (b) vs K at the largest common H, both variants
    hmax = int(agg["H"].max())
    for variant in ("euclidean", "network"):
        sub = agg[(agg["variant"] == variant) & (agg["H"] == hmax)].sort_values("K")
        if sub.empty:
            continue
        axes[1].plot(sub["K"], sub["median_ms"], marker="o", color=COLOR[variant],
                     label=LABEL[variant])
    axes[1].set(xlabel="K (number of people)", ylabel="median execution time (ms)",
                title=f"(b) time vs K  (H = {hmax})")
    axes[1].set_xscale("log"); axes[1].set_yscale("log")
    axes[1].legend(fontsize=8); axes[1].grid(True, which="both", alpha=0.3)

    fig.tight_layout(rect=(0, 0, 1, 0.95))
    fig.savefig(outpath, dpi=150)
    plt.close(fig)
    print(f"  wrote {outpath}")


def main():
    agg = load()
    print(f"Loaded {len(agg)} (variant, K, H) cells from {os.path.basename(CSV)}")
    plot_variant(agg, "euclidean", os.path.join(OUT, "plot_euclidean.png"))
    plot_variant(agg, "network", os.path.join(OUT, "plot_network.png"))
    plot_comparison(agg, os.path.join(OUT, "plot_comparison.png"))


if __name__ == "__main__":
    main()
