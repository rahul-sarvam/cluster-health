#!/usr/bin/env python3
"""Phase 3 aggregator smoke test.

Fabricates two synthetic results dirs (a happy-path and a failure-path)
and runs phase3-fullscale/aggregate/report.py against each. Validates:

  * happy path produces PASS and rc=0
  * failure path produces FAIL and rc=2
  * cliff_audit, fec_audit, ufm_audit each fire correctly

Run from anywhere:
    python3 phase3_smoke.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List

ROOT = Path("/sessions/clever-zealous-babbage/mnt/cluster-health/phase3-fullscale")
AGG = ROOT / "aggregate" / "report.py"


# -----------------------------------------------------------------------------
# Synthetic fragment builders
# -----------------------------------------------------------------------------

def write_json(path: Path, obj: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj))


def mk_nccl_all5(results_dir: Path, job: str, with_cliff: bool) -> None:
    """Check 01: per-collective busbw at 256/512/1024 GPUs."""
    results: List[Dict[str, Any]] = []
    for coll, base in [("all_reduce", 480), ("all_gather", 420),
                       ("reduce_scatter", 420), ("alltoall", 360),
                       ("sendrecv", 240)]:
        for nodes, gpus in [(32, 256), (64, 512), (128, 1024)]:
            if with_cliff and gpus == 1024 and coll == "all_reduce":
                bw = base * 0.80   # 20% drop — triggers cliff
            else:
                bw = base + (gpus * 0.01)
            results.append({
                "collective": coll, "nodes": nodes, "gpus": gpus,
                "busbw_gbs": round(bw, 2), "target_gbs": 400, "status": "pass",
            })
    overall = "fail" if with_cliff else "pass"
    write_json(results_dir / f"01_nccl_all5_{job}.json", {
        "check": "01_nccl_all5", "status": overall, "ts": "2026-05-12T10:00:00",
        "job_id": job, "results": results,
    })


def mk_variance(results_dir: Path, job: str, good: bool) -> None:
    if good:
        body = {"status": "pass", "mean_gbs": 478.2, "std_pct": 1.1,
                "p99_p50_ratio": 1.02, "samples": 100}
    else:
        body = {"status": "fail", "mean_gbs": 410.0, "std_pct": 4.6,
                "p99_p50_ratio": 1.14, "samples": 100,
                "reason": "std_pct_over_threshold"}
    body.update({"check": "02_nccl_variance", "ts": "2026-05-12T10:05:00", "job_id": job})
    write_json(results_dir / f"02_nccl_variance_{job}.json", body)


def mk_sharp(results_dir: Path, job: str, good: bool) -> None:
    body: Dict[str, Any] = {
        "check": "03_sharp_compare", "ts": "2026-05-12T10:10:00", "job_id": job,
        "off_busbw_gbs": 380.0,
    }
    if good:
        body.update({"status": "pass", "on_busbw_gbs": 462.0,
                     "sharp_gain_pct": 21.6, "sharp_log_present": True})
    else:
        body.update({"status": "fail", "on_busbw_gbs": 392.0,
                     "sharp_gain_pct": 3.1, "sharp_log_present": True,
                     "reason": "below_gain_threshold"})
    write_json(results_dir / f"03_sharp_compare_{job}.json", body)


def mk_clusterkit(results_dir: Path, job: str) -> None:
    write_json(results_dir / f"04_clusterkit_fullscale_{job}.json", {
        "check": "04_clusterkit_fullscale", "status": "pass",
        "ts": "2026-05-12T10:30:00", "job_id": job,
        "median_gbs": 47.2, "min_gbs": 45.9, "pct_below_median": 1.4,
        "pair_count": 1047552,
    })


def mk_ar(results_dir: Path, job: str) -> None:
    write_json(results_dir / f"05_ar_congestion_{job}.json", {
        "check": "05_ar_congestion", "status": "pass",
        "ts": "2026-05-12T10:45:00", "job_id": job,
        "baseline_gbs": 472.0, "collision_ar_off_gbs": 218.0,
        "collision_ar_on_gbs": 405.0, "recovery_pct": 85.8, "ar_uplift_pct": 85.8,
    })


def mk_iblat(results_dir: Path, job: str) -> None:
    write_json(results_dir / f"06_ib_latency_{job}.json", {
        "check": "06_ib_latency", "status": "pass",
        "ts": "2026-05-12T10:50:00", "job_id": job,
        "intra_leaf_us": 0.94, "cross_spine_us": 1.61,
        "intra_leaf_pair": "node001,node002",
        "cross_spine_pair": "node001,node128",
    })


def mk_hpl(results_dir: Path, job: str) -> None:
    write_json(results_dir / f"08_hpl_fp64_{job}.json", {
        "check": "08_hpl_fp64", "status": "pass",
        "ts": "2026-05-12T11:30:00", "job_id": job,
        "hpl_tflops": 28400.0, "peak_total_tflops": 37888.0,
        "peak_fraction": 0.75,
    })


def mk_hpl_mxp(results_dir: Path, job: str) -> None:
    write_json(results_dir / f"09_hpl_mxp_{job}.json", {
        "check": "09_hpl_mxp", "status": "pass",
        "ts": "2026-05-12T12:00:00", "job_id": job,
        "measured_tflops": 102000.0, "reference_tflops": 100000.0,
        "deviation_pct": 2.0,
    })


def mk_hpcg(results_dir: Path, job: str) -> None:
    write_json(results_dir / f"10_hpcg_{job}.json", {
        "check": "10_hpcg", "status": "pass",
        "ts": "2026-05-12T12:30:00", "job_id": job,
        "hpcg_tflops": 1136.0, "reference_label": "hpl_tflops",
        "reference_value": 28400.0, "fraction": 0.04,
    })


# -----------------------------------------------------------------------------
# Synthetic mlxlink + UFM payloads (for bookended checks 07 and 11)
# -----------------------------------------------------------------------------

MLX_TEMPLATE_GOOD = """===== HOST: {host} =====
===== timestamp: 2026-05-12T10:00:00 =====
----- DEVICE: mlx5_0 -----
effective_physical_BER: 3.4e-13
symbol_errors: {se0}
----- DEVICE: mlx5_1 -----
effective_physical_BER: 2.1e-13
symbol_errors: {se1}
"""

MLX_TEMPLATE_BAD = """===== HOST: {host} =====
----- DEVICE: mlx5_0 -----
effective_physical_BER: 5.2e-06
symbol_errors: {se0}
----- DEVICE: mlx5_1 -----
effective_physical_BER: 3.1e-13
symbol_errors: {se1}
"""


def mk_fec_dumps(results_dir: Path, job: str, kind: str) -> None:
    """kind ∈ {happy, ber_breach, symerr_growth}."""
    base_dir = results_dir / f"07_fec_sweep_{job}" / "baseline"
    fin_dir = results_dir / f"07_fec_sweep_{job}" / "final"
    base_dir.mkdir(parents=True, exist_ok=True)
    fin_dir.mkdir(parents=True, exist_ok=True)
    hosts = [f"node{i:03d}" for i in (1, 2, 3, 64, 128)]
    for h in hosts:
        (base_dir / f"{h}.txt").write_text(
            MLX_TEMPLATE_GOOD.format(host=h, se0=12, se1=18))
        if kind == "happy":
            (fin_dir / f"{h}.txt").write_text(
                MLX_TEMPLATE_GOOD.format(host=h, se0=12, se1=18))
        elif kind == "ber_breach" and h == "node064":
            (fin_dir / f"{h}.txt").write_text(
                MLX_TEMPLATE_BAD.format(host=h, se0=12, se1=18))
        elif kind == "symerr_growth" and h == "node002":
            (fin_dir / f"{h}.txt").write_text(
                MLX_TEMPLATE_GOOD.format(host=h, se0=4711, se1=18))
        else:
            (fin_dir / f"{h}.txt").write_text(
                MLX_TEMPLATE_GOOD.format(host=h, se0=12, se1=18))


def mk_ufm(results_dir: Path, job: str, with_renegotiate: bool) -> None:
    base = results_dir / f"11_ufm_snapshot_{job}" / "baseline"
    fin = results_dir / f"11_ufm_snapshot_{job}" / "final"
    base.mkdir(parents=True, exist_ok=True)
    fin.mkdir(parents=True, exist_ok=True)
    ports_base = [
        {"name": f"node{i:03d}/U1/P1",
         "active_speed": "NDR", "active_width": "4x",
         "physical_state": "LinkUp", "logical_state": "Active"}
        for i in range(1, 11)
    ]
    ports_final = [dict(p) for p in ports_base]
    if with_renegotiate:
        ports_final[3]["active_speed"] = "HDR"   # NDR -> HDR mid-Phase-3
    (base / "ports.json").write_text(json.dumps(ports_base))
    (fin / "ports.json").write_text(json.dumps(ports_final))
    # Also emit empty links / events so the aggregator's file checks pass.
    (base / "links.json").write_text("[]")
    (fin / "links.json").write_text("[]")
    (base / "events.json").write_text("[]")
    (fin / "events.json").write_text("[]")


# -----------------------------------------------------------------------------
# Scenarios
# -----------------------------------------------------------------------------

def build_happy(results_dir: Path, job: str) -> None:
    mk_nccl_all5(results_dir, job, with_cliff=False)
    mk_variance(results_dir, job, good=True)
    mk_sharp(results_dir, job, good=True)
    mk_clusterkit(results_dir, job)
    mk_ar(results_dir, job)
    mk_iblat(results_dir, job)
    mk_hpl(results_dir, job)
    mk_hpl_mxp(results_dir, job)
    mk_hpcg(results_dir, job)
    mk_fec_dumps(results_dir, job, kind="happy")
    mk_ufm(results_dir, job, with_renegotiate=False)


def build_failure(results_dir: Path, job: str) -> None:
    # Cliff in NCCL, variance breach, SHARP regression, FEC BER breach, UFM
    # renegotiation. ClusterKit / AR / IB-lat / HPL / HPCG stay clean to
    # show the aggregator still surfaces them.
    mk_nccl_all5(results_dir, job, with_cliff=True)
    mk_variance(results_dir, job, good=False)
    mk_sharp(results_dir, job, good=False)
    mk_clusterkit(results_dir, job)
    mk_ar(results_dir, job)
    mk_iblat(results_dir, job)
    mk_hpl(results_dir, job)
    mk_hpl_mxp(results_dir, job)
    mk_hpcg(results_dir, job)
    mk_fec_dumps(results_dir, job, kind="ber_breach")
    mk_ufm(results_dir, job, with_renegotiate=True)


# -----------------------------------------------------------------------------
# Driver
# -----------------------------------------------------------------------------

def run_aggregator(results_dir: Path, job: str, out: Path) -> int:
    proc = subprocess.run(
        [sys.executable, str(AGG),
         "--results-dir", str(results_dir),
         "--job-id", job,
         "--out", str(out)],
        capture_output=True, text=True,
    )
    print(f"  stdout: {proc.stdout.strip()}")
    print(f"  stderr: {proc.stderr.strip()}")
    return proc.returncode


def assert_(cond: bool, msg: str) -> None:
    if not cond:
        print(f"  FAIL  {msg}", file=sys.stderr)
        sys.exit(1)
    print(f"  ok    {msg}")


def scenario(label: str, builder, expect_rc: int, expect_overall: str) -> None:
    print(f"\n=== Scenario: {label} ===")
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        results = tmp / "results"
        results.mkdir()
        job = "test12345"
        builder(results, job)
        out = tmp / "report.md"
        rc = run_aggregator(results, job, out)
        assert_(rc == expect_rc, f"return code rc={rc} expected={expect_rc}")
        report = out.read_text()
        assert_(f"Overall: **{expect_overall}**" in report,
                f"report contains 'Overall: **{expect_overall}**'")
        # Sanity: every check name appears in the report.
        for check in ("NCCL all-5", "SHARP", "ClusterKit", "HPL FP64",
                      "HPCG", "FEC", "UFM"):
            assert_(check in report, f"'{check}' present in report")
        if label == "happy_path":
            assert_("64\u219201024 GPU cliff: **PASS**" in report
                    or "64→1024 GPU cliff: **PASS**" in report,
                    "cliff audit reports PASS")
        else:
            assert_("64\u219201024 GPU cliff: **FAIL**" in report
                    or "64→1024 GPU cliff: **FAIL**" in report,
                    "cliff audit reports FAIL")
            assert_("pre_fec_ber_over_ceiling" in report,
                    "FEC BER breach surfaced in report")
            assert_("active_speed" in report and "HDR" in report,
                    "UFM renegotiation surfaced in report")


def main() -> int:
    if not AGG.is_file():
        print(f"ERROR: aggregator missing at {AGG}", file=sys.stderr)
        return 1
    scenario("happy_path", build_happy, expect_rc=0, expect_overall="PASS")
    scenario("failure_path", build_failure, expect_rc=2, expect_overall="FAIL")
    print("\nAll scenarios passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
