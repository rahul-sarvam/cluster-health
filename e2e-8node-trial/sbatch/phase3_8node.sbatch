#!/usr/bin/env bash
#SBATCH --job-name=e2e8_phase3
#SBATCH --ntasks-per-node=8
#SBATCH --gpus-per-node=8
#SBATCH --exclusive
# --nodes/--output/--error/--time/--partition supplied by run_all.sh
#
# Phase 3 — collectives at 8-node scale. We drop the platform-side
# bookended checks (UFM snapshot, FEC sweep) which require provider
# fabric access we don't have on Slinky, and the SHARP/AR A/B which is
# provider-toggled. The remaining checks port unchanged.

set -u

: "${E2E_RUN_DIR:?E2E_RUN_DIR must be set in the inherited env}"
: "${E2E_REPO_ROOT:?E2E_REPO_ROOT must be set in the inherited env}"

source "${E2E_REPO_ROOT}/e2e-8node-trial/env-8node.sh"
source "${P3_ROOT}/slurm/env.sh"

CHECKS_DIR="${P3_ROOT}/checks"
AGG_DIR="${P3_ROOT}/aggregate"

p3_log "phase3 (8-node trial) on $(scontrol show hostnames "${SLURM_JOB_NODELIST}" | wc -l) nodes (job ${SLURM_JOB_ID})"
p3_log "results landing in ${P3_RESULTS}"
p3_log "skipping: ufm_snapshot, fec_sweep, sharp_compare, ar_congestion (provider-side, not testable from tenant)"

overall_rc=0
record_rc() {
    local rc="$1" name="$2"
    if [[ "${rc}" -eq 0 ]]; then p3_log "phase3: ${name} OK"; return; fi
    p3_log "phase3: ${name} exited rc=${rc}"
    if [[ "${rc}" -eq 1 ]] && [[ "${overall_rc}" -lt 1 ]]; then overall_rc=1
    elif [[ "${rc}" -ge 2 ]] && [[ "${overall_rc}" -lt 2 ]]; then overall_rc=2
    fi
}

# Tenant-runnable checks. Order matches the original phase3 wrapper.
TENANT_CHECKS=(
    "${CHECKS_DIR}/01_nccl_all5.sh"
    "${CHECKS_DIR}/02_nccl_variance.sh"
    "${CHECKS_DIR}/04_clusterkit_fullscale.sh"
    "${CHECKS_DIR}/06_ib_latency.sh"
    "${CHECKS_DIR}/08_hpl_fp64.sh"
    "${CHECKS_DIR}/09_hpl_mxp.sh"
    "${CHECKS_DIR}/10_hpcg.sh"
)

# Emit a placeholder skip-record for each disabled provider-side check
# so the aggregator records the gap explicitly.
for skipped in 03_sharp_compare 05_ar_congestion 07_fec_sweep 11_ufm_snapshot; do
    out="${P3_RESULTS}/${skipped}_${SLURM_JOB_ID}.json"
    cat > "${out}" <<EOF
{"check":"${skipped}","status":"skip","ts":"$(date -Iseconds)","job_id":"${SLURM_JOB_ID}","reason":"not_testable_from_tenant_on_managed_platform"}
EOF
done

for script in "${TENANT_CHECKS[@]}"; do
    name="$(basename "${script}")"
    if [[ ! -r "${script}" ]]; then
        p3_log "phase3: ${name} missing — skipping"
        continue
    fi
    p3_log "phase3: --- ${name} ---"
    bash "${script}"
    record_rc $? "${name}"
done

p3_log "phase3: running aggregator"
if [[ -r "${AGG_DIR}/report.py" ]]; then
    python3 "${AGG_DIR}/report.py" \
        --results-dir "${P3_RESULTS}" \
        --job-id "${SLURM_JOB_ID}" \
        --out "${P3_RESULTS}/phase3_report_${SLURM_JOB_ID}.md" \
        || p3_log "phase3: aggregator exited non-zero"
fi

p3_log "phase3: done (overall_rc=${overall_rc})"
exit "${overall_rc}"
