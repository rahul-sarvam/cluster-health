#!/usr/bin/env bash
#SBATCH --job-name=e2e8_phase2
#SBATCH --ntasks-per-node=8
#SBATCH --gpus-per-node=8
#SBATCH --exclusive
# --nodes/--output/--error/--time/--partition are passed from run_all.sh
#
# Phase 2 — intra-cluster collectives on 8 nodes. Re-uses the existing
# phase2-intra-rack checks; we just redirect outputs into ${E2E_RUN_DIR}.

set -u

: "${E2E_RUN_DIR:?E2E_RUN_DIR must be set in the inherited env}"
: "${E2E_REPO_ROOT:?E2E_REPO_ROOT must be set in the inherited env}"

source "${E2E_REPO_ROOT}/e2e-8node-trial/env-8node.sh"
source "${P2_ROOT}/slurm/env.sh"

CHECKS_DIR="${P2_ROOT}/checks"
AGG_DIR="${P2_ROOT}/aggregate"

p2_log "phase2 (8-node trial) on $(scontrol show hostnames "${SLURM_JOB_NODELIST}" | wc -l) nodes (job ${SLURM_JOB_ID})"
p2_log "results landing in ${P2_RESULTS}"

overall_rc=0
for script in \
    "${CHECKS_DIR}/01_nccl_sweep.sh" \
    "${CHECKS_DIR}/02_nccl_small_msg.sh" \
    "${CHECKS_DIR}/03_rail_isolated.sh" \
    "${CHECKS_DIR}/04_clusterkit_intra.sh" \
    "${CHECKS_DIR}/05_osu_intra.sh" \
    "${CHECKS_DIR}/06_topo_check.sh"
do
    name="$(basename "${script}")"
    if [[ ! -x "${script}" ]] && [[ ! -r "${script}" ]]; then
        p2_log "phase2: ${name} missing — skipping"
        continue
    fi
    p2_log "phase2: --- ${name} ---"
    if bash "${script}"; then
        p2_log "phase2: ${name} OK"
    else
        rc=$?
        p2_log "phase2: ${name} exited rc=${rc}"
        if [[ "${rc}" -eq 1 ]] && [[ "${overall_rc}" -lt 1 ]]; then
            overall_rc=1
        elif [[ "${rc}" -ge 2 ]] && [[ "${overall_rc}" -lt 2 ]]; then
            overall_rc=2
        fi
    fi
done

p2_log "phase2: running aggregator"
if [[ -r "${AGG_DIR}/report.py" ]]; then
    python3 "${AGG_DIR}/report.py" \
        --results-dir "${P2_RESULTS}" \
        --job-id "${SLURM_JOB_ID}" \
        --out "${P2_RESULTS}/phase2_report_${SLURM_JOB_ID}.md" \
        || p2_log "phase2: aggregator exited non-zero"
fi

p2_log "phase2: done (overall_rc=${overall_rc})"
exit "${overall_rc}"
