#!/usr/bin/env python3
"""
firmware_diff.py — compare per-node firmware payloads against
  (a) the vendor manifest (reference/expected_firmware.yaml), and
  (b) the cohort majority (so we surface drift even before the manifest is filled in).

Inputs:
  --raw-dir       Directory containing <host>.json files from firmware_baseline.sh.
                  Defaults to the latest directory pointed to by ${P0_RESULTS}/.firmware_latest.
  --manifest      Path to expected_firmware.yaml. If absent or full of TODO_FILL,
                  we silently fall back to majority mode for that field.
  --out           Output path for the comparison report (JSON). Defaults to
                  ${P0_RESULTS}/firmware_diff.json.

Output:
  A JSON report with per-host PASS / WARN / FAIL plus a summary block. Exit code 0 if
  no node has more than FIRMWARE_DRIFT_MAX_COMPONENTS mismatches, else 2.

Dependencies: pyyaml. Falls back to a minimal hand-rolled parser if pyyaml is absent
so the script can be run on a bare management node before pip is set up.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path


def _load_yaml(path: Path) -> dict:
    try:
        import yaml  # type: ignore
        with path.open() as f:
            return yaml.safe_load(f) or {}
    except ImportError:
        # Minimal fallback - only supports the flat key: "value" structure we use.
        out: dict = {}
        section: dict | None = None
        section_name: str | None = None
        for line in path.read_text().splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if not line.startswith(" "):
                if line.rstrip().endswith(":"):
                    section_name = line.rstrip()[:-1]
                    section = {}
                    out[section_name] = section
                    continue
            else:
                m = re.match(r"\s+([A-Za-z0-9_]+):\s*(?:\"([^\"]*)\"|(\S.*))", line)
                if m and section is not None:
                    key = m.group(1)
                    val = m.group(2) if m.group(2) is not None else (m.group(3) or "").strip()
                    section[key] = val
        return out


# Mapping from manifest field -> (section, payload key, comparison mode).
# Modes: "exact" (must equal), "contains" (manifest value must be a substring of payload).
MANIFEST_RULES: list[tuple[str, str, str, str]] = [
    ("host_firmware", "bios_version", "bios_version", "exact"),
    ("host_firmware", "bios_date", "bios_date", "exact"),
    ("host_firmware", "sys_product", "sys_product", "exact"),
    ("host_firmware", "baseboard_mfg", "baseboard_mfg", "exact"),
    ("host_os", "kernel", "kernel", "exact"),
    ("host_os", "os_release_contains", "os_release", "contains"),
    ("nvidia_stack", "driver_smi", "driver_smi", "exact"),
    ("nvidia_stack", "cuda_contains", "cuda", "contains"),
    ("nvidia_stack", "vbios", "vbios", "exact"),
    ("nvidia_stack", "fm_status", "fm_status", "exact"),
    ("nvidia_stack", "fm_version_contains", "fm_version", "contains"),
    ("mellanox_stack", "ofed_contains", "ofed", "contains"),
    ("mellanox_stack", "mlx_fw_contains", "mlx_fw", "contains"),
    ("mellanox_stack", "mst_cx_count", "mst_cx_count", "exact"),
    ("software_stack", "nccl_pkg_contains", "nccl_pkg", "contains"),
    ("software_stack", "enroot_contains", "enroot", "contains"),
    ("software_stack", "pyxis_contains", "pyxis", "contains"),
    ("kernel_modules", "mod_nvidia_srcversion", "mod_nvidia_srcversion", "exact"),
    ("kernel_modules", "mod_peermem_srcversion", "mod_peermem_srcversion", "exact"),
    ("kernel_modules", "mod_mlx5_srcversion", "mod_mlx5_srcversion", "exact"),
]


def _resolve_latest(raw_dir_arg: str | None) -> Path:
    if raw_dir_arg:
        return Path(raw_dir_arg)
    pointer = Path(os.environ.get("P0_RESULTS", "/opt/qualification/phase0/results")) / ".firmware_latest"
    if pointer.exists():
        return Path(pointer.read_text().strip())
    raise SystemExit(f"No --raw-dir given and {pointer} does not exist.")


def _is_placeholder(v: str) -> bool:
    return v is None or v == "" or "TODO_FILL" in str(v)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw-dir", default=None)
    ap.add_argument("--manifest", default=None)
    ap.add_argument("--out", default=None)
    ap.add_argument("--max-drift", type=int,
                    default=int(os.environ.get("FIRMWARE_DRIFT_MAX_COMPONENTS", 0)))
    args = ap.parse_args()

    raw_dir = _resolve_latest(args.raw_dir)
    if not raw_dir.is_dir():
        raise SystemExit(f"raw dir {raw_dir} is not a directory")

    payloads: dict[str, dict] = {}
    for jf in sorted(raw_dir.glob("*.json")):
        host = jf.stem
        try:
            payloads[host] = json.loads(jf.read_text())
        except json.JSONDecodeError as e:
            payloads[host] = {"__parse_error__": str(e)}

    if not payloads:
        raise SystemExit(f"No payloads found in {raw_dir}")

    manifest_path = Path(args.manifest) if args.manifest else \
        Path(os.environ.get("P0_EXPECTED_FIRMWARE",
                            "/opt/qualification/phase0/reference/expected_firmware.yaml"))
    manifest = _load_yaml(manifest_path) if manifest_path.exists() else {}

    # Compute majority value per payload key, ignoring "missing".
    value_counters: dict[str, Counter] = defaultdict(Counter)
    for host, p in payloads.items():
        if "__parse_error__" in p:
            continue
        for _, _, payload_key, _ in MANIFEST_RULES:
            v = p.get(payload_key, "missing")
            if v != "missing":
                value_counters[payload_key][v] += 1
    majority: dict[str, str] = {
        k: c.most_common(1)[0][0] for k, c in value_counters.items() if c
    }

    # Per-host evaluation.
    host_reports: dict[str, dict] = {}
    for host, p in sorted(payloads.items()):
        if "__parse_error__" in p:
            host_reports[host] = {
                "status": "fail",
                "mismatches": [{"field": "__parse_error__", "msg": p["__parse_error__"]}],
                "missing": [],
            }
            continue
        mismatches: list[dict] = []
        missing: list[str] = []
        for section, manifest_key, payload_key, mode in MANIFEST_RULES:
            actual = p.get(payload_key, "missing")
            if actual == "missing":
                missing.append(payload_key)
                continue
            manifest_val = manifest.get(section, {}).get(manifest_key) if manifest else None
            if manifest_val is None or _is_placeholder(manifest_val):
                # Manifest field unfilled - fall back to cohort majority.
                expected = majority.get(payload_key)
                source = "majority"
            else:
                expected = str(manifest_val)
                source = "manifest"
            if expected is None:
                continue
            ok = (actual == expected) if mode == "exact" else (expected in actual)
            if not ok:
                mismatches.append({
                    "field": payload_key,
                    "expected": expected,
                    "actual": actual,
                    "mode": mode,
                    "source": source,
                })
        status = "pass" if len(mismatches) <= args.max_drift else "fail"
        if mismatches and status == "pass":
            status = "warn"
        host_reports[host] = {
            "status": status,
            "mismatches": mismatches,
            "missing": missing,
        }

    summary = {
        "host_count": len(payloads),
        "pass": sum(1 for v in host_reports.values() if v["status"] == "pass"),
        "warn": sum(1 for v in host_reports.values() if v["status"] == "warn"),
        "fail": sum(1 for v in host_reports.values() if v["status"] == "fail"),
        "manifest_used": manifest_path.exists(),
        "manifest_path": str(manifest_path),
    }

    out_path = Path(args.out) if args.out else \
        Path(os.environ.get("P0_RESULTS", "/opt/qualification/phase0/results")) / "firmware_diff.json"
    out_path.write_text(json.dumps(
        {"summary": summary, "hosts": host_reports, "majority": majority},
        indent=2, sort_keys=True,
    ))
    print(f"firmware_diff: wrote {out_path}")
    print(f"  pass={summary['pass']}  warn={summary['warn']}  fail={summary['fail']}")

    return 0 if summary["fail"] == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
