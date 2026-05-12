#!/usr/bin/env bash
# 10_host_health.sh
# CPU, memory, NUMA, NVMe, PTP, hugepages. Boring but every one of these
# has cost real clusters real money when it was wrong.
set -uo pipefail
source "${QUAL_ROOT}/slurm/env.sh"

OUT="${QUAL_LOGS}/$(hostname)_host_health.txt"
: > "${OUT}"

# NUMA layout
numactl --hardware > "${OUT}" 2>&1
numa_nodes=$(numactl --hardware | grep -c "^node [0-9]")

# Memory
total_mem_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
hugepages_total=$(awk '/^HugePages_Total/ {print $2}' /proc/meminfo)

# STREAM-like memory bandwidth (use BabelStream CPU build if available, else skip)
stream_triad=0
if command -v stream-bw >/dev/null 2>&1; then
    stream_triad=$(stream-bw 2>&1 | awk '/Triad/ {print $2; exit}')
fi

# NVMe SMART
nvme_fail=0
nvme_details=()
for d in /dev/nvme*n1; do
    [[ -b "${d}" ]] || continue
    health=$(nvme smart-log "${d}" 2>/dev/null | awk '/critical_warning/ {print $3; exit}')
    pct_used=$(nvme smart-log "${d}" 2>/dev/null | awk '/percentage_used/ {print $3; exit}')
    nvme_details+=("{\"dev\":\"${d}\",\"critical_warning\":\"${health}\",\"pct_used\":\"${pct_used}\"}")
    if [[ "${health}" != "0" ]] && [[ -n "${health}" ]]; then nvme_fail=1; fi
done

# PTP offset
ptp_offset_us="unknown"
if command -v chronyc >/dev/null 2>&1; then
    ptp_offset_us=$(chronyc tracking 2>/dev/null | awk '/Last offset/ {printf "%.1f", $4*1e6}')
fi

# Persistent mode + hugepages contract
fail=0
[[ "${numa_nodes}" -lt 2 ]] && { qual_log "Unexpected NUMA topology: ${numa_nodes} nodes"; fail=1; }
[[ "${total_mem_gb}" -lt 1900 ]] && { qual_log "Host RAM low: ${total_mem_gb} GB"; fail=1; }
[[ "${nvme_fail}" -eq 1 ]] && fail=1
if [[ "${ptp_offset_us}" != "unknown" ]] && \
   awk -v o="${ptp_offset_us}" -v m="${PTP_OFFSET_MAX_US}" 'BEGIN {exit !(o+0 > m+0 || o+0 < -m+0)}'; then
    qual_log "PTP offset out of range: ${ptp_offset_us} us"
    fail=1
fi

nvme_json="[$(IFS=,; echo "${nvme_details[*]}")]"
status="pass"; [[ "${fail}" -eq 1 ]] && status="fail"
qual_emit host_health "${status}" \
    log_path="${OUT}" \
    numa_nodes="${numa_nodes}" \
    total_mem_gb="${total_mem_gb}" \
    hugepages_total="${hugepages_total}" \
    stream_triad_gbs="${stream_triad}" \
    nvme="${nvme_json}" \
    ptp_offset_us="${ptp_offset_us}"

exit "${fail}"
