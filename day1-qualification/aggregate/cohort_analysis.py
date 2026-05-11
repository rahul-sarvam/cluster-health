#!/usr/bin/env python3
"""
cohort_analysis.py

Read the long-format cohort.parquet produced by parse_results.py --gather,
compute cohort statistics per metric, and flag outlier (host, metric) pairs.

A pair is flagged if it satisfies either:
  - z-score |z| >= 3.0 against the cohort mean for that metric, OR
  - value is more than COHORT_OUTLIER_PCT % below the cohort median
    (one-sided: we care only about under-performance for bandwidth/throughput).

Power, temperature, throttle, SBE, and PTP-offset metrics are one-sided UPward
(over-cohort is bad). Bandwidth and triad metrics are one-sided DOWNward.

Outputs:
  - results/outliers.csv : one row per (host, metric) flagged
  - prints a summary to stdout

This script is deliberately conservative — its output is "investigate this",
not "RMA this". The human signs off on the final node list.
"""
from __future__ import annotations
import argparse, os, sys
from pathlib import Path
import pandas as pd
import numpy as np

OVER_IS_BAD = {
    "burn_max_temp_c", "burn_peak_power_w", "burn_throttle_events",
    "burn_sbe_after", "ptp_offset_us",
}

def direction(metric: str) -> str:
    """Return 'down' (under cohort = bad) or 'up' (over cohort = bad)."""
    for m in OVER_IS_BAD:
        if metric == m or metric.startswith(m): return "up"
    return "down"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("parquet", type=Path)
    ap.add_argument("--outlier-pct", type=float,
                    default=float(os.environ.get("COHORT_OUTLIER_PCT", "1.0")))
    ap.add_argument("--z-threshold", type=float, default=3.0)
    ap.add_argument("--out-dir", type=Path, default=Path("results"))
    args = ap.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)

    df = pd.read_parquet(args.parquet)
    if df.empty:
        sys.exit("Empty cohort dataframe")

    # Skip status-only rows in the outlier analysis (handled separately).
    metric_df = df[~df["metric"].str.endswith("_status")].copy()

    stats = metric_df.groupby("metric")["value"].agg(["count","mean","std","median","min","max"])
    stats["pct_below_median_threshold"] = stats["median"] * (1.0 - args.outlier_pct/100.0)
    stats["pct_above_median_threshold"] = stats["median"] * (1.0 + args.outlier_pct/100.0)

    flagged = []
    for (metric,), grp in metric_df.groupby(["metric"]):
        s = grp["value"]
        mu, sigma = s.mean(), s.std(ddof=0)
        med = s.median()
        dirn = direction(metric)
        for _, row in grp.iterrows():
            v = row["value"]
            z = (v - mu) / sigma if sigma > 0 else 0.0
            reasons = []
            if dirn == "down":
                if med > 0 and v < med * (1.0 - args.outlier_pct/100.0):
                    reasons.append(f"below_median_by_{(med-v)/med*100:.2f}pct")
                if z <= -args.z_threshold:
                    reasons.append(f"z={z:.2f}")
            else:  # up-is-bad
                if med > 0 and v > med * (1.0 + args.outlier_pct/100.0):
                    reasons.append(f"above_median_by_{(v-med)/med*100:.2f}pct")
                if z >= args.z_threshold:
                    reasons.append(f"z={z:.2f}")
            if reasons:
                flagged.append(dict(
                    host=row["host"], metric=metric,
                    value=v, cohort_median=med, cohort_mean=mu, cohort_std=sigma,
                    direction=dirn, reasons=";".join(reasons),
                ))

    out_csv = args.out_dir / "outliers.csv"
    pd.DataFrame(flagged).to_csv(out_csv, index=False)

    # Per-host outlier count for the gate decision.
    if flagged:
        outlier_count = pd.DataFrame(flagged).groupby("host").size().rename("outlier_metric_count").reset_index()
    else:
        outlier_count = pd.DataFrame(columns=["host","outlier_metric_count"])
    outlier_count.to_csv(args.out_dir / "outliers_per_host.csv", index=False)

    # Hard-fail hosts: those with any *_status == 0.0 from parse_results.
    status_df = df[df["metric"].str.endswith("_status")]
    hard_fails = (status_df[status_df["value"] == 0.0]
                  .groupby("host")["metric"].apply(lambda s: ";".join(sorted(s)))
                  .reset_index()
                  .rename(columns={"metric":"failed_checks"}))
    hard_fails.to_csv(args.out_dir / "hard_failures.csv", index=False)

    print(f"Cohort size: {df['host'].nunique()} hosts")
    print(f"Metrics evaluated: {metric_df['metric'].nunique()}")
    print(f"Flagged outlier (host, metric) pairs: {len(flagged)}")
    print(f"Hosts with at least one hard-failed check: {len(hard_fails)}")
    print(f"Wrote: {out_csv}")
    print(f"Wrote: {args.out_dir/'outliers_per_host.csv'}")
    print(f"Wrote: {args.out_dir/'hard_failures.csv'}")

    # Print the cohort statistics so the operator has the headline numbers.
    print("\n=== Cohort statistics ===")
    print(stats.round(2).to_string())

if __name__ == "__main__":
    main()
