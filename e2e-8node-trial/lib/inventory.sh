#!/usr/bin/env bash
# Per-node inventory. Runs once per node via srun. Captures everything
# we want to know about each node's installed stack, then writes a
# single JSON to ${E2E_RUN_DIR}/inventory/<hostname>.json.
#
# We are deliberately permissive: a missing tool emits a `null` field
# rather than failing. The cohort_drift.py step compares the per-node
# JSONs and flags inconsistencies.

set -uo pipefail

: "${E2E_RUN_DIR:?E2E_RUN_DIR must be set in the inherited env}"
HOST="$(hostname)"
OUT="${E2E_RUN_DIR}/inventory/${HOST}.json"
RAW="${E2E_RUN_DIR}/inventory/${HOST}.raw"

mkdir -p "${E2E_RUN_DIR}/inventory"

# Capture the raw command outputs (for forensics) and extract one
# canonical field from each into the JSON.
{
    echo "## hostname";   hostname
    echo "## uname";      uname -a
    echo "## os-release"; cat /etc/os-release 2>/dev/null
    echo "## cpuinfo";    grep -m1 "model name" /proc/cpuinfo 2>/dev/null
    echo "## memtotal";   grep MemTotal /proc/meminfo 2>/dev/null
    echo "## nvidia-smi";
        nvidia-smi --query-gpu=index,name,driver_version,vbios_version,memory.total \
                   --format=csv,noheader 2>&1
    echo "## nvcc";       nvcc --version 2>&1
    echo "## fabric-mgr"; systemctl is-active nvidia-fabricmanager 2>&1; nv-fabricmanager --version 2>&1
    echo "## dcgmi";      dcgmi --version 2>&1
    echo "## peermem";    lsmod | grep nvidia_peermem 2>&1
    echo "## ofed_info";  ofed_info -n 2>&1
    echo "## ibstat";     ibstat 2>&1 | head -40
    echo "## ibdev2net";  ibdev2netdev 2>&1
    echo "## mst";        mst status 2>&1
    echo "## nccl";       dpkg -l libnccl2 2>&1; dpkg -l libnccl-dev 2>&1
    echo "## sharp";      ldconfig -p 2>/dev/null | grep -E 'sharp|nccl-net-sharp'
    echo "## enroot";     enroot version 2>&1
    echo "## pyxis";      dpkg -l '*pyxis*' 2>&1
    echo "## mounts";     mount
    echo "## bios";       dmidecode -s bios-version 2>&1; dmidecode -s bios-release-date 2>&1
    echo "## product";    dmidecode -s system-product-name 2>&1
    echo "## modinfo nv"; modinfo nvidia 2>&1 | grep -E 'srcversion|version:'
    echo "## modinfo mlx5"; modinfo mlx5_core 2>&1 | grep -E 'srcversion|version:'
    echo "## kver";       uname -r
    echo "## numa";       numactl --hardware 2>&1 | head -20
    echo "## local nvme"; lsblk -d -o NAME,TYPE,SIZE,MODEL 2>&1 | grep -E 'NAME|nvme'
} > "${RAW}" 2>&1

# Now extract canonical fields from the raw dump into a JSON. Each
# field is null-on-missing so we always produce well-formed JSON.
python3 - "${HOST}" "${RAW}" "${OUT}" <<'PY'
import json, re, subprocess, sys
host, raw, out = sys.argv[1], sys.argv[2], sys.argv[3]

with open(raw) as f:
    text = f.read()

def section(name):
    m = re.search(rf"## {re.escape(name)}\n(.*?)(?=\n## |\Z)", text, re.S)
    return m.group(1).strip() if m else ""

def first_line(s):
    return s.splitlines()[0].strip() if s.strip() else None

def grep1(pat, s, flags=0):
    m = re.search(pat, s, flags)
    return m.group(1).strip() if m else None

