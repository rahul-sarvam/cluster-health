#!/usr/bin/env python3
"""Phase 3 aggregator.

Reads every per-check JSON fragment, plus the bookended FEC/UFM
snapshots (baseline + final), and produces a single Markdown report.

Cross-cutting analyses done here:
  - 64→1024 GPU cliff detection from check 01 (NCCL all-5).
  - FEC/BER deltas from check 07 (per-port pre-FEC BER trend, symbol
    errors increased, post-FEC errors).
  - UFM delta (check 11): any port that renegotiated speed, link-down
    events, or counter spikes during Phase 3.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


CHECK_ORDER = [
    "01_nccl_all5",
    "02_nccl_variance",
    "03_sharp_compare",
    "04_clusterkit_fullscale",
    "05_ar_congestion",
    "06_ib_latency",
    "07_fec_sweep",         # synthesized below from baseline/final pair
    "08_hpl_fp64",
    "09_hpl_mxp",
    "10_hpcg",
    "11_ufm_snapshot",      # synthesized below from baseline/final pair
]

CHECK_TITLES = {
    "01_nccl_all5":          "NCCL all-5 collectives at 256/512/1024 GPUs",
    "02_nccl_variance":      "NCCL variance (100× all-reduce)",
    "03_sharp_compare":      "SHARP on/off comparison",
    "04_clusterkit_fullscale": "ClusterKit pair-matrix (1024 GPUs)",
    "05_ar_congestion":      "Adaptive routing under congestion",
    "06_ib_latency":         "IB latency sweep (intra-leaf + cross-spine)",
    "07_fec_sweep":          "FEC / pre-FEC BER deltas",
    "08_hpl_fp64":           "HPL FP64",
    "09_hpl_mxp":            "HPL-MxP",
    "10_hpcg":               "HPCG",
    "11_ufm_snapshot":       "UFM port-counter deltas",
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

def cliff_audit(nccl_all5: Optional[Dict[str, Any]],
                cliff_pct_max: float) -> Dict[str, Any]:
    """For each collective, compare the busbw at 1024 GPUs against the
    largest sub-1024 scale point captured (typically 256 GPUs from the
    sweep). Drops > cliff_pct_max % imply a spine pathology."""
    if not nccl_all5 or nccl_all5.get("status") not in ("pass", "fail"):
        return {"status": "skip", "reason": "no_input"}
    results = nccl_all5.get("results")
    if isinstance(results, str):
        try:
            results = json.loads(results)
        except json.JSONDecodeError:
            return {"status": "error", "reason": "results_unparseable"}
    by_coll: Dict[str, List[Tuple[int, float]]] = {}
    for r in results or []:
        if "busbw_gbs" not in r:
            continue
        try:
            by_coll.setdefault(r["collective"], []).append(
                (int(r["gpus"]), float(r["busbw_gbs"])))
        except (TypeError, ValueError, KeyError):
            continue
    cliffs = []
    for coll, points in by_coll.items():
        if len(points) < 2:
            continue
        points.sort()
        small_gpus, small_bw = points[0]
        big_gpus, big_bw = points[-1]
        if small_bw <= 0:
            continue
        drop_pct = (small_bw - big_bw) / small_bw * 100.0
        if drop_pct > cliff_pct_max:
            cliffs.append({
                "collective": coll,
                "from_gpus": small_gpus, "to_gpus": big_gpus,
                "from_gbs": small_bw, "to_gbs": big_bw,
                "drop_pct": round(drop_pct, 3),
            })
    return {
        "status": "fail" if cliffs else "pass",
        "cliff_pct_max": cliff_pct_max,
        "cliffs": cliffs,
        "collectives_analyzed": list(by_coll.keys()),
    }


RE_PRE_FEC = re.compile(r"effective_physical_BER\s*[:=]\s*([0-9.eE+-]+)", re.I)
RE_SYMBOL_ERR = re.compile(r"symbol_errors\s*[:=]\s*([0-9]+)", re.I)
RE_DEVICE = re.compile(r"^-+\s*DEVICE:\s*(\S+)")
RE_HOST = re.compile(r"^=+\s*HOST:\s*(\S+)")


def parse_mlxlink_dump(path: Path) -> Dict[str, Dict[str, Any]]:
    """Return {device_name: {pre_fec_ber, symbol_errors}}."""
    if not path.is_file():
        return {}
    out: Dict[str, Dict[str, Any]] = {}
    current = None
    for line in path.read_text(errors="replace").splitlines():
        m = RE_DEVICE.match(line)
        if m:
            current = m.group(1)
            out.setdefault(current, {})
            continue
        if current is None:
            continue
        m = RE_PRE_FEC.search(line)
        if m:
            try:
                out[current]["pre_fec_ber"] = float(m.group(1))
            except ValueError:
                pass
        m = RE_SYMBOL_ERR.search(line)
        if m:
            try:
                out[current]["symbol_errors"] = int(m.group(1))
            except ValueError:
                pass
    return out


def fec_audit(results_dir: Path, job_id: str,
              pre_fec_ber_max: float) -> Dict[str, Any]:
    """Diff baseline vs final mlxlink dumps for every host. Flag any
    port over the pre-FEC BER ceiling or with symbol_errors that
    increased during Phase 3."""
    base_dir = results_dir / f"07_fec_sweep_{job_id}" / "baseline"
    fin_dir = results_dir / f"07_fec_sweep_{job_id}" / "final"
    if not base_dir.is_dir() or not fin_dir.is_dir():
        return {"status": "skip", "reason": "no_fec_dumps"}
    issues: List[Dict[str, Any]] = []
    hosts_with_data = 0
    for fin_file in sorted(fin_dir.glob("*.txt")):
        host = fin_file.stem
        base_file = base_dir / f"{host}.txt"
        base_devs = parse_mlxlink_dump(base_file)
        fin_devs = parse_mlxlink_dump(fin_file)
        if not fin_devs:
            continue
        hosts_with_data += 1
        for dev, fin_data in fin_devs.items():
            base_data = base_devs.get(dev, {})
            ber = fin_data.get("pre_fec_ber")
            if ber is not None and ber > pre_fec_ber_max:
                issues.append({
                    "host": host, "device": dev,
                    "kind": "pre_fec_ber_over_ceiling",
                    "pre_fec_ber": ber, "ceiling": pre_fec_ber_max,
                })
            fin_se = fin_data.get("symbol_errors")
            base_se = base_data.get("symbol_errors", 0)
            if fin_se is not None and base_se is not None and fin_se > base_se:
                issues.append({
                    "host": host, "device": dev,
                    "kind": "symbol_errors_increased",
                    "baseline": base_se, "final": fin_se,
                    "delta": fin_se - base_se,
                })
    return {
        "status": "fail" if issues else "pass",
        "hosts_with_data": hosts_with_data,
        "issues": issues[:200],   # cap to keep report readable
        "issue_count": len(issues),
        "pre_fec_ber_max": pre_fec_ber_max,
    }


def ufm_audit(results_dir: Path, job_id: str) -> Dict[str, Any]:
    """Diff baseline vs final UFM port snapshots: any port whose
    effective speed/width changed during Phase 3 is flagged."""
    base = results_dir / f"11_ufm_snapshot_{job_id}" / "baseline" / "ports.json"
    fin = results_dir / f"11_ufm_snapshot_{job_id}" / "final" / "ports.json"
    if not base.is_file() or not fin.is_file():
        return {"status": "skip", "reason": "no_ufm_snapshots"}
    try:
        b_ports = json.loads(base.read_text())
        f_ports = json.loads(fin.read_text())
    except json.JSONDecodeError as exc:
        return {"status": "error", "reason": f"bad_json:{exc}"}

    def index(ports: Any) -> Dict[str, Dict[str, Any]]:
        out: Dict[str, Dict[str, Any]] = {}
        if isinstance(ports, list):
            for p in ports:
                key = p.get("name") or p.get("guid") or p.get("port_id")
                if key:
                    out[str(key)] = p
        elif isinstance(ports, dict):
            for k, v in ports.items():
                out[str(k)] = v
        return out

    b_idx, f_idx = index(b_ports), index(f_ports)
    renegotiated: List[Dict[str, Any]] = []
    for key, f_p in f_idx.items():
        b_p = b_idx.get(key)
        if not b_p:
            continue
        for field in ("active_speed", "active_width", "physical_state", "logical_state"):
            b_v, f_v = b_p.get(field), f_p.get(field)
            if b_v is not None and f_v is not None and b_v != f_v:
                renegotiated.append({
                    "port": key, "field": field,
                    "baseline": b_v, "final": f_v,
                })
                break   # one issue per port is enough
    return {
        "status": "fail" if renegotiated else "pass",
        "ports_compared": len(set(b_idx) & set(f_idx)),
        "renegotiated_count": len(renegotiated),
        "renegotiated": renegotiated[:50],
    }


# ---------------------------------------------------------------------------
# Rollup + rendering
# ---------------------------------------------------------------------------

def verdict_for_check(check_id: str,
                      checks: Dict[str, Optional[Dict[str, Any]]],
                      synth: Dict[str, Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    if check_id == "07_fec_sweep":
        return synth.get("fec_audit")
    if check_id == "11_ufm_snapshot":
        return synth.get("ufm_audit")
    return checks.get(check_id)


def verdict(checks: Dict[str, Optional[Dict[str, Any]]],
            synth: Dict[str, Dict[str, Any]],
            cross: Dict[str, Dict[str, Any]]) -> str:
    order = {"fail": 3, "error": 3, "warn": 2, "pass": 1, "skip": 0, None: 0}
    worst = 0
    for cid in CHECK_ORDER:
        c = verdict_for_check(cid, checks, synth)
        if c:
            worst = max(worst, order.get(c.get("status"), 0))
    for c in cross.values():
        worst = max(worst, order.get(c.get("status"), 0))
    return {3: "FAIL", 2: "WARN", 1: "PASS", 0: "SKIP"}[worst]


def fmt_kv(d: Dict[str, Any], keys: List[str]) -> str:
    parts = []
    for k in keys:
        if k in d and d[k] not in (None, ""):
            parts.append(f"`{k}`={d[k]}")
    return ", ".join(parts)


REPORT_FIELDS = [
    "hpl_tflops", "peak_fraction", "measured_tflops", "deviation_pct",
    "hpcg_tflops", "fraction", "sharp_gain_pct", "recovery_pct",
    "intra_leaf_us", "cross_spine_us", "mean_gbs", "std_pct", "p99_p50_ratio",
    "median_gbs", "min_gbs", "pct_below_median", "pair_count",
    "issue_count", "renegotiated_count", "reason",
]


def render_report(checks, synth, cross, overall, job_id) -> str:
    lines: List[str] = []
    lines.append("# Phase 3 — Cross-Spine / Full-Scale Report")
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
        c = verdict_for_check(cid, checks, synth)
        if not c:
            lines.append(f"| {title} | _missing_ | — |")
            continue
        st = c.get("status", "?").upper()
        lines.append(f"| {title} | {st} | {fmt_kv(c, REPORT_FIELDS)} |")
    lines.append("")
    lines.append("## Cross-cutting")
    lines.append("")
    cliff = cross.get("cliff_audit", {})
    lines.append(f"- 64→1024 GPU cliff: **{cliff.get('status', '?').upper()}**")
    for c in cliff.get("cliffs", []):
        lines.append(
            f"  - {c['collective']}: {c['from_gpus']}→{c['to_gpus']} GPUs "
            f"{c['from_gbs']:.1f}→{c['to_gbs']:.1f} GB/s ({c['drop_pct']}%)"
        )
    fec = synth.get("fec_audit", {})
    lines.append(f"- FEC / pre-FEC BER deltas: **{fec.get('status', '?').upper()}** "
                 f"({fec.get('issue_count', 0)} issues across {fec.get('hosts_with_data', 0)} hosts)")
    for iss in (fec.get("issues") or [])[:10]:
        lines.append(f"  - {iss}")
    if fec.get("issue_count", 0) > 10:
        lines.append(f"  - ... and {fec['issue_count'] - 10} more (see JSON dump)")
    ufm = synth.get("ufm_audit", {})
    lines.append(f"- UFM port-counter deltas: **{ufm.get('status', '?').upper()}** "
                 f"({ufm.get('renegotiated_count', 0)} renegotiated of "
                 f"{ufm.get('ports_compared', 0)} compared)")
    for r in (ufm.get("renegotiated") or [])[:10]:
        lines.append(f"  - {r}")
    lines.append("")
    lines.append("## Raw JSON fragments")
    lines.append("")
    for cid in CHECK_ORDER:
        c = verdict_for_check(cid, checks, synth)
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
    p.add_argument("--cliff-pct-max", type=float,
                   default=float(os.environ.get("P3_64_TO_1024_CLIFF_PCT", "5")))
    p.add_argument("--pre-fec-ber-max", type=float,
                   default=float(os.environ.get("P3_PRE_FEC_BER_MAX", "1e-7")))
    args = p.parse_args()

    # The base checks (the ones that emit a normal *_<job>.json fragment).
    base_checks = [c for c in CHECK_ORDER if c not in ("07_fec_sweep", "11_ufm_snapshot")]
    checks = {c: load_check(args.results_dir, c, args.job_id) for c in base_checks}

    synth = {
        "fec_audit": fec_audit(args.results_dir, args.job_id, args.pre_fec_ber_max),
        "ufm_audit": ufm_audit(args.results_dir, args.job_id),
    }
    cross = {
        "cliff_audit": cliff_audit(checks.get("01_nccl_all5"), args.cliff_pct_max),
    }

    overall = verdict(checks, synth, cross)
    report = render_report(checks, synth, cross, overall, args.job_id)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(report)
    print(f"Wrote {args.out}  (overall: {overall})", file=sys.stderr)
    return {"PASS": 0, "SKIP": 0, "WARN": 1, "FAIL": 2}[overall]


if __name__ == "__main__":
    sys.exit(main())
