#!/usr/bin/env bash
# cable_inventory.sh
# Enumerate the InfiniBand fabric and dump per-port link state, width, speed,
# GUIDs, and pre-FEC counters. The output is fed to cable_validate.py, which
# cross-checks it against reference/expected_topology.yaml (rack -> leaf -> host
# port mapping) and flags any miscabling or degraded links.
#
# This script runs from a single management host that has access to the
# InfiniBand subnet (any host where `ibnetdiscover` and `iblinkinfo` succeed
# will do — typically the UFM host or any DGX/HGX node).
#
# Read-only. Safe to run repeatedly.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"
# shellcheck source=helpers/ssh_fanout.sh
source "${SCRIPT_DIR}/helpers/ssh_fanout.sh"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
out_dir="${P0_RESULTS}/cables_${ts}"
mkdir -p "${out_dir}"

p0_log "cable_inventory: starting fabric-wide scan; outputs -> ${out_dir}"

# --- 1. Fabric topology snapshot (run locally on the management host) -------
# `ibnetdiscover` produces the canonical fabric graph; we also dump
# `iblinkinfo -l` which gives one line per link with width/speed.
if command -v ibnetdiscover >/dev/null 2>&1; then
    ibnetdiscover -p > "${out_dir}/ibnetdiscover.txt" 2>&1 || \
        p0_log "cable_inventory: ibnetdiscover returned non-zero (continuing)"
else
    p0_log "cable_inventory: ibnetdiscover not found on this host; skipping fabric topology"
fi

if command -v iblinkinfo >/dev/null 2>&1; then
    iblinkinfo -l > "${out_dir}/iblinkinfo.txt" 2>&1 || \
        p0_log "cable_inventory: iblinkinfo returned non-zero (continuing)"
else
    p0_log "cable_inventory: iblinkinfo not found; per-link width/speed will come from host-side only"
fi

# Full ibdiagnet sweep - heaviest, gives FEC, BER, symbol errors. Skip if missing.
if command -v ibdiagnet >/dev/null 2>&1; then
    ibdiagnet --out_dir "${out_dir}/ibdiagnet" -P all=1 >/dev/null 2>&1 || \
        p0_log "cable_inventory: ibdiagnet returned non-zero (continuing)"
fi

# --- 2. Per-host HCA port summary (fan-out) ---------------------------------
# We collect, for each host: ibstat for each device, port state, port lid,
# port speed/width, mlxlink FEC counters per port.
read -r -d '' REMOTE <<'REMOTE_EOF' || true
set -u
host_section() {
    local title="$1"; shift
    echo "===== ${title} ====="
    "$@" 2>&1 || true
}
host_section IBSTAT ibstat
host_section IBDEVINFO ibv_devinfo
for dev in $(ibstat -l 2>/dev/null); do
    for port in 1 2; do
        host_section "MLXLINK ${dev} port ${port}" mlxlink -d "${dev}" -p "${port}" -m -c -e
    done
done
host_section IBSTATUS ibstatus
host_section MST_STATUS mst status -v
REMOTE_EOF

ssh_fanout "${P0_NODES}" "${P0_FANOUT}" "${REMOTE}" | \
while IFS=$'\t' read -r host rc payload; do
    decoded="$(ssh_fanout_decode "${payload}")"
    if [[ "${rc}" -ne 0 ]]; then
        p0_log "cable_inventory: ${host} ssh-rc=${rc}"
        p0_emit cables "${host}" fail rc="${rc}" reason=ssh_failed
        echo "${decoded}" > "${out_dir}/${host}.err"
        continue
    fi
    echo "${decoded}" > "${out_dir}/${host}.txt"
    p0_emit cables "${host}" pass path="${out_dir}/${host}.txt"
done

p0_log "cable_inventory: sweep complete. Raw outputs in ${out_dir}"
echo "${out_dir}" > "${P0_RESULTS}/.cables_latest"
