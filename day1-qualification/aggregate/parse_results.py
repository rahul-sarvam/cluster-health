#!/usr/bin/env python3
"""
parse_results.py

Two modes:

1) Per-host roll-up (called from Slurm task):
   parse_results.py --per-host <hostname> --in-dir results/ --out results/<hostname>.json
   Reads results/<hostname>_<check>.json (one per check), merges into a single dict,
   writes results/<hostname>.json.

2) Whole-cluster gather (called from head node after job array completes):
   parse_results.py --gather --in-dir results/ --out results/cohort.parquet
   Walks every results/<hostname>.json, flattens the metrics into a long-format
   DataFrame: (host, check, metric, value, unit), writes parquet.
"""
from __future__ import annotations
import argparse, json, os, sys, glob
from pathlib import Path

def merge_per_host(hostname: str, in_dir: Path, out: Path) -> None:
    merged = {"host": hostname, "checks": {}}
    for f in sorted(in_dir.glob(f"{hostname}_*.json")):
        # Filename pattern is <hostname>_<check>.json. Skip the rolled-up one.
        if f.name == f"{hostname}.json":
            continue
        try:
            data = json.loads(f.read_text())
        except json.JSONDecodeError as e:
            print(f"WARN: could not parse {f}: {e}", file=sys.stderr)
            continue
        check_name = data.get("check", f.stem.split("_", 1)[-1])
        merged["checks"][check_name] = data
    out.write_text(json.dumps(merged, indent=2, sort_keys=True))
    print(f"Wrote {out}")

# Metrics we want to extract into the long-format cohort table for outlier analysis.
# (check_name, key_path_in_check_json, metric_name, expand_as_list)
NUMERIC_METRICS = [
    ("nvbandwidth",        "p2p_bidir_min_gbs",       "nvbw_p2p_bidir_min_gbs",   False),
    ("hbm_bandwidth",      "node_median_gbs",         "hbm_node_median_gbs",      False),
    ("hbm_bandwidth",      "triad_gbs",               "hbm_triad_per_gpu_gbs",    True),
    ("gpu_burn",           "max_temp_c",              "burn_max_temp_c",          False),
    ("gpu_burn",           "peak_power_w",            "burn_peak_power_w",        False),
    ("gpu_burn",           "thermal_throttle_events", "burn_throttle_events",     False),
    ("gpu_burn",           "sbe_after",               "burn_sbe_after",           False),
    ("intra_node_nccl",    "ar_busbw_8gib_gbs",       "nccl_ar_busbw_gbs",        False),
    ("intra_node_nccl",    "a2a_busbw_8gib_gbs",      "nccl_a2a_busbw_gbs",       False),
    ("ib_loopback_bw",     "per_pair",                "ib_pair_host_gbps",        "host_gbps"),
    ("ib_loopback_bw",     "per_pair",                "ib_pair_gpu_gbps",         "gpu_gbps"),
    ("ib_loopback_bw",     "per_pair",                "ib_pair_gdr_ratio",        "gdr_ratio"),
    ("host_health",        "ptp_offset_us",           "ptp_offset_us",            False),
    ("host_health",        "stream_triad_gbs",        "stream_triad_gbs",         False),
]

def gather_cohort(in_dir: Path, out: Path) -> None:
    import pandas as pd
    rows = []
    host_jsons = [p for p in in_dir.glob("*.json") if "_" not in p.stem]
    for f in sorted(host_jsons):
        try:
            data = json.loads(f.read_text())
        except json.JSONDecodeError:
            continue
        host = data.get("host", f.stem)
        checks = data.get("checks", {})
        # Top-level pass/fail per check.
        for cname, cdata in checks.items():
            rows.append(dict(host=host, check=cname,
                             metric=f"{cname}_status",
                             value=1.0 if cdata.get("status") == "pass" else 0.0))
        for check_name, key, metric_name, expand in NUMERIC_METRICS:
            cdata = checks.get(check_name, {})
            v = cdata.get(key)
            if v is None: continue
            if expand is False:
                try:
                    rows.append(dict(host=host, check=check_name,
                                     metric=metric_name, value=float(v)))
                except (TypeError, ValueError):
                    pass
            elif expand is True:
                # v is a list of numbers (per-GPU triads). Emit one row per index.
                if isinstance(v, list):
                    for i, x in enumerate(v):
                        try:
                            rows.append(dict(host=host, check=check_name,
                                             metric=f"{metric_name}_gpu{i}",
                                             value=float(x)))
                        except (TypeError, ValueError):
                            pass
            else:
                # v is a list of dicts; pull a specific sub-key per element.
                if isinstance(v, list):
                    for i, item in enumerate(v):
                        try:
                            rows.append(dict(host=host, check=check_name,
                                             metric=f"{metric_name}_pair{i}",
                                             value=float(item.get(expand, 0))))
                        except (TypeError, ValueError):
                            pass
    df = pd.DataFrame(rows)
    df.to_parquet(out, index=False)
    print(f"Wrote {out} with {len(df)} rows from {len(host_jsons)} hosts")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--per-host", help="hostname for per-host rollup mode")
    ap.add_argument("--gather", action="store_true", help="whole-cluster gather mode")
    ap.add_argument("--in-dir", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()

    if args.per_host and args.gather:
        sys.exit("--per-host and --gather are mutually exclusive")
    if args.per_host:
        merge_per_host(args.per_host, args.in_dir, args.out)
    elif args.gather:
        gather_cohort(args.in_dir, args.out)
    else:
        sys.exit("either --per-host or --gather is required")

if __name__ == "__main__":
    main()
