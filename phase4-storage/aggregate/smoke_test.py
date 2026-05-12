#!/usr/bin/env python3
"""Phase 4 aggregator smoke test.

Fabricates two synthetic results dirs and runs report.py against each:

  * happy path  → PASS, rc=0
  * failure     → FAIL, rc=2, tail_audit fires
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict

ROOT = Path("/sessions/clever-zealous-babbage/mnt/cluster-health/phase4-storage")
AGG = ROOT / "aggregate" / "report.py"


def write_json(path: Path, obj: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj))


def build_happy(results: Path, job: str) -> None:
    write_json(results / f"00_preflight_{job}.json",
               {"check": "00_preflight", "status": "pass", "path": "/mnt/scratch"})
    write_json(results / f"01_ior_sequential_{job}.json",
               {"check": "01_ior_sequential", "status": "pass",
                "ranks": 1024, "read_gbs": 285.4, "write_gbs": 142.0,
                "read_gbs_min": 200, "write_gbs_min": 100})
    write_json(results / f"02_mdtest_{job}.json",
               {"check": "02_mdtest", "status": "pass",
                "ranks": 1024, "creates_per_sec": 247000,
                "creates_per_sec_min": 200000})
    write_json(results / f"03_fio_mixed_{job}.json",
               {"check": "03_fio_mixed", "status": "pass",
                "ranks": 1024, "min_iops": 58000, "worst_p99_us": 720,
                "iops_min_target": 50000, "p99_us_max_target": 1000})
    write_json(results / f"04_elbencho_gds_{job}.json",
               {"check": "04_elbencho_gds", "status": "pass",
                "nics": 1024, "per_nic_gbs": 42.8,
                "line_rate_gbs": 46, "fraction_of_line_rate": 0.93,
                "fraction_of_line_rate_min": 0.90})
    write_json(results / f"05_mlperf_storage_{job}.json",
               {"check": "05_mlperf_storage", "status": "pass",
                "model": "unet3d", "num_accelerators": 1024,
                "measured_samples_per_sec": 1842.7,
                "reference_samples_per_sec": 1800.0,
                "deviation_pct": 2.37, "deviation_pct_max": 10})
    write_json(results / f"06_ckpt_storm_{job}.json",
               {"check": "06_ckpt_storm", "status": "pass",
                "ranks": 1024, "shard_size_gb": 1.3,
                "elapsed_sec": 53.2, "deadline_sec": 60,
                "agg_gbs": 25.6, "agg_gbs_min": 22})
    write_json(results / f"07_noisy_neighbor_{job}.json",
               {"check": "07_noisy_neighbor", "status": "pass",
                "baseline_p99_us": 720, "under_load_p99_us": 980,
                "amplification_ratio": 1.36, "amplification_max": 2.0})
    write_json(results / f"08_gds_dataloader_{job}.json",
               {"check": "08_gds_dataloader", "status": "pass",
                "ratio": 0.86, "ratio_min": 0.80})


def build_failure(results: Path, job: str) -> None:
    # Preflight OK; IOR + ckpt + noisy-neighbor + GDS dataloader all fail.
    write_json(results / f"00_preflight_{job}.json",
               {"check": "00_preflight", "status": "pass", "path": "/mnt/scratch"})
    write_json(results / f"01_ior_sequential_{job}.json",
               {"check": "01_ior_sequential", "status": "fail",
                "ranks": 1024, "read_gbs": 148.0, "write_gbs": 81.0,
                "read_gbs_min": 200, "write_gbs_min": 100})
    write_json(results / f"02_mdtest_{job}.json",
               {"check": "02_mdtest", "status": "pass",
                "ranks": 1024, "creates_per_sec": 241000,
                "creates_per_sec_min": 200000})
    write_json(results / f"03_fio_mixed_{job}.json",
               {"check": "03_fio_mixed", "status": "pass",
                "ranks": 1024, "min_iops": 53000, "worst_p99_us": 700,
                "iops_min_target": 50000, "p99_us_max_target": 1000})
    # 04 skipped — libcufile not present.
    write_json(results / f"04_elbencho_gds_{job}.json",
               {"check": "04_elbencho_gds", "status": "skip",
                "reason": "libcufile_missing"})
    # 05 warns — no reference yet.
    write_json(results / f"05_mlperf_storage_{job}.json",
               {"check": "05_mlperf_storage", "status": "warn",
                "reason": "reference_not_set",
                "measured_samples_per_sec": 1842.7,
                "model": "unet3d"})
    # 06 fails — too slow.
    write_json(results / f"06_ckpt_storm_{job}.json",
               {"check": "06_ckpt_storm", "status": "fail",
                "ranks": 1024, "shard_size_gb": 1.3,
                "elapsed_sec": 78.0, "deadline_sec": 60,
                "agg_gbs": 17.4, "agg_gbs_min": 22})
    # 07 fails — tail amplification 3x.
    write_json(results / f"07_noisy_neighbor_{job}.json",
               {"check": "07_noisy_neighbor", "status": "fail",
                "baseline_p99_us": 700, "under_load_p99_us": 2100,
                "amplification_ratio": 3.0, "amplification_max": 2.0})
    write_json(results / f"08_gds_dataloader_{job}.json",
               {"check": "08_gds_dataloader", "status": "skip",
                "reason": "libcufile_missing"})


def run_aggregator(results: Path, job: str, out: Path) -> int:
    proc = subprocess.run(
        [sys.executable, str(AGG),
         "--results-dir", str(results),
         "--job-id", job, "--out", str(out)],
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


def scenario(label, builder, expect_rc, expect_overall) -> None:
    print(f"\n=== Scenario: {label} ===")
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        results = tmp / "results"
        results.mkdir()
        job = "test4242"
        builder(results, job)
        out = tmp / "phase4_report.md"
        rc = run_aggregator(results, job, out)
        assert_(rc == expect_rc, f"return code rc={rc} expected={expect_rc}")
        report = out.read_text()
        assert_(f"Overall: **{expect_overall}**" in report,
                f"report contains 'Overall: **{expect_overall}**'")
        for chunk in ("IOR sequential", "mdtest", "FIO mixed",
                      "elbencho", "MLPerf Storage", "Checkpoint",
                      "Noisy-neighbour", "PyTorch + cuFile"):
            assert_(chunk in report, f"'{chunk}' present in report")
        if label == "happy":
            assert_("tail amplification: **PASS**" in report,
                    "tail_audit reports PASS in happy path")
        else:
            # In failure path baseline=700, under_load=2100, ratio=3.0 → fail.
            assert_("tail amplification: **FAIL**" in report,
                    "tail_audit reports FAIL in failure path")
            assert_("ratio=3.0" in report,
                    "tail_audit ratio surfaced in report")


def main() -> int:
    if not AGG.is_file():
        print(f"ERROR: aggregator missing at {AGG}", file=sys.stderr)
        return 1
    scenario("happy", build_happy, expect_rc=0, expect_overall="PASS")
    scenario("failure", build_failure, expect_rc=2, expect_overall="FAIL")
    print("\nAll scenarios passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
