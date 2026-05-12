#!/usr/bin/env bash
# 07_fec_sweep.sh — Test 3.7
# Capture mlxlink FEC / BER counters from every node's IB NICs.
# Invoked twice from the sbatch wrapper:
#   P3_PHASE=baseline  — captured at the start of Phase 3
#   P3_PHASE=final     — captured at the end
# The aggregator diffs them: any port whose pre-FEC BER crossed the
# ceiling OR whose post-FEC error counter increased fails 3.7.
#
# This script only collects raw data — verdict is the aggregator's job.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../slurm/env.sh
source "${SCRIPT_DIR}/../slurm/env.sh"

CHECK="07_fec_sweep"
PHASE="${P3_PHASE:-baseline}"
case "${PHASE}" in baseline|final) ;; *) PHASE=baseline ;; esac

if ! command -v mlxlink >/dev/null 2>&1; then
    p3_emit "${CHECK}_${PHASE}" skip reason=mlxlink_missing
    exit 0
fi

out_dir="${P3_RESULTS}/${CHECK}_${SLURM_JOB_ID}/${PHASE}"
mkdir -p "${out_dir}"

p3_log "${CHECK}: phase=${PHASE}: collecting mlxlink dumps from all nodes"

# Run on every allocated node, one rank per node. mlxlink output goes
# to ${out_dir}/<hostname>.txt via Slurm's --output filename template.
srun --nodes="${SLURM_NNODES}" \
     --ntasks="${SLURM_NNODES}" \
     --ntasks-per-node=1 \
     --output="${out_dir}/%n.txt" --error="${out_dir}/%n.err" \
     bash -c '
        host=$(hostname)
        echo "===== HOST: $host ====="
        echo "===== timestamp: $(date -Iseconds) ====="
        # mst start is idempotent; needed for mlxlink to enumerate devices.
        mst start >/dev/null 2>&1 || true
        # Enumerate all mlx5_* devices and dump their port stats.
        for dev in $(ibstat -l 2>/dev/null); do
            echo "----- DEVICE: $dev -----"
            mlxlink -d "$dev" --show_eye --show_fec --pf 1 2>&1 || true
            mlxlink -d "$dev" --show_counters 2>&1 || true
        done
     ' \
    || { p3_emit "${CHECK}_${PHASE}" fail reason=srun_failed out_dir="${out_dir}"; exit 2; }

# Count how many host dumps we got. Aggregator will parse the actual values.
host_count=$(find "${out_dir}" -maxdepth 1 -name "*.txt" | wc -l)

p3_emit "${CHECK}_${PHASE}" pass phase="${PHASE}" host_count="${host_count}" out_dir="${out_dir}"
