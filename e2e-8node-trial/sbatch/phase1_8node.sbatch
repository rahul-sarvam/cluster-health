#!/usr/bin/env bash
#SBATCH --job-name=e2e8_phase1
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --gpus-per-node=8
#SBATCH --exclusive
# --output/--error/--array/--partition/--time are passed by run_all.sh
# via the sbatch command line so they pick up ${E2E_RUN_DIR}.
#
# Phase 1 per-node qualification, narrowed to N nodes (one array task
# per node). Re-uses the existing phase1-qualification/run_node.sh; we
# only set the overrides in env-8node.sh and direct its outputs to
# ${E2E_RUN_DIR}/phase1/.

set -u

: "${E2E_RUN_DIR:?E2E_RUN_DIR must be set in the inherited env}"
: "${E2E_REPO_ROOT:?E2E_REPO_ROOT must be set in the inherited env}"

source "${E2E_REPO_ROOT}/e2e-8node-trial/env-8node.sh"

# Source the original phase1 env *after* our overrides, so QUAL_RESULTS
# and friends are already pinned to ${E2E_RUN_DIR}/phase1/...
source "${QUAL_ROOT}/slurm/env.sh"

qual_log "phase1 (8-node trial) array task ${SLURM_ARRAY_TASK_ID:-0} on $(hostname)"
qual_log "results landing in ${QUAL_RESULTS}"
qual_log "logs    landing in ${QUAL_LOGS}"

# Same pre-flight bail as the original wrapper.
if dmesg | grep -qE 'NVRM: Xid.*: (31|43|45|61|63|64|74|79)'; then
    qual_log "FATAL: node has uncleared critical XID errors in dmesg"
    qual_emit pre_flight fail reason="critical_xid_in_dmesg"
    exit 1
fi

"${QUAL_ROOT}/run_node.sh"
RC=$?

# Roll the per-check JSONs into a per-host JSON.
python3 "${QUAL_ROOT}/aggregate/parse_results.py" \
    --per-host "$(hostname)" \
    --in-dir "${QUAL_RESULTS}" \
    --out "${QUAL_RESULTS}/$(hostname).json" || true

qual_log "phase1 node finished rc=${RC}"
exit "${RC}"