# GPU summary: list of (idx, name, driver, vbios, mem) tuples.
gpu_rows = []
for ln in section("nvidia-smi").splitlines():
    parts = [p.strip() for p in ln.split(",")]
    if len(parts) >= 5 and parts[0].isdigit():
        gpu_rows.append({
            "index": int(parts[0]),
            "name":  parts[1],
            "driver": parts[2],
            "vbios": parts[3],
            "memory_mib": parts[4],
        })

# IB ports: parse ibstat for state + rate
ib_ports = []
cur = {}
for ln in section("ibstat").splitlines():
    s = ln.strip()
    if s.startswith("CA '"):
        if cur: ib_ports.append(cur)
        cur = {"ca": s.split("'")[1]}
    elif s.startswith("Rate:"):
        cur["rate"] = s.split(":",1)[1].strip()
    elif s.startswith("State:"):
        cur["state"] = s.split(":",1)[1].strip()
    elif s.startswith("Physical state:"):
        cur["phys"] = s.split(":",1)[1].strip()
    elif s.startswith("Link layer:"):
        cur["link_layer"] = s.split(":",1)[1].strip()
if cur: ib_ports.append(cur)

# NCCL package version
nccl = grep1(r"libnccl2\s+(\S+)", section("nccl"))

# OFED version
ofed = first_line(section("ofed_info")) or None

# Driver: first GPU's driver
driver = gpu_rows[0]["driver"] if gpu_rows else None

# CUDA: from nvcc --version
cuda = grep1(r"release\s+([\d.]+)", section("nvcc")) or None

# Kernel
kver = first_line(section("kver"))

# OS
os_pretty = grep1(r'PRETTY_NAME="([^"]+)"', section("os-release"))

# CPU model
cpu = grep1(r"model name\s*:\s*(.+)", section("cpuinfo"))

# Memory (kB)
mem_kb = grep1(r"MemTotal:\s+(\d+)", section("memtotal"))
mem_gb = round(int(mem_kb)/1024/1024, 1) if mem_kb else None

# Fabric Manager
fm_status = "active" if "active" in section("fabric-mgr").splitlines()[0:1] and \
                       section("fabric-mgr").splitlines()[0].strip() == "active" else \
            (section("fabric-mgr").splitlines()[0].strip() if section("fabric-mgr") else None)
fm_version = grep1(r"NVIDIA Fabric Manager.*version\s+([\d.\-]+)", section("fabric-mgr"))

# peermem loaded?
peermem = "nvidia_peermem" in section("peermem")

# BIOS
bios_ver  = first_line(section("bios").split("\n", 1)[0]) if section("bios") else None
sys_prod  = first_line(section("product"))

# nvidia modinfo srcversion
nv_srcver = grep1(r"srcversion:\s*(\S+)", section("modinfo nv"))
mlx_srcver = grep1(r"srcversion:\s*(\S+)", section("modinfo mlx5"))

# Local NVMe
nvme_lines = [l.strip() for l in section("local nvme").splitlines() if "nvme" in l]

doc = {
    "check": "inventory",
    "host": host,
    "status": "info",
    "os":   os_pretty,
    "kernel": kver,
    "cpu":  cpu,
    "memory_gb": mem_gb,
    "system_product": sys_prod,
    "bios": bios_ver,
    "gpus": gpu_rows,
    "gpu_count": len(gpu_rows),
    "driver": driver,
    "cuda": cuda,
    "vbios_set": sorted({g["vbios"] for g in gpu_rows}) if gpu_rows else [],
    "fabricmanager_status": fm_status,
    "fabricmanager_version": fm_version,
    "peermem_loaded": peermem,
    "ib_ports": ib_ports,
    "ib_port_count": len(ib_ports),
    "ofed": ofed,
    "nccl": nccl,
    "nvidia_kmod_srcversion": nv_srcver,
    "mlx5_kmod_srcversion": mlx_srcver,
    "local_nvme": nvme_lines,
}
with open(out, "w") as f:
    json.dump(doc, f, indent=2)
PY

echo "inventory: wrote ${OUT}"
