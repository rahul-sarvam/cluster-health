#!/usr/bin/env bash
#SBATCH --job-name=qualify-day1
#SBATCH --partition=acceptance          # TODO: replace with your partition name
#SBATCH --array=0-127                   # 128 nodes; one task per node
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --gpus-per-node=8
#SBATCH --exclusive
#SBATCH --time=02:00:00
#SBATCH --output=/opt/qualification/day1/logs/slurm-%A_%a.out
#SBATCH --error=/opt/qualification/day1/logs/slurm-%A_%a.err
# Pin each array task to a specific node so we have a deterministic mapping
# from array index -> hostname. The nodelist must be supplied via --nodelist
# from the sbatch caller, OR be replaced with the explicit list below.

set -euo pipefail

QUAL_ROOT="${QUAL_ROOT:-/opt/qualification/day1}"
source "${QUAL_ROOT}/slurm/env.sh"

qual_log "Slurm array task ${SLURM_ARRAY_TASK_ID} running on $(hostname)"
qual_log "Job ID = ${SLURM_JOB_ID}"

# Fail fast if the node is already known-bad: refuse to run on a node with
# any uncleared XID errors since boot.
if dmesg | grep -qE 'NVRM: Xid.*: (31|43|45|61|63|64|74|79)'; then
    qual_log "FATAL: node has uncleared critical XID errors in dmesg"
    qual_emit pre_flight fail reason="critical_xid_in_dmesg"
    exit 1
fi

# Run the orchestrator. It runs every check sequentially, captures output,
# and emits one JSON file per check into ${QUAL_RESULTS}.
"${QUAL_ROOT}/run_node.sh"
RC=$?

# Roll up the per-check JSONs into a single per-node JSON.
python3 "${QUAL_ROOT}/aggregate/parse_results.py" \
    --per-host "$(hostname)" \
    --in-dir "${QUAL_RESULTS}" \
    --out "${QUAL_RESULTS}/$(hostname).json"

qual_log "Node finished with rc=${RC}"
exit "${RC}"
