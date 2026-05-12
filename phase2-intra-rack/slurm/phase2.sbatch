#!/usr/bin/env bash
#SBATCH --job-name=phase2_intra_rack
#SBATCH --nodes=8
#SBATCH --ntasks-per-node=8
#SBATCH --gpus-per-node=8
#SBATCH --time=02:00:00
#SBATCH --exclusive
#SBATCH --output=/opt/qualification/phase2/logs/phase2_%j.out
#SBATCH --error=/opt/qualification/phase2/logs/phase2_%j.err
#
# Phase 2 — Intra-Rack Scale
# Single Slurm job spanning one rack (8 nodes / 64 GPUs). All six checks
# run sequentially inside this allocation so the node set is constant
# across tests. The aggregator runs at the end to roll the JSON
# fragments up into a Markdown report.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHECKS_DIR="${ROOT}/checks"
AGG_DIR="${ROOT}/aggregate"

# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

p2_log "phase2: starting on $(scontrol show hostnames "${SLURM_JOB_NODELIST}" | wc -l) nodes (job ${SLURM_JOB_ID})"

# Run checks in numeric order. We don't bail on the first failure —
# we want the full picture from one allocation. Each check emits its
# own JSON fragment.
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
    p2_log "phase2: --- ${name} ---"
    if bash "${script}"; then
        p2_log "phase2: ${name} OK"
    else
        rc=$?
        p2_log "phase2: ${name} exited rc=${rc}"
        # rc=1 → infrastructure issue (missing binary, alloc too small); fatal-ish
        # rc=2 → check failed substantively; record but continue
        if [[ "${rc}" -eq 1 ]] && [[ "${overall_rc}" -lt 1 ]]; then
            overall_rc=1
        elif [[ "${rc}" -ge 2 ]] && [[ "${overall_rc}" -lt 2 ]]; then
            overall_rc=2
        fi
    fi
done

# Aggregate. Don't let the aggregator step mask the test verdict —
# we want the sbatch exit code to reflect the worst check.
p2_log "phase2: running aggregator"
if [[ -x "${AGG_DIR}/report.py" ]]; then
    python3 "${AGG_DIR}/report.py" \
        --results-dir "${P2_RESULTS}" \
        --job-id "${SLURM_JOB_ID}" \
        --out "${P2_RESULTS}/phase2_report_${SLURM_JOB_ID}.md" \
        || p2_log "phase2: aggregator exited non-zero"
fi

p2_log "phase2: done (overall_rc=${overall_rc})"
exit "${overall_rc}"
