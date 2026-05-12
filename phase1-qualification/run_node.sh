#!/usr/bin/env bash
# Per-node orchestrator. Runs every check in order. Failure of any check
# does NOT short-circuit later checks: we want all data per node so the
# aggregator has full information for outlier analysis. The script's exit
# code is the number of failed checks (0 = clean).
set -uo pipefail

QUAL_ROOT="${QUAL_ROOT:-/opt/qualification/phase1}"
source "${QUAL_ROOT}/slurm/env.sh"

CHECKS=(
    01_node_sanity.sh
    02_firmware_inventory.sh
    03_dcgm_diag.sh
    04_nvbandwidth.sh
    05_hbm_bandwidth.sh
    06_gpu_burn.sh
    07_intra_node_nccl.sh
    08_ib_health.sh
    09_ib_loopback_bw.sh
    10_host_health.sh
)

FAILED=0
for c in "${CHECKS[@]}"; do
    qual_log "==> START ${c}"
    if bash "${QUAL_ROOT}/checks/${c}"; then
        qual_log "<== PASS  ${c}"
    else
        qual_log "<== FAIL  ${c}"
        FAILED=$((FAILED+1))
    fi
done

qual_log "Total failed checks on $(hostname): ${FAILED}"
exit "${FAILED}"
