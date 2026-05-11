#!/usr/bin/env bash
# firmware_baseline.sh
# Collect every piece of firmware / driver / kernel version data we care about,
# from every node in nodes.txt, in parallel. Emit one JSON per host that
# downstream aggregation (firmware_diff.py) compares against the vendor manifest
# and against the cohort majority.
#
# Read-only. No reconfiguration. Safe to run as many times as needed.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"
# shellcheck source=helpers/ssh_fanout.sh
source "${SCRIPT_DIR}/helpers/ssh_fanout.sh"

p0_require_nodes || exit 1

p0_log "firmware_baseline: starting sweep across $(wc -l < "${P0_NODES}") nodes (fanout=${P0_FANOUT})"

# The remote payload. We capture every version we can find, in a single SSH
# round-trip, and emit a single JSON blob on stdout. Anything missing is
# reported as "missing" so the aggregator can see gaps clearly.
read -r -d '' REMOTE <<'REMOTE_EOF' || true
set -u

get_or_missing() {
    local out
    out=$("$@" 2>/dev/null) || out=""
    if [[ -z "${out}" ]]; then echo "missing"; else echo "${out}" | head -c 4096; fi
}

q() {
    # JSON-string-encode a value: strip CR, escape backslash + dquote + newline.
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a;N;$!ba;s/\n/\\n/g' -e 's/\r//g'
}

bios_version=$(get_or_missing dmidecode -s bios-version | q)
bios_date=$(get_or_missing dmidecode -s bios-release-date | q)
sys_product=$(get_or_missing dmidecode -s system-product-name | q)
baseboard_mfg=$(get_or_missing dmidecode -s baseboard-manufacturer | q)
kernel=$(get_or_missing uname -r | q)
os_release=$(get_or_missing sh -c 'cat /etc/os-release | grep PRETTY_NAME' | q)

driver=$(get_or_missing sh -c 'cat /proc/driver/nvidia/version 2>/dev/null | head -1' | q)
nvidia_smi_driver=$(get_or_missing nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | q)
cuda=$(get_or_missing nvcc --version | q)

# GPU VBIOS - one row per GPU, comma-joined unique values.
vbios=$(nvidia-smi --query-gpu=vbios_version --format=csv,noheader 2>/dev/null | sort -u | paste -sd, -)
[[ -z "${vbios}" ]] && vbios="missing"
vbios=$(echo "${vbios}" | q)

# Fabric Manager.
fm_status=$(get_or_missing systemctl is-active nvidia-fabricmanager | q)
fm_version=$(get_or_missing sh -c 'nv-fabricmanager --version 2>/dev/null | head -1' | q)

# Mellanox/CX-7 firmware and OFED.
mlx_fw=$(get_or_missing sh -c 'mlxfwmanager --query 2>/dev/null | grep -E "FW Version" | sort -u | paste -sd, -' | q)
ofed=$(get_or_missing sh -c 'ofed_info -s 2>/dev/null | head -1' | q)
mst_status=$(get_or_missing sh -c 'mst status 2>/dev/null | grep -c "ConnectX"' | q)

# NCCL
nccl_so=$(get_or_missing sh -c 'find /usr/lib /usr/local /opt -name "libnccl.so*" 2>/dev/null | head -3 | paste -sd, -' | q)
nccl_pkg=$(get_or_missing sh -c 'dpkg-query -W -f="${Version}" libnccl2 2>/dev/null' | q)

# Container runtime versions (used by Pyxis/Enroot).
enroot=$(get_or_missing enroot version | q)
pyxis=$(get_or_missing sh -c 'dpkg-query -W -f="${Version}" pyxis 2>/dev/null' | q)
docker=$(get_or_missing docker --version | q)

# Kernel modules we care about - did they load, and at what srcversion?
mod_nvidia=$(get_or_missing sh -c 'modinfo -F srcversion nvidia 2>/dev/null' | q)
mod_peermem=$(get_or_missing sh -c 'modinfo -F srcversion nvidia_peermem 2>/dev/null' | q)
mod_mlx5=$(get_or_missing sh -c 'modinfo -F srcversion mlx5_core 2>/dev/null' | q)

# Emit one JSON blob.
cat <<JSON
{
  "bios_version": "${bios_version}",
  "bios_date": "${bios_date}",
  "sys_product": "${sys_product}",
  "baseboard_mfg": "${baseboard_mfg}",
  "kernel": "${kernel}",
  "os_release": "${os_release}",
  "driver_proc": "${driver}",
  "driver_smi": "${nvidia_smi_driver}",
  "cuda": "${cuda}",
  "vbios": "${vbios}",
  "fm_status": "${fm_status}",
  "fm_version": "${fm_version}",
  "mlx_fw": "${mlx_fw}",
  "ofed": "${ofed}",
  "mst_cx_count": "${mst_status}",
  "nccl_so": "${nccl_so}",
  "nccl_pkg": "${nccl_pkg}",
  "enroot": "${enroot}",
  "pyxis": "${pyxis}",
  "docker": "${docker}",
  "mod_nvidia_srcversion": "${mod_nvidia}",
  "mod_peermem_srcversion": "${mod_peermem}",
  "mod_mlx5_srcversion": "${mod_mlx5}"
}
JSON
REMOTE_EOF

# Run the payload on every node in parallel.
ts="$(date -u +%Y%m%dT%H%M%SZ)"
out_dir="${P0_RESULTS}/firmware_${ts}"
mkdir -p "${out_dir}"

ssh_fanout "${P0_NODES}" "${P0_FANOUT}" "${REMOTE}" | \
while IFS=$'\t' read -r host rc payload; do
    decoded="$(ssh_fanout_decode "${payload}")"
    if [[ "${rc}" -ne 0 ]]; then
        p0_log "firmware_baseline: ${host} ssh-rc=${rc}"
        p0_emit firmware "${host}" fail rc="${rc}" reason=ssh_failed
        echo "${decoded}" > "${out_dir}/${host}.err"
        continue
    fi
    echo "${decoded}" > "${out_dir}/${host}.json"
    # Cross-check that the JSON parses; emit a status fragment for the aggregator.
    if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${out_dir}/${host}.json" 2>/dev/null; then
        p0_emit firmware "${host}" pass path="${out_dir}/${host}.json"
    else
        p0_emit firmware "${host}" fail reason=invalid_json path="${out_dir}/${host}.json"
    fi
done

p0_log "firmware_baseline: sweep complete. Raw payloads in ${out_dir}"
echo "${out_dir}" > "${P0_RESULTS}/.firmware_latest"
