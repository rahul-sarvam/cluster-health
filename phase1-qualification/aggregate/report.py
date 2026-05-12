#!/usr/bin/env python3
"""
report.py

Produce a single Markdown report summarising the qualification gate result.
Reads:
  - results/cohort.parquet  (from parse_results.py --gather)
  - results/hard_failures.csv
  - results/outliers.csv
  - results/outliers_per_host.csv

Emits to stdout — pipe to results/qualification_report.md.

A node FAILS the gate if any of the following are true:
  1. It has at least one hard-failed check.
  2. It has >= 2 outlier metrics flagged by cohort_analysis.
"""
from __future__ import annotations
import argparse, sys
from pathlib import Path
import pandas as pd

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results-dir", type=Path, default=Path("results"))
    ap.add_argument("--outlier-fail-count", type=int, default=2,
                    help="A node fails the gate at >= this many outlier metrics")
    args = ap.parse_args()
    R = args.results_dir

    df = pd.read_parquet(R / "cohort.parquet")
    hard = pd.read_csv(R / "hard_failures.csv") if (R / "hard_failures.csv").exists() else pd.DataFrame()
    out_per_host = pd.read_csv(R / "outliers_per_host.csv") if (R / "outliers_per_host.csv").exists() else pd.DataFrame()
    outliers = pd.read_csv(R / "outliers.csv") if (R / "outliers.csv").exists() else pd.DataFrame()

    all_hosts = sorted(df["host"].unique())
    hard_set = set(hard["host"].tolist()) if not hard.empty else set()
    out_map = dict(zip(out_per_host["host"], out_per_host["outlier_metric_count"])) if not out_per_host.empty else {}

    rows = []
    for h in all_hosts:
        hard_ck = hard.loc[hard["host"]==h, "failed_checks"].iloc[0] if h in hard_set else ""
        ocount = int(out_map.get(h, 0))
        gate = "PASS"
        if hard_ck: gate = "FAIL"
        elif ocount >= args.outlier_fail_count: gate = "FAIL"
        elif ocount > 0: gate = "WARN"
        rows.append(dict(host=h, gate=gate, hard_failed_checks=hard_ck, outlier_metric_count=ocount))
    summary = pd.DataFrame(rows)

    n_pass = (summary["gate"]=="PASS").sum()
    n_warn = (summary["gate"]=="WARN").sum()
    n_fail = (summary["gate"]=="FAIL").sum()

    print("# Day-1 Per-Node Qualification Gate — Report")
    print()
    print(f"- Total nodes evaluated: **{len(summary)}**")
    print(f"- PASS: **{n_pass}**")
    print(f"- WARN: **{n_warn}** (one outlier, no hard fail — investigate, do not deploy)")
    print(f"- FAIL: **{n_fail}** (block from cluster, return to vendor)")
    print()
    print("## Gate Decision Per Node")
    print()
    print(summary.to_markdown(index=False))
    print()

    if not outliers.empty:
        print("## Detailed Outlier Findings")
        print()
        print(outliers.to_markdown(index=False))
        print()

    # Headline cohort metrics.
    metric_df = df[~df["metric"].str.endswith("_status")]
    stats = metric_df.groupby("metric")["value"].agg(["count","mean","std","median","min","max"]).round(2)
    print("## Cohort Statistics (all nodes)")
    print()
    print(stats.to_markdown())
    print()

    # Cohort homogeneity headline numbers — these are the contractually
    # interesting cluster-wide numbers we hand to the vendor.
    headline_metrics = [
        "hbm_node_median_gbs",
        "nvbw_p2p_bidir_min_gbs",
        "nccl_ar_busbw_gbs",
        "nccl_a2a_busbw_gbs",
    ]
    print("## Cluster Homogeneity (cohort cv = std / mean)")
    print()
    lines = ["| metric | mean | std | cv | min | max |", "|---|---|---|---|---|---|"]
    for m in headline_metrics:
        sub = metric_df[metric_df["metric"]==m]["value"]
        if sub.empty: continue
        mu, sigma, mn, mx = sub.mean(), sub.std(ddof=0), sub.min(), sub.max()
        cv = sigma/mu if mu else 0
        lines.append(f"| {m} | {mu:.1f} | {sigma:.2f} | {cv*100:.2f}% | {mn:.1f} | {mx:.1f} |")
    print("\n".join(lines))

if __name__ == "__main__":
    main()
