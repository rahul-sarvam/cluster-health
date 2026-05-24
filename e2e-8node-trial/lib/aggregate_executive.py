#!/usr/bin/env python3
"""
Roll the per-phase JSON fragments into one executive Markdown report.

Reads:
  - ${RUN}/preflight/preflight.json
  - ${RUN}/inventory/*.json
  - ${RUN}/phase0/cohort_drift.json
  - ${RUN}/phase1/results/*.json
  - ${RUN}/phase2/results/*.json
  - ${RUN}/phase3/results/*.json

Writes:
  - ${RUN}/report/REPORT.md      single human-readable summary
  - ${RUN}/report/summary.json   structured roll-up (for downstream tools)

Exit codes:
  0  everything pass or skip-by-design
  1  at least one warn
  2  at least one fail
"""

from __future__ import annotations
import argparse, json, sys
from collections import Counter, defaultdict
from pathlib import Path
from datetime import datetime, timezone


def load_json(p):
    try:
        return json.loads(Path(p).read_text())
    except Exception:
        return None


def collect_results(d: Path):
    """Read *.json under d (recursive one level), return list of dicts."""
    out = []
    if not d.exists():
        return out
    for f in sorted(d.glob("*.json")):
        doc = load_json(f)
        if doc is not None:
            doc["_source"] = str(f.relative_to(d.parent.parent))
            out.append(doc)
    return out


def status_emoji(s):
    return {"pass": "✅", "fail": "❌", "warn": "⚠️", "skip": "⏭️"}.get(s, "•")


