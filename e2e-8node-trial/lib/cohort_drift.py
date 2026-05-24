#!/usr/bin/env python3
"""
Cohort drift analysis for the per-node inventory JSONs.

Reads every <hostname>.json in --in-dir, compares the values across
nodes, and flags any field where one node disagrees with the cohort
majority. Produces both a JSON summary and a Markdown report.

This is what survives of "Phase 0 firmware drift" on a managed
platform: we don't have BMC, IPMI, or switch access, but we can still
look for the case where one node has a different driver / NCCL / OFED
version than the others.

Exit codes:
  0  no drift
  1  drift detected (any field differs)
  2  fewer than the expected node count of inventories present
"""

from __future__ import annotations
import argparse, json, sys
from collections import Counter
from pathlib import Path


# Fields we compare across nodes. Anything not in here is informational
# (e.g. hostname).
COHORT_FIELDS = [
    ("os",                     "Linux distribution"),
    ("kernel",                 "kernel"),
    ("cpu",                    "CPU model"),
    ("memory_gb",              "RAM (GB)"),
    ("system_product",         "system product"),
    ("bios",                   "BIOS version"),
    ("driver",                 "NVIDIA driver"),
    ("cuda",                   "CUDA release"),
    ("gpu_count",              "GPU count"),
    ("ib_port_count",          "IB port count"),
    ("fabricmanager_status",   "fabric manager status"),
    ("fabricmanager_version",  "fabric manager version"),
    ("peermem_loaded",         "nvidia-peermem loaded"),
    ("ofed",                   "MLNX_OFED"),
    ("nccl",                   "NCCL package"),
    ("nvidia_kmod_srcversion", "nvidia kmod srcversion"),
    ("mlx5_kmod_srcversion",   "mlx5 kmod srcversion"),
]

# GPU-row-level fields are checked separately since each node has
# multiple GPUs.
GPU_FIELDS = [
    ("name",   "GPU model"),
    ("driver", "GPU driver (per-GPU readback)"),
    ("vbios",  "VBIOS"),
    ("memory_mib", "memory_mib"),
]


def majority(values):
    """Return (modal_value, count, total) ignoring None."""
    seen = [v for v in values if v is not None]
    if not seen:
        return None, 0, len(values)
    c = Counter(repr(v) for v in seen)
    top, cnt = c.most_common(1)[0]
    # eval back to the original type
    return eval(top), cnt, len(values)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in-dir", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--report", required=True)
    ap.add_argument("--expected-nodes", type=int, default=8)
    args = ap.parse_args()

    files = sorted(Path(args.in_dir).glob("*.json"))
    docs = []
    for f in files:
        try:
            docs.append(json.loads(f.read_text()))
        except Exception as e:
            print(f"WARN: failed to parse {f}: {e}", file=sys.stderr)

    findings = {
        "check": "cohort_drift",
        "expected_nodes": args.expected_nodes,
        "observed_nodes": len(docs),
        "hosts": [d.get("host") for d in docs],
        "fields": [],
        "gpu_fields": [],
        "drift_detected": False,
    }

    if len(docs) < args.expected_nodes:
        findings["status"] = "warn"
        findings["note"] = f"only {len(docs)} of {args.expected_nodes} inventories present"
    else:
        findings["status"] = "pass"

    # Cohort-level field drift
    for key, label in COHORT_FIELDS:
        vals = [d.get(key) for d in docs]
        modal, cnt, tot = majority(vals)
        outliers = [
            {"host": d.get("host"), "value": d.get(key)}
            for d in docs if d.get(key) != modal
        ]
        entry = {
            "field": key,
            "label": label,
            "majority": modal,
            "agreeing": cnt,
            "total": tot,
            "outliers": outliers,
        }
        findings["fields"].append(entry)
        if outliers and modal is not None:
            findings["drift_detected"] = True
            findings["status"] = "fail"

    # GPU-row-level drift (every GPU on every node must agree on model/vbios/driver/memory)
    all_gpu_rows = []
    for d in docs:
        for g in d.get("gpus") or []:
            all_gpu_rows.append({"host": d.get("host"), **g})

    for key, label in GPU_FIELDS:
        vals = [g.get(key) for g in all_gpu_rows]
        modal, cnt, tot = majority(vals)
        outliers = [
            {"host": g["host"], "index": g.get("index"), "value": g.get(key)}
            for g in all_gpu_rows if g.get(key) != modal
        ]
        entry = {
            "field": key,
            "label": label,
            "majority": modal,
            "agreeing": cnt,
            "total": tot,
            "outliers": outliers,
        }
        findings["gpu_fields"].append(entry)
        if outliers and modal is not None:
            findings["drift_detected"] = True
            findings["status"] = "fail"

    Path(args.out).write_text(json.dumps(findings, indent=2))

    # Markdown
    md = []
    md.append("# Cohort drift\n")
    md.append(f"- expected nodes: **{args.expected_nodes}**")
    md.append(f"- observed inventories: **{len(docs)}**")
    md.append(f"- hosts: {', '.join(findings['hosts'])}")
    md.append(f"- overall: **{findings['status'].upper()}**" + (" (drift detected)" if findings["drift_detected"] else ""))
    md.append("")
    md.append("## Cluster-level fields")
    md.append("")
    md.append("| Field | Majority | Agreeing | Outliers |")
    md.append("|-------|----------|----------|----------|")
    for e in findings["fields"]:
        outlier_str = (
            ", ".join(f"`{o['host']}={o['value']}`" for o in e["outliers"])
            if e["outliers"] else "—"
        )
        md.append(f"| {e['label']} | `{e['majority']}` | {e['agreeing']}/{e['total']} | {outlier_str} |")
    md.append("")
    md.append("## Per-GPU fields")
    md.append("")
    md.append("| Field | Majority | Agreeing | Outliers |")
    md.append("|-------|----------|----------|----------|")
    for e in findings["gpu_fields"]:
        outlier_str = (
            ", ".join(f"`{o['host']}/gpu{o['index']}={o['value']}`" for o in e["outliers"])
            if e["outliers"] else "—"
        )
        md.append(f"| {e['label']} | `{e['majority']}` | {e['agreeing']}/{e['total']} | {outlier_str} |")
    Path(args.report).write_text("\n".join(md) + "\n")

    if findings["observed_nodes"] < args.expected_nodes:
        sys.exit(2)
    if findings["drift_detected"]:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
