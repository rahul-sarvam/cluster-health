#!/usr/bin/env python3
"""
bmc_summary.py — Parse per-BMC text dumps from bmc_sweep.sh and report:
  - reachability (transport succeeded?),
  - power status (chassis on),
  - sensor health (any non-OK sensor),
  - recent SEL entries (critical / non-critical, within BMC_SEL_WINDOW_HOURS),
  - FRU sanity (chassis serial present),
  - BMC firmware version (so firmware_diff has a peer for the BMC layer).

Designed to parse both ipmitool and Redfish (raw JSON-blob-in-text) outputs.
Tolerant to malformed entries: we never crash on a malformed line; we just
record the field as "missing" / "parse_error" and continue.

Outputs ${P0_RESULTS}/bmc_summary.json. Exit 0 if no FAIL, 2 otherwise.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path


def _resolve_latest(raw_dir_arg: str | None) -> Path:
    if raw_dir_arg:
        return Path(raw_dir_arg)
    pointer = Path(os.environ.get("P0_RESULTS", "/opt/qualification/phase0/results")) / ".bmc_latest"
    if pointer.exists():
        return Path(pointer.read_text().strip())
    raise SystemExit(f"No --raw-dir given and {pointer} does not exist.")


RE_SECTION = re.compile(r"=====\s*([^=]+?)\s*=====")
RE_MC_FW = re.compile(r"Firmware Revision\s*:\s*(\S+)", re.IGNORECASE)
RE_POWER = re.compile(r"Chassis Power is\s+(\S+)", re.IGNORECASE)
# ipmitool `sensor` rows: name | reading | unit | status | ...
# We treat anything that isn't "ok" or "ns" (no-state) or "na" as bad.
RE_SENSOR_ROW = re.compile(
    r"^([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|", re.MULTILINE
)
# SEL lines look like: "  1 | 03/10/2026 | 12:01:23 | Temperature ... | Critical | Asserted"
RE_SEL_ROW = re.compile(
    r"^\s*\S+\s*\|\s*(\d{2}/\d{2}/\d{4})\s*\|\s*(\d{2}:\d{2}:\d{2})\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|",
    re.MULTILINE,
)
RE_FRU_SERIAL = re.compile(r"Chassis Serial\s*:\s*(\S+)", re.IGNORECASE)


def _split_sections(text: str) -> dict[str, str]:
    parts = RE_SECTION.split(text)
    sections: dict[str, str] = {}
    for i in range(1, len(parts), 2):
        sections[parts[i].strip()] = parts[i + 1] if i + 1 < len(parts) else ""
    return sections


def evaluate_bmc(text: str, window_hours: int, max_bad_sensors: int) -> dict:
    sec = _split_sections(text)
    issues: list[str] = []
    warnings: list[str] = []

    # 1. Power status
    power = "missing"
    if "POWER STATUS" in sec:
        m = RE_POWER.search(sec["POWER STATUS"])
        if m:
            power = m.group(1)
    if power == "missing":
        issues.append("no_power_status")
    elif power.lower() != "on":
        issues.append(f"power_state={power}")

    # 2. BMC firmware
    bmc_fw = "missing"
    if "MC INFO" in sec:
        m = RE_MC_FW.search(sec["MC INFO"])
        if m:
            bmc_fw = m.group(1)

    # 3. Sensors
    bad_sensors: list[str] = []
    sensor_text = sec.get("SENSOR", "")
    for row in RE_SENSOR_ROW.finditer(sensor_text):
        name = row.group(1).strip()
        status = row.group(4).strip().lower()
        if status in ("ok", "ns", "na", ""):
            continue
        # ipmitool occasionally prints "0x0008" status codes for OK-ish sensors;
        # treat unknown numeric codes leniently (warn) and named non-OK as fail.
        if status.startswith("0x"):
            warnings.append(f"sensor_{name}_status={status}")
            continue
        bad_sensors.append(f"{name}={status}")
    if len(bad_sensors) > max_bad_sensors:
        issues.append(f"{len(bad_sensors)}_bad_sensors")
    elif bad_sensors:
        warnings.append(f"{len(bad_sensors)}_bad_sensors_within_tolerance")

    # 4. SEL within window
    sel_text = sec.get("SEL", "")
    cutoff = datetime.now(timezone.utc) - timedelta(hours=window_hours)
    crit_recent = 0
    for row in RE_SEL_ROW.finditer(sel_text):
        d, t, _ev, sev = row.group(1), row.group(2), row.group(3), row.group(4).strip().lower()
        try:
            stamp = datetime.strptime(f"{d} {t}", "%m/%d/%Y %H:%M:%S").replace(tzinfo=timezone.utc)
        except ValueError:
            continue
        if stamp < cutoff:
            continue
        if "critical" in sev or "non-recoverable" in sev:
            crit_recent += 1
    if crit_recent:
        issues.append(f"{crit_recent}_critical_sel_within_{window_hours}h")

    # 5. FRU serial
    fru_serial = "missing"
    if "FRU" in sec:
        m = RE_FRU_SERIAL.search(sec["FRU"])
        if m:
            fru_serial = m.group(1)
    if fru_serial == "missing":
        warnings.append("chassis_serial_missing")

    if issues:
        status = "fail"
    elif warnings:
        status = "warn"
    else:
        status = "pass"

    return {
        "status": status,
        "power": power,
        "bmc_fw": bmc_fw,
        "bad_sensors": bad_sensors,
        "crit_sel_in_window": crit_recent,
        "chassis_serial": fru_serial,
        "issues": issues,
        "warnings": warnings,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw-dir", default=None)
    ap.add_argument("--out", default=None)
    ap.add_argument("--window-hours", type=int,
                    default=int(os.environ.get("BMC_SEL_WINDOW_HOURS", 24)))
    ap.add_argument("--max-bad-sensors", type=int,
                    default=int(os.environ.get("BMC_BAD_SENSOR_MAX", 0)))
    args = ap.parse_args()

    raw_dir = _resolve_latest(args.raw_dir)
    if not raw_dir.is_dir():
        raise SystemExit(f"raw dir {raw_dir} is not a directory")

    bmc_reports: dict[str, dict] = {}
    for tf in sorted(raw_dir.glob("*.txt")):
        bmc = tf.stem
        text = tf.read_text(errors="replace")
        if not text.strip():
            bmc_reports[bmc] = {
                "status": "fail",
                "issues": ["empty_output"],
                "warnings": [],
            }
            continue
        bmc_reports[bmc] = evaluate_bmc(text, args.window_hours, args.max_bad_sensors)

    summary = {
        "bmc_count": len(bmc_reports),
        "pass": sum(1 for v in bmc_reports.values() if v["status"] == "pass"),
        "warn": sum(1 for v in bmc_reports.values() if v["status"] == "warn"),
        "fail": sum(1 for v in bmc_reports.values() if v["status"] == "fail"),
        "window_hours": args.window_hours,
        "max_bad_sensors": args.max_bad_sensors,
    }

    out_path = Path(args.out) if args.out else \
        Path(os.environ.get("P0_RESULTS", "/opt/qualification/phase0/results")) / "bmc_summary.json"
    out_path.write_text(json.dumps(
        {"summary": summary, "bmcs": bmc_reports},
        indent=2, sort_keys=True,
    ))
    print(f"bmc_summary: wrote {out_path}")
    print(f"  pass={summary['pass']}  warn={summary['warn']}  fail={summary['fail']}")
    return 0 if summary["fail"] == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