def worst_status(statuses):
    order = ["pass", "skip", "info", "warn", "fail"]
    seen = set(statuses)
    for s in reversed(order):
        if s in seen:
            return s
    return "info"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--summary-json", required=True)
    args = ap.parse_args()

    run = Path(args.run_dir)
    summary = {
        "generated_ts": datetime.now(timezone.utc).isoformat(),
        "run_dir": str(run),
        "preflight": None,
        "inventory_count": 0,
        "cohort_drift": None,
        "phases": {},
        "verdict": "unknown",
    }

    md = []
    md.append("# E2E 8-Node Acceptance Trial — Executive Report")
    md.append("")
    md.append(f"- Run directory: `{run}`")
    md.append(f"- Generated: `{summary['generated_ts']}`")
    md.append("")

    # ---- preflight ----
    pf = load_json(run / "preflight" / "preflight.json")
    summary["preflight"] = pf
    md.append("## Pre-flight")
    if pf:
        md.append(f"- partition: `{pf.get('partition')}`")
        md.append(f"- expected nodes: {pf.get('expected_node_count')}, observed: {pf.get('observed_node_count')}")
        md.append(f"- shared FS visible on all compute nodes: **{pf.get('shared_fs_ok')}**")
        md.append(f"- status: {status_emoji(pf.get('status','info'))} **{pf.get('status','?').upper()}**")
    else:
        md.append("- preflight.json missing — preflight did not complete cleanly.")
    md.append("")

    # ---- inventory ----
    inv = collect_results(run / "inventory")
    summary["inventory_count"] = len(inv)
    md.append("## Inventory")
    if inv:
        md.append(f"- node inventories captured: **{len(inv)}**")
        md.append("- host fingerprint:")
        md.append("")
        md.append("| host | GPUs | driver | CUDA | NCCL | OFED | kernel |")
        md.append("|------|-----:|--------|------|------|------|--------|")
        for d in inv:
            md.append(
                f"| `{d.get('host')}` | {d.get('gpu_count')} | "
                f"`{d.get('driver')}` | `{d.get('cuda')}` | `{d.get('nccl')}` | "
                f"`{d.get('ofed')}` | `{d.get('kernel')}` |"
            )
    else:
        md.append("- no inventory data.")
    md.append("")

    # ---- cohort drift ----
    cd = load_json(run / "phase0" / "cohort_drift.json")
    summary["cohort_drift"] = cd
    md.append("## Phase 0 — cohort drift")
    if cd:
        md.append(f"- status: {status_emoji(cd.get('status','info'))} **{cd.get('status','?').upper()}**")
        md.append(f"- drift detected: **{cd.get('drift_detected')}**")
        drift_rows = [f for f in cd.get("fields", []) if f["outliers"]]
        if drift_rows:
            md.append("- drift in:")
            for f in drift_rows:
                outs = "; ".join(f"{o['host']}={o['value']}" for o in f["outliers"])
                md.append(f"  - **{f['label']}** — majority `{f['majority']}`; outliers: {outs}")
        gpu_drift = [f for f in cd.get("gpu_fields", []) if f["outliers"]]
        if gpu_drift:
            md.append("- GPU-level drift in:")
            for f in gpu_drift:
                outs = "; ".join(f"{o['host']}/gpu{o['index']}={o['value']}" for o in f["outliers"])
                md.append(f"  - **{f['label']}** — majority `{f['majority']}`; outliers: {outs}")
        md.append(f"- detail: [`phase0/cohort_drift.md`](../phase0/cohort_drift.md)")
    else:
        md.append("- cohort_drift.json missing.")
    md.append("")

    # ---- Phases 1/2/3 ----
    phase_dirs = [
        ("Phase 1 — per-node qualification", run / "phase1" / "results"),
        ("Phase 2 — intra-cluster collectives", run / "phase2" / "results"),
        ("Phase 3 — collective sweep at 8-node scale", run / "phase3" / "results"),
    ]
    for title, d in phase_dirs:
        md.append(f"## {title}")
        docs = collect_results(d)
        phase_key = d.parent.name
        phase_summary = {"results_dir": str(d), "count": len(docs), "by_status": {}, "checks": []}
        summary["phases"][phase_key] = phase_summary
        if not docs:
            md.append(f"- no results in `{d}`")
            md.append("")
            continue
        by_check = defaultdict(list)
        for doc in docs:
            name = doc.get("check") or doc.get("_source")
            by_check[name].append(doc)
        statuses = [d.get("status", "info") for d in docs]
        counts = Counter(statuses)
        phase_summary["by_status"] = dict(counts)
        ws = worst_status(statuses)
        phase_summary["worst_status"] = ws
        md.append(f"- result count: **{len(docs)}**; "
                  + ", ".join(f"{status_emoji(s)} {s}={n}" for s, n in counts.items()))
        md.append(f"- worst status: {status_emoji(ws)} **{ws.upper()}**")
        md.append("")
        md.append("| check | status | host(s) | details |")
        md.append("|-------|--------|---------|---------|")
        for name in sorted(by_check):
            entries = by_check[name]
            for doc in entries:
                s = doc.get("status", "info")
                host = doc.get("host", doc.get("job_id", ""))
                tags = []
                for k in ("busbw_gbs", "p99_us", "reason", "deviation_pct", "ratio"):
                    if k in doc:
                        tags.append(f"{k}={doc[k]}")
                tag_str = ", ".join(tags) if tags else ""
                md.append(f"| `{name}` | {status_emoji(s)} {s} | `{host}` | {tag_str} |")
            phase_summary["checks"].append({
                "name": name,
                "entries": len(entries),
                "statuses": [d.get("status") for d in entries],
            })
        md.append("")

    # ---- Verdict ----
    all_statuses = []
    if pf:
        all_statuses.append(pf.get("status", "info"))
    if cd:
        all_statuses.append(cd.get("status", "info"))
    for p in summary["phases"].values():
        if p.get("worst_status"):
            all_statuses.append(p["worst_status"])
    verdict = worst_status(all_statuses) if all_statuses else "info"
    summary["verdict"] = verdict

    md.insert(2, f"## Verdict: {status_emoji(verdict)} **{verdict.upper()}**")
    md.insert(3, "")

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text("\n".join(md) + "\n")
    Path(args.summary_json).write_text(json.dumps(summary, indent=2, default=str))

    print(f"executive report: {args.out}")
    print(f"verdict: {verdict}")
    sys.exit({"pass": 0, "info": 0, "skip": 0, "warn": 1, "fail": 2}.get(verdict, 1))


if __name__ == "__main__":
    main()
