#!/usr/bin/env python3
"""Phase 2 aggregator.

Reads every per-check JSON fragment written by the six check scripts
in ${P2_RESULTS}, rolls them into a single Markdown report, and exits
non-zero if the overall verdict is FAIL.

Cross-cutting analyses we do here (rather than in any one check):
  - Monotonicity of the NCCL scale curve (busbw shouldn't crater).
  - OSU vs NCCL agreement at matched message sizes.

Invocation:
    report.py --results-dir /opt/qualification/phase2/results \\
              --job-id 12345 \\
              --out phase2_report_12345.md
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional


CHECK_ORDER = [
    "01_nccl_sweep",
    "02_nccl_small_msg",
    "03_rail_isolated",
    "04_clusterkit_intra",
    "05_osu_intra",
    "06_topo_check",
]

# Sane per-test descriptions for the report.
CHECK_TITLES = {
    "01_nccl_sweep": "NCCL all-reduce scale sweep (8 → 64 GPUs)",
    "02_nccl_small_msg": "NCCL small-message latency",
    "03_rail_isolated": "Rail-isolated all-reduce",
    "04_clusterkit_intra": "ClusterKit pair-matrix",
    "05_osu_intra": "OSU collectives (cross-check)",
    "06_topo_check": "NCCL topology drift",
}


def load_check(results_dir: Path, check: str, job_id: str) -> Optional[Dict[str, Any]]:
    path = results_dir / f"{check}_{job_id}.json"
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        return {"check": check, "status": "error", "reason": f"bad_json:{exc}"}


def monotonicity_audit(nccl_sweep: Optional[Dict[str, Any]],
                       max_drop_pct: float) -> Dict[str, Any]:
    """Look at the (nodes, busbw) curve and flag any drop > max_drop_pct
    between adjacent scale points. Busbw shouldn't ever *decrease* as we
    move up the cluster (though it grows sub-linearly)."""
    if not nccl_sweep:
        return {"status": "skip", "reason": "no_nccl_sweep_result"}
    scales = nccl_sweep.get("scales")
    if not scales:
        return {"status": "skip", "reason": "no_scales_field"}
    # `scales` is the JSON-encoded array embedded by the bash check.
    if isinstance(scales, str):
        try:
            scales = json.loads(scales)
        except json.JSONDecodeError:
            return {"status": "error", "reason": "scales_unparseable"}
    points = [(int(s["nodes"]), float(s["busbw_gbs"]))
              for s in scales if "busbw_gbs" in s]
    points.sort()
    drops = []
    for (n0, b0), (n1, b1) in zip(points, points[1:]):
        if b0 <= 0:
            continue
        delta_pct = (b0 - b1) / b0 * 100.0
        if delta_pct > max_drop_pct:
            drops.append({
                "from_nodes": n0, "to_nodes": n1,
                "from_gbs": b0, "to_gbs": b1,
                "drop_pct": round(delta_pct, 3),
            })
    return {
        "status": "fail" if drops else "pass",
        "max_drop_pct": max_drop_pct,
        "points": points,
        "drops": drops,
    }


def osu_nccl_agreement(nccl_sweep: Optional[Dict[str, Any]],
                       osu: Optional[Dict[str, Any]],
                       threshold_pct: float) -> Dict[str, Any]:
    """Cross-library sanity check.

    NCCL sweep emits busbw at the largest message size for each scale.
    OSU emits latency at fixed sizes including 64 MiB. We convert OSU's
    64 MiB latency to an effective busbw (GB/s) and compare it to NCCL's
    busbw at the 64-GPU scale. Both should be saturating the same fabric
    ceiling at sizes ≥ a few MiB; a sustained mismatch implies one of
    the two libraries is taking a different path."""
    if not nccl_sweep or not osu:
        return {"status": "skip", "reason": "missing_input"}
    if osu.get("status") == "skip":
        return {"status": "skip", "reason": "osu_skipped"}
    scales = nccl_sweep.get("scales")
    if isinstance(scales, str):
        try:
            scales = json.loads(scales)
        except json.JSONDecodeError:
            return {"status": "skip", "reason": "nccl_scales_unparseable"}
    nccl_64gpu = next((s for s in (scales or []) if s.get("nodes") == 8), None)
    if not nccl_64gpu or "busbw_gbs" not in nccl_64gpu:
        return {"status": "skip", "reason": "no_64gpu_nccl_point"}
    osu_64m_us = osu.get("ar_64m_us")
    if osu_64m_us in (None, "null"):
        return {"status": "skip", "reason": "no_osu_64m_latency"}
    try:
        osu_us = float(osu_64m_us)
        nccl_gbs = float(nccl_64gpu["busbw_gbs"])
    except (TypeError, ValueError):
        return {"status": "skip", "reason": "non_numeric"}
    if osu_us <= 0 or nccl_gbs <= 0:
        return {"status": "skip", "reason": "zero_value"}
    # 64 MiB = 67_108_864 bytes; GB/s = bytes / latency_seconds / 1e9
    osu_gbs = 67_108_864.0 / (osu_us * 1e-6) / 1e9
    delta_pct = abs(osu_gbs - nccl_gbs) / nccl_gbs * 100.0
    return {
        "status": "fail" if delta_pct > threshold_pct else "pass",
        "nccl_busbw_gbs": round(nccl_gbs, 3),
        "osu_effective_gbs_at_64m": round(osu_gbs, 3),
        "osu_latency_us_at_64m": osu_us,
        "delta_pct": round(delta_pct, 3),
        "threshold_pct": threshold_pct,
    }


def verdict(checks: Dict[str, Optional[Dict[str, Any]]],
            cross: Dict[str, Dict[str, Any]]) -> str:
    """Worst-case rollup. fail beats warn beats pass beats skip."""
    order = {"fail": 3, "error": 3, "warn": 2, "pass": 1, "skip": 0, None: 0}
    worst = 0
    for c in checks.values():
        if not c:
            continue
        worst = max(worst, order.get(c.get("status"), 0))
    for c in cross.values():
        worst = max(worst, order.get(c.get("status"), 0))
    return {3: "FAIL", 2: "WARN", 1: "PASS", 0: "SKIP"}[worst]


def fmt_kv(d: Dict[str, Any], keys: List[str]) -> str:
    out = []
    for k in keys:
        if k in d and d[k] not in (None, ""):
            out.append(f"`{k}`={d[k]}")
    return ", ".join(out)


def render_report(checks: Dict[str, Optional[Dict[str, Any]]],
                  cross: Dict[str, Dict[str, Any]],
                  overall: str,
                  job_id: str) -> str:
    lines: List[str] = []
    lines.append(f"# Phase 2 — Intra-Rack Scale Report")
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
        st = c.get("status", "?").upper()
        keys = [k for k in ("median_gbs", "min_gbs", "pct_below_median",
                            "latency_8b_us", "lines_added", "lines_removed",
                            "pair_count", "reason") if k in c]
        lines.append(f"| {title} | {st} | {fmt_kv(c, keys)} |")
    lines.append("")
    lines.append("## Cross-cutting")
    lines.append("")
    mono = cross.get("monotonicity", {})
    lines.append(f"- Scale-curve monotonicity: **{mono.get('status', '?').upper()}**")
    if mono.get("points"):
        pts = ", ".join(f"{n}n→{b:.1f}" for n, b in mono["points"])
        lines.append(f"  - Curve: {pts} GB/s")
    if mono.get("drops"):
        for d in mono["drops"]:
            lines.append(
                f"  - drop {d['from_nodes']}→{d['to_nodes']}n: "
                f"{d['from_gbs']:.1f}→{d['to_gbs']:.1f} ({d['drop_pct']}%)"
            )
    ag = cross.get("osu_nccl_agreement", {})
    lines.append(f"- OSU vs NCCL agreement: **{ag.get('status', '?').upper()}**")
    if "delta_pct" in ag:
        lines.append(
            f"  - NCCL busbw={ag['nccl_busbw_gbs']} GB/s, "
            f"OSU effective@64MiB={ag['osu_effective_gbs_at_64m']} GB/s, "
            f"Δ={ag['delta_pct']}% (threshold {ag['threshold_pct']}%)"
        )
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
    p.add_argument("--monotonicity-drop-pct", type=float,
                   default=float(os.environ.get("P2_MONOTONICITY_DROP_PCT", "5")))
    p.add_argument("--osu-nccl-agreement-pct", type=float,
                   default=float(os.environ.get("P2_OSU_NCCL_AGREEMENT_PCT", "3")))
    args = p.parse_args()

    checks = {cid: load_check(args.results_dir, cid, args.job_id)
              for cid in CHECK_ORDER}

    cross = {
        "monotonicity": monotonicity_audit(
            checks.get("01_nccl_sweep"), args.monotonicity_drop_pct),
        "osu_nccl_agreement": osu_nccl_agreement(
            checks.get("01_nccl_sweep"),
            checks.get("05_osu_intra"),
            args.osu_nccl_agreement_pct),
    }

    overall = verdict(checks, cross)
    report = render_report(checks, cross, overall, args.job_id)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(report)
    print(f"Wrote {args.out}  (overall: {overall})", file=sys.stderr)

    return {"PASS": 0, "SKIP": 0, "WARN": 1, "FAIL": 2}[overall]


if __name__ == "__main__":
    sys.exit(main())
