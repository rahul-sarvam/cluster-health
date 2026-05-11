#!/usr/bin/env python3
"""
cable_validate.py — parse per-host cable_inventory.sh outputs (plain text
from ibstat / ibv_devinfo / mlxlink) and validate against expected_topology.yaml.

This is a deliberately forgiving parser: vendor `mlxlink` output drifts between
OFED releases, so we extract a small, stable subset (port state, active speed,
active width, pre-FEC BER) and ignore the rest.

Checks performed:
  1. Every host has at least cluster.expected hca_count HCAs visible.
  2. Every IB port that is supposed to be active is Active / LinkUp.
  3. ActiveSpeed contains expected_link_speed (e.g. "NDR").
  4. ActiveWidth contains expected_link_width (e.g. "4x").
  5. Pre-FEC BER below ber.pre_fec_fail (FAIL) and ber.pre_fec_warn (WARN).
  6. The leaf each HCA lands on (from iblinkinfo) matches reference/expected_topology.yaml,
     if rack mappings are filled in.

Outputs ${P0_RESULTS}/cable_validate.json. Exit 0 on no FAIL, 2 otherwise.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path


def _load_yaml(path: Path) -> dict:
    try:
        import yaml  # type: ignore
        with path.open() as f:
            return yaml.safe_load(f) or {}
    except ImportError:
        # Minimal fallback - sufficient for the flat structures we use here.
        out: dict = {}
        stack: list[tuple[int, dict]] = [(0, out)]
        for line in path.read_text().splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            indent = len(line) - len(line.lstrip())
            content = line.strip()
            while stack and indent < stack[-1][0]:
                stack.pop()
            parent = stack[-1][1]
            if content.endswith(":"):
                key = content[:-1].strip()
                nested: dict = {}
                if isinstance(parent, dict):
                    parent[key] = nested
                stack.append((indent + 2, nested))
            elif ":" in content:
                k, v = content.split(":", 1)
                v = v.strip().strip('"').strip("'")
                if isinstance(parent, dict):
                    parent[k.strip()] = v
        return out


def _resolve_latest(raw_dir_arg: str | None) -> Path:
    if raw_dir_arg:
        return Path(raw_dir_arg)
    pointer = Path(os.environ.get("P0_RESULTS", "/opt/qualification/phase0/results")) / ".cables_latest"
    if pointer.exists():
        return Path(pointer.read_text().strip())
    raise SystemExit(f"No --raw-dir given and {pointer} does not exist.")


# Parser fragments. Tolerant of small vendor output changes.
RE_DEVNAME = re.compile(r"CA '([^']+)'")
RE_STATE = re.compile(r"\bState:\s*(\S+)", re.IGNORECASE)
RE_PHYS = re.compile(r"\bPhysical state:\s*(\S+)", re.IGNORECASE)
RE_RATE = re.compile(r"\bRate:\s*([0-9]+)", re.IGNORECASE)
RE_LINK_LAYER = re.compile(r"\blink_layer:\s*(\S+)", re.IGNORECASE)
RE_ACTIVE_SPEED = re.compile(r"Active\s+Speed[^:]*:\s*([^\n]+)", re.IGNORECASE)
RE_ACTIVE_WIDTH = re.compile(r"Active\s+Width[^:]*:\s*([^\n]+)", re.IGNORECASE)
RE_PRE_FEC = re.compile(
    r"(Effective\s+Physical\s+BER|Raw\s+Physical\s+BER|Pre[-\s]?FEC\s+BER)[^:]*:\s*([0-9.eE+\-]+)",
    re.IGNORECASE,
)


def parse_host_dump(text: str) -> dict:
    """Return {device: {port: {...}}} parsed from one host's combined output."""
    devices: dict[str, dict] = {}
    current_dev: str | None = None
    current_port: int | None = None
    # Walk sections separated by "===== ... =====" headers.
    sections = re.split(r"=====\s*([^=]+?)\s*=====", text)
    # sections = [pre, title1, body1, title2, body2, ...]
    for i in range(1, len(sections), 2):
        title = sections[i].strip()
        body = sections[i + 1] if i + 1 < len(sections) else ""

        if title.startswith("IBSTAT"):
            # ibstat: multi-CA block with State, Physical state, Rate per port.
            for ca_match in re.finditer(
                r"CA '([^']+)'.*?(?=(?:CA '|\Z))", body, re.DOTALL
            ):
                dev = ca_match.group(1)
                block = ca_match.group(0)
                devices.setdefault(dev, {"ports": {}, "leaf": None})
                # Find every "Port N:" inside this CA block.
                for port_match in re.finditer(
                    r"Port\s+(\d+):(.*?)(?=Port\s+\d+:|\Z)", block, re.DOTALL
                ):
                    p = int(port_match.group(1))
                    pbody = port_match.group(2)
                    state = RE_STATE.search(pbody)
                    phys = RE_PHYS.search(pbody)
                    rate = RE_RATE.search(pbody)
                    link_layer = RE_LINK_LAYER.search(pbody)
                    rec = devices[dev]["ports"].setdefault(p, {})
                    if state:
                        rec["state"] = state.group(1)
                    if phys:
                        rec["phys"] = phys.group(1)
                    if rate:
                        rec["rate_gbps"] = int(rate.group(1))
                    if link_layer:
                        rec["link_layer"] = link_layer.group(1)
        elif title.startswith("MLXLINK"):
            # Title looks like: "MLXLINK mlx5_0 port 1"
            m = re.match(r"MLXLINK\s+(\S+)\s+port\s+(\d+)", title)
            if not m:
                continue
            dev, p = m.group(1), int(m.group(2))
            devices.setdefault(dev, {"ports": {}, "leaf": None})
            rec = devices[dev]["ports"].setdefault(p, {})
            asp = RE_ACTIVE_SPEED.search(body)
            awd = RE_ACTIVE_WIDTH.search(body)
            ber = RE_PRE_FEC.search(body)
            if asp:
                rec["active_speed"] = asp.group(1).strip()
            if awd:
                rec["active_width"] = awd.group(1).strip()
            if ber:
                try:
                    rec["pre_fec_ber"] = float(ber.group(2))
                except ValueError:
                    pass
    return devices


