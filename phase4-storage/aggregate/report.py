#!/usr/bin/env python3
"""Phase 4 aggregator.

Reads every per-check JSON fragment in ${P4_RESULTS}/ and renders a
single Markdown report. Adds one cross-cutting analysis:

  * tail_audit: compare the FIO baseline P99 (test 4.3) against the
    noisy-neighbor under-load P99 (test 4.7) to surface end-to-end
    tail-latency amplification even when each individual check
    passed.

Exit codes: PASS=0, SKIP=0, WARN=1, FAIL=2 — same as Phase 3.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional


CHECK_ORDER = [
    "00_preflight",
    "01_ior_sequential",
    "02_mdtest",
    "03_fio_mixed",
    "04_elbencho_gds",
    "05_mlperf_storage",
    "06_ckpt_storm",
    "07_noisy_neighbor",
    "08_gds_dataloader",
]

CHECK_TITLES = {
    "00_preflight":      "Pre-flight (storage root reachable)",
    "01_ior_sequential": "IOR sequential at 1024 clients",
    "02_mdtest":         "mdtest metadata throughput",
    "03_fio_mixed":      "FIO mixed random IOPS + tail latency",
    "04_elbencho_gds":   "elbencho + GPUDirect Storage",
    "05_mlperf_storage": "MLPerf Storage (realistic dataloader)",
    "06_ckpt_storm":     "Checkpoint write storm (1024 ranks)",
    "07_noisy_neighbor": "Noisy-neighbour tail amplification",
    "08_gds_dataloader": "PyTorch + cuFile dataloader end-to-end",
}


def load_check(results_dir: Path, check: str, job_id: str) -> Optional[Dict[str, Any]]:
    path = results_dir / f"{check}_{job_id}.json"
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        return {"check": check, "status": "error", "reason": f"bad_json:{exc}"}


# ---------------------------------------------------------------------------
# Cross-cutting analyses
# ---------------------------------------------------------------------------

def tail_audit(fio: Optional[Dict[str, Any]],
               nn: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """Compare the FIO baseline P99 (from check 03) with the
    noisy-neighbor under-load P99 (from check 07). Even if check 07
    passed against its own baseline, a 2× swing from the steady-state
    P99 captured during the FIO check is worth surfacing in the report.

    Returns one of:
      {status: skip, reason: ...}
      {status: pass, ratio: ...}
      {status: warn, ratio: ...}    — ratio exceeds 1.5× but <= 2×
      {status: fail, ratio: ...}    — ratio exceeds 2×
    """
    if not fio or not nn:
        return {"status": "skip", "reason": "missing_input"}
    fio_p99 = fio.get("worst_p99_us")
    nn_load = nn.get("under_load_p99_us")
    if fio_p99 in (None, "None") or nn_load in (None, "None"):
        return {"status": "skip", "reason": "no_p99_values"}
    try:
        fio_p99_f = float(fio_p99)
        nn_load_f = float(nn_load)
    except (TypeError, ValueError):
        return {"status": "skip", "reason": "non_numeric_p99"}
    if fio_p99_f <= 0:
        return {"status": "skip", "reason": "fio_p99_zero"}
    ratio = nn_load_f / fio_p99_f
    if ratio > 2.0:
        status = "fail"
    elif ratio > 1.5:
        status = "warn"
    else:
        status = "pass"
    return {
        "status": status,
        "fio_baseline_p99_us": fio_p99_f,
        "noisy_neighbor_under_load_p99_us": nn_load_f,
        "ratio_vs_fio_baseline": round(ratio, 3),
    }


# ---------------------------------------------------------------------------
# Rollup + rendering
# ---------------------------------------------------------------------------

def verdict(checks: Dict[str, Optional[Dict[str, Any]]],
            cross: Dict[str, Dict[str, Any]]) -> str:
    order = {"fail": 3, "error": 3, "warn": 2, "pass": 1, "skip": 0, None: 0}
    worst = 0
    for c in checks.values():
        if c:
            worst = max(worst, order.get(c.get("status"), 0))
    for c in cross.values():
        worst = max(worst, order.get(c.get("status"), 0))
    return {3: "FAIL", 2: "WARN", 1: "PASS", 0: "SKIP"}[worst]


REPORT_FIELDS = [
    # IOR + ckpt + elbencho
    "read_gbs", "write_gbs", "agg_gbs", "per_nic_gbs",
    "fraction_of_line_rate", "elapsed_sec",
    # mdtest
    "creates_per_sec",
    # FIO + noisy neighbor
    "min_iops", "worst_p99_us", "amplification_ratio",
    "baseline_p99_us", "under_load_p99_us",
    # MLPerf
    "measured_samples_per_sec", "deviation_pct", "model",
    # GDS dataloader
    "ratio",
    # Generic
    "ranks", "reason",
]


def fmt_kv(d: Dict[str, Any], keys: List[str]) -> str:
    parts = []
    for k in keys:
        if k in d and d[k] not in (None, ""):
            parts.append(f"`{k}`={d[k]}")
    return ", ".join(parts)


def render_report(checks, cross, overall, job_id) -> str:
    lines: List[str] = []
    lines.append("# Phase 4 — Storage Scale Report")
    lines.append("")
    lines.append(f"Job ID: `{job_id}`")
    lines.append(f"Overall: **{overall}**")
    lines.append("")
    lines.append("## Per-check results")
    lines.append("")
    lines.append("| Check | Status | Key metrics |")
    lines.append("| ----- | ------ | ----------- |")
    for cid in CHECK_ORDER:
        title = CHECK_TITLES.get(cid, cid)
        c = checks.get(cid)
        if not c:
            lines.append(f"| {title} | _missing_ | — |")
            continue
        st = (c.get("status") or "?").upper()
        lines.append(f"| {title} | {st} | {fmt_kv(c, REPORT_FIELDS)} |")
    lines.append("")
    lines.append("## Cross-cutting")
    lines.append("")
    ta = cross.get("tail_audit", {})
    lines.append(f"- FIO-vs-noisy-neighbor tail amplification: **{ta.get('status','?').upper()}**")
    if "ratio_vs_fio_baseline" in ta:
        lines.append(
            f"  - baseline P99={ta.get('fio_baseline_p99_us')} µs, "
            f"under load P99={ta.get('noisy_neighbor_under_load_p99_us')} µs, "
            f"ratio={ta.get('ratio_vs_fio_baseline')}"
        )
    elif ta.get("reason"):
        lines.append(f"  - skipped: {ta['reason']}")
    lines.append("")
    lines.append("## Raw JSON fragments")
    lines.append("")
    for cid in CHECK_ORDER:
        c = checks.get(cid)
        if not c:
            continue
        lines.append(f"### {cid}")
        lines.append("")
        lines.append("```json")
        lines.append(json.dumps(c, indent=2, sort_keys=True))
        lines.append("```")
        lines.append("")
    return "\n".join(lines) + "\n"


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--results-dir", required=True, type=Path)
    p.add_argument("--job-id", required=True)
    p.add_argument("--out", required=True, type=Path)
    args = p.parse_args()

    checks = {c: load_check(args.results_dir, c, args.job_id) for c in CHECK_ORDER}
    cross = {
        "tail_audit": tail_audit(checks.get("03_fio_mixed"), checks.get("07_noisy_neighbor")),
    }

    overall = verdict(checks, cross)
    report = render_report(checks, cross, overall, args.job_id)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(report)
    print(f"Wrote {args.out}  (overall: {overall})", file=sys.stderr)
    return {"PASS": 0, "SKIP": 0, "WARN": 1, "FAIL": 2}[overall]


if __name__ == "__main__":
    sys.exit(main())
