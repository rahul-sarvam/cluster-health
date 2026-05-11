#!/usr/bin/env python3
"""
report.py — collate firmware_diff.json + cable_validate.json + bmc_summary.json
into a single markdown report that's safe to drop into a PR / Confluence /
email.

The report has three top-line sections (firmware, cables, BMC), each with:
  - a one-paragraph executive summary (pass/warn/fail counts);
  - a list of failing hosts with their specific issues;
  - a list of warning hosts (collapsible block).

A final "Sign-off" section gives a single OVERALL verdict (PASS / WARN / FAIL)
suitable for the contractual acceptance log.

Output: ${P0_RESULTS}/PHASE0_REPORT.md
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path


def _load_or_empty(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return {}


def _verdict(*statuses: str) -> str:
    if "fail" in statuses:
        return "FAIL"
    if "warn" in statuses:
        return "WARN"
    return "PASS"


def _section_firmware(d: dict) -> list[str]:
    out = ["## 1. Firmware baseline", ""]
    if not d:
        out.append("_No firmware_diff.json present — sweep not run._")
        return out
    s = d.get("summary", {})
    out.append(
        f"**{s.get('host_count','?')} hosts scanned · "
        f"PASS={s.get('pass','?')} WARN={s.get('warn','?')} FAIL={s.get('fail','?')}**"
    )
    out.append("")
    out.append(f"Manifest used: `{s.get('manifest_path','?')}` "
               f"({'yes' if s.get('manifest_used') else 'no — cohort majority mode'})")
    out.append("")
    fails = {h: v for h, v in d.get("hosts", {}).items() if v["status"] == "fail"}
    warns = {h: v for h, v in d.get("hosts", {}).items() if v["status"] == "warn"}
    if fails:
        out.append("### Hosts failing firmware drift")
        out.append("")
        out.append("| host | mismatches |")
        out.append("| --- | --- |")
        for h, v in sorted(fails.items()):
            mm = "; ".join(
                f"{m['field']}: expected `{m.get('expected','?')}` got `{m['actual']}` "
                f"({m.get('source','?')})"
                for m in v.get("mismatches", [])[:5]
            )
            extra = "" if len(v.get("mismatches", [])) <= 5 else f" (+{len(v['mismatches'])-5} more)"
            out.append(f"| `{h}` | {mm}{extra} |")
        out.append("")
    if warns:
        out.append("<details><summary>Hosts with warnings (firmware fields missing)</summary>")
        out.append("")
        for h, v in sorted(warns.items()):
            miss = ", ".join(v.get("missing", []))
            out.append(f"- `{h}` — missing: {miss}")
        out.append("")
        out.append("</details>")
        out.append("")
    return out


def _section_cables(d: dict) -> list[str]:
    out = ["## 2. Cable inventory", ""]
    if not d:
        out.append("_No cable_validate.json present — sweep not run._")
        return out
    s = d.get("summary", {})
    out.append(
        f"**{s.get('host_count','?')} hosts scanned · "
        f"PASS={s.get('pass','?')} WARN={s.get('warn','?')} FAIL={s.get('fail','?')}**"
    )
    out.append("")
    out.append(f"Topology used: `{s.get('topology_path','?')}` "
               f"({'yes' if s.get('topology_used') else 'no — pin-only mode'})")
    out.append("")
    fails = {h: v for h, v in d.get("hosts", {}).items() if v["status"] == "fail"}
    warns = {h: v for h, v in d.get("hosts", {}).items() if v["status"] == "warn"}
    if fails:
        out.append("### Hosts with degraded / miscabled links")
        out.append("")
        out.append("| host | hca_count | issues |")
        out.append("| --- | --- | --- |")
        for h, v in sorted(fails.items()):
            issues = "; ".join(v.get("issues", [])[:6])
            extra = "" if len(v.get("issues", [])) <= 6 else f" (+{len(v['issues'])-6})"
            out.append(f"| `{h}` | {v.get('hca_count','?')} | {issues}{extra} |")
        out.append("")
    if warns:
        out.append("<details><summary>Hosts with high pre-FEC BER (not yet failing)</summary>")
        out.append("")
        for h, v in sorted(warns.items()):
            out.append(f"- `{h}` — {'; '.join(v.get('warnings', []))}")
        out.append("")
        out.append("</details>")
        out.append("")
    return out


def _section_bmc(d: dict) -> list[str]:
    out = ["## 3. BMC sweep", ""]
    if not d:
        out.append("_No bmc_summary.json present — sweep not run._")
        return out
    s = d.get("summary", {})
    out.append(
        f"**{s.get('bmc_count','?')} BMCs scanned · "
        f"PASS={s.get('pass','?')} WARN={s.get('warn','?')} FAIL={s.get('fail','?')}**"
    )
    out.append("")
    out.append(f"SEL window: {s.get('window_hours','?')}h · "
               f"max bad sensors tolerated: {s.get('max_bad_sensors','?')}")
    out.append("")
    fails = {b: v for b, v in d.get("bmcs", {}).items() if v["status"] == "fail"}
    warns = {b: v for b, v in d.get("bmcs", {}).items() if v["status"] == "warn"}
    if fails:
        out.append("### BMCs failing")
        out.append("")
        out.append("| bmc | power | fw | issues |")
        out.append("| --- | --- | --- | --- |")
        for b, v in sorted(fails.items()):
            iss = "; ".join(v.get("issues", []))
            out.append(f"| `{b}` | {v.get('power','?')} | {v.get('bmc_fw','?')} | {iss} |")
        out.append("")
    if warns:
        out.append("<details><summary>BMCs with warnings</summary>")
        out.append("")
        for b, v in sorted(warns.items()):
            out.append(f"- `{b}` — {'; '.join(v.get('warnings', []))}")
        out.append("")
        out.append("</details>")
        out.append("")
    return out


def main() -> int:
    results_dir = Path(os.environ.get("P0_RESULTS", "/opt/qualification/phase0/results"))
    fw = _load_or_empty(results_dir / "firmware_diff.json")
    cb = _load_or_empty(results_dir / "cable_validate.json")
    bm = _load_or_empty(results_dir / "bmc_summary.json")

    def _agg_status(d: dict) -> str:
        s = d.get("summary", {}) if d else {}
        if s.get("fail", 0):
            return "fail"
        if s.get("warn", 0):
            return "warn"
        if s.get("host_count", s.get("bmc_count", 0)):
            return "pass"
        return "missing"

    overall = _verdict(_agg_status(fw), _agg_status(cb), _agg_status(bm))

    lines: list[str] = [
        "# Phase 0 Pre-Commission Report",
        "",
        f"_Rendered {datetime.now(timezone.utc).isoformat(timespec='seconds')}_",
        "",
        f"## Overall verdict: **{overall}**",
        "",
        "| Phase | Status | Notes |",
        "| --- | --- | --- |",
        f"| Firmware baseline | {_agg_status(fw).upper()} | "
        f"see §1; manifest={fw.get('summary',{}).get('manifest_used','-')} |",
        f"| Cable inventory   | {_agg_status(cb).upper()} | "
        f"see §2; topology={cb.get('summary',{}).get('topology_used','-')} |",
        f"| BMC sweep         | {_agg_status(bm).upper()} | see §3 |",
        "",
    ]
    lines += _section_firmware(fw) + [""] + _section_cables(cb) + [""] + _section_bmc(bm) + [""]
    lines += [
        "## Sign-off",
        "",
        "By accepting this report the receiving party confirms that:",
        "",
        "1. Every host in `nodes.txt` was successfully contacted.",
        "2. Every BMC in `bmc_hosts.txt` is reachable and reporting good health.",
        "3. Firmware drift is within the configured tolerance (default: zero).",
        "4. Every InfiniBand port is Active/NDR/4x with pre-FEC BER below the failure threshold.",
        "",
        "Any FAIL entries above must be resolved (or explicitly waived in writing) before Phase 1.",
        "",
    ]

    out_path = results_dir / "PHASE0_REPORT.md"
    out_path.write_text("\n".join(lines))
    print(f"report: wrote {out_path}")
    print(f"  overall verdict: {overall}")
    return 0 if overall == "PASS" else (1 if overall == "WARN" else 2)


if __name__ == "__main__":
    sys.exit(main())
