#!/usr/bin/env bash
#SBATCH --job-name=phase3_fullscale
#SBATCH --nodes=128
#SBATCH --ntasks-per-node=8
#SBATCH --gpus-per-node=8
#SBATCH --time=12:00:00
#SBATCH --exclusive
#SBATCH --output=/opt/qualification/phase3/logs/phase3_%j.out
#SBATCH --error=/opt/qualification/phase3/logs/phase3_%j.err
#
# Phase 3 — Cross-Spine / Full-Scale.
# Single Slurm job spanning the full cluster (128 nodes × 8 GPUs = 1024 GPUs).
# 11 checks run inside one allocation. Test order matters:
#
#   - Check 11 (UFM snapshot) runs FIRST to capture baseline counters,
#     then is invoked again at the END to compute deltas.
#   - Check 07 (FEC capture) also runs at both ends to detect any link
#     that degraded mid-run.
#
# All other checks run in numeric order. We don't bail on the first
# failure; we want the full picture from one allocation.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHECKS_DIR="${ROOT}/checks"
AGG_DIR="${ROOT}/aggregate"

# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

p3_log "phase3: starting on $(scontrol show hostnames "${SLURM_JOB_NODELIST}" | wc -l) nodes (job ${SLURM_JOB_ID})"

overall_rc=0
record_rc() {
    local rc="$1" name="$2"
    if [[ "${rc}" -eq 0 ]]; then p3_log "phase3: ${name} OK"; return; fi
    p3_log "phase3: ${name} exited rc=${rc}"
    if [[ "${rc}" -eq 1 ]] && [[ "${overall_rc}" -lt 1 ]]; then overall_rc=1
    elif [[ "${rc}" -ge 2 ]] && [[ "${overall_rc}" -lt 2 ]]; then overall_rc=2
    fi
}

# --- Bookend: capture baselines BEFORE running stress workloads ---
p3_log "phase3: --- BASELINE: ufm_snapshot + fec_sweep ---"
P3_PHASE=baseline bash "${CHECKS_DIR}/11_ufm_snapshot.sh"; record_rc $? "11_ufm_snapshot(baseline)"
P3_PHASE=baseline bash "${CHECKS_DIR}/07_fec_sweep.sh"; record_rc $? "07_fec_sweep(baseline)"

# --- Body: NCCL + fabric + HPC, in numeric order ---
for script in \
    "${CHECKS_DIR}/01_nccl_all5.sh" \
    "${CHECKS_DIR}/02_nccl_variance.sh" \
    "${CHECKS_DIR}/03_sharp_compare.sh" \
    "${CHECKS_DIR}/04_clusterkit_fullscale.sh" \
    "${CHECKS_DIR}/05_ar_congestion.sh" \
    "${CHECKS_DIR}/06_ib_latency.sh" \
    "${CHECKS_DIR}/08_hpl_fp64.sh" \
    "${CHECKS_DIR}/09_hpl_mxp.sh" \
    "${CHECKS_DIR}/10_hpcg.sh"
do
    name="$(basename "${script}")"
    p3_log "phase3: --- ${name} ---"
    bash "${script}"; record_rc $? "${name}"
done

# --- Bookend: re-capture, then diff against baseline in the aggregator ---
p3_log "phase3: --- FINAL: ufm_snapshot + fec_sweep ---"
P3_PHASE=final bash "${CHECKS_DIR}/11_ufm_snapshot.sh"; record_rc $? "11_ufm_snapshot(final)"
P3_PHASE=final bash "${CHECKS_DIR}/07_fec_sweep.sh"; record_rc $? "07_fec_sweep(final)"

# --- Aggregate ---
p3_log "phase3: running aggregator"
if [[ -x "${AGG_DIR}/report.py" ]]; then
    python3 "${AGG_DIR}/report.py" \
        --results-dir "${P3_RESULTS}" \
        --job-id "${SLURM_JOB_ID}" \
        --out "${P3_RESULTS}/phase3_report_${SLURM_JOB_ID}.md" \
        || p3_log "phase3: aggregator exited non-zero"
fi

p3_log "phase3: done (overall_rc=${overall_rc})"
exit "${overall_rc}"