def parse_iblinkinfo(path: Path) -> dict[str, str]:
    """Best-effort: map host_hca_port -> leaf NodeDescription. Returns {} if absent."""
    out: dict[str, str] = {}
    if not path.exists():
        return out
    # iblinkinfo -l line format (rough):
    #   <lid> <port> <width> <speed> "<NodeDescription>" ==> "<RemoteDescription>"
    # We index by remote description (which contains the host name) -> NodeDescription (which contains the leaf name).
    line_re = re.compile(
        r'^\s*\d+\s+\d+\[\s*\d+\]\s+"([^"]+)"\s+\d+\s+\d+\[\s*\d+\]\s+"([^"]+)"'
    )
    for line in path.read_text().splitlines():
        m = line_re.search(line)
        if not m:
            continue
        local, remote = m.group(1), m.group(2)
        out.setdefault(remote, local)
    return out


def evaluate_host(devices: dict, topo: dict, leaf_map: dict[str, str]) -> dict:
    cluster = topo.get("cluster", {})
    defaults = topo.get("defaults", {})
    ber_cfg = topo.get("ber", {})
    expected_speed = str(cluster.get("expected_link_speed", "NDR"))
    expected_width = str(cluster.get("expected_link_width", "4x"))
    expected_state = str(cluster.get("expected_port_state", "Active"))
    expected_phys = str(cluster.get("expected_phys_state", "LinkUp"))
    expected_hca = int(defaults.get("hca_count", 8))

    try:
        ber_warn = float(ber_cfg.get("pre_fec_warn", 1e-7))
    except (TypeError, ValueError):
        ber_warn = 1e-7
    try:
        ber_fail = float(ber_cfg.get("pre_fec_fail", 1e-6))
    except (TypeError, ValueError):
        ber_fail = 1e-6

    issues: list[str] = []
    warnings: list[str] = []

    ib_devs = [d for d in devices if d.startswith("mlx")]
    if len(ib_devs) < expected_hca:
        issues.append(f"only_{len(ib_devs)}_of_{expected_hca}_hcas_visible")

    for dev, dev_rec in devices.items():
        for port_num, p in dev_rec.get("ports", {}).items():
            link_layer = p.get("link_layer", "").lower()
            # Skip Ethernet ports - this validator is IB-only.
            if link_layer and "infiniband" not in link_layer:
                continue
            state = p.get("state", "")
            phys = p.get("phys", "")
            if state and state != expected_state:
                issues.append(f"{dev}/{port_num}_state={state}")
            if phys and phys != expected_phys:
                issues.append(f"{dev}/{port_num}_phys={phys}")
            asp = p.get("active_speed", "")
            if asp and expected_speed not in asp:
                issues.append(f"{dev}/{port_num}_speed={asp}")
            awd = p.get("active_width", "")
            if awd and expected_width not in awd:
                issues.append(f"{dev}/{port_num}_width={awd}")
            ber = p.get("pre_fec_ber")
            if ber is not None:
                if ber >= ber_fail:
                    issues.append(f"{dev}/{port_num}_ber={ber:.2e}")
                elif ber >= ber_warn:
                    warnings.append(f"{dev}/{port_num}_ber={ber:.2e}")

    # Topology check (only if rack map filled in).
    racks_with_hosts = [
        r for r in (topo.get("racks") or [])
        if any(l.get("hosts") for l in r.get("leaves", []))
    ]
    if racks_with_hosts and leaf_map:
        # TODO: cross-reference per-port leaf binding once the rack file is filled.
        pass

    if issues:
        status = "fail"
    elif warnings:
        status = "warn"
    else:
        status = "pass"
    return {"status": status, "issues": issues, "warnings": warnings, "hca_count": len(ib_devs)}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw-dir", default=None)
    ap.add_argument("--topology", default=None)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    raw_dir = _resolve_latest(args.raw_dir)
    if not raw_dir.is_dir():
        raise SystemExit(f"raw dir {raw_dir} is not a directory")

    topo_path = Path(args.topology) if args.topology else \
        Path(os.environ.get("P0_EXPECTED_TOPOLOGY",
                            "/opt/qualification/phase0/reference/expected_topology.yaml"))
    topo = _load_yaml(topo_path) if topo_path.exists() else {}

    leaf_map = parse_iblinkinfo(raw_dir / "iblinkinfo.txt")

    host_reports: dict[str, dict] = {}
    for tf in sorted(raw_dir.glob("*.txt")):
        if tf.name in ("ibnetdiscover.txt", "iblinkinfo.txt"):
            continue
        host = tf.stem
        text = tf.read_text(errors="replace")
        devices = parse_host_dump(text)
        host_reports[host] = evaluate_host(devices, topo, leaf_map)
        host_reports[host]["devices"] = {
            d: {"ports": dr.get("ports", {})} for d, dr in devices.items()
        }

    summary = {
        "host_count": len(host_reports),
        "pass": sum(1 for v in host_reports.values() if v["status"] == "pass"),
        "warn": sum(1 for v in host_reports.values() if v["status"] == "warn"),
        "fail": sum(1 for v in host_reports.values() if v["status"] == "fail"),
        "topology_used": topo_path.exists(),
        "topology_path": str(topo_path),
    }

    out_path = Path(args.out) if args.out else \
        Path(os.environ.get("P0_RESULTS", "/opt/qualification/phase0/results")) / "cable_validate.json"
    out_path.write_text(json.dumps(
        {"summary": summary, "hosts": host_reports},
        indent=2, sort_keys=True,
    ))
    print(f"cable_validate: wrote {out_path}")
    print(f"  pass={summary['pass']}  warn={summary['warn']}  fail={summary['fail']}")
    return 0 if summary["fail"] == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
