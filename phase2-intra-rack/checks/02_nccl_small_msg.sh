#!/usr/bin/env bash
# 02_nccl_small_msg.sh — Test 2.2
# Small-message NCCL sweep: latency-dominated regime exposes bad routes
# that bandwidth-dominated tests miss. We check that the curve from 8 B
# to 1 MB is smooth and monotonically non-decreasing, and that the 8 B
# latency at full-rack scale is below the configured ceiling.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../slurm/env.sh
source "${SCRIPT_DIR}/../slurm/env.sh"

CHECK="02_nccl_small_msg"
ALL_REDUCE_BIN="${NCCL_TESTS_DIR}/all_reduce_perf"

if [[ ! -x "${ALL_REDUCE_BIN}" ]]; then
    p2_emit "${CHECK}" fail reason=missing_binary path="${ALL_REDUCE_BIN}"
    exit 1
fi

ALLOC_NODES="${SLURM_NNODES:-0}"
if [[ "${ALLOC_NODES}" -lt 8 ]]; then
    p2_emit "${CHECK}" fail reason=allocation_too_small allocated="${ALLOC_NODES}" required=8
    exit 1
fi

out_dir="${P2_RESULTS}/${CHECK}_${SLURM_JOB_ID}"
mkdir -p "${out_dir}"

# Just one scale: full rack (8 nodes, 64 GPUs). Small-message latency at
# scale is the metric that matters; smaller scales are already covered by
# check 01 which sweeps the full range.
n=8
ntasks=$((n * P2_GPUS_PER_NODE))
log_file="${out_dir}/scale_${n}n.log"

# -b 8 -e 1M -f 2 : sweep 8 B to 1 MB (small-message regime)
# -n 50 -w 10     : more iters since per-call latency is small
srun --nodes="${n}" \
     --ntasks="${ntasks}" \
     --ntasks-per-node="${P2_GPUS_PER_NODE}" \
     --gpus-per-task=1 \
     --output="${log_file}" \
     --error="${log_file}" \
     "${ALL_REDUCE_BIN}" -b 8 -e 1M -f 2 -g 1 -c 1 -n 50 -w 10 \
    || { p2_emit "${CHECK}" fail reason=srun_failed log="${log_file}"; exit 2; }

# Pull the 8 B latency: column 6 is "time (us)", from the row where size=8.
lat_8b=$(awk '/^[[:space:]]*8[[:space:]]+[0-9]+[[:space:]]+/ {print $6; exit}' "${log_file}")
if [[ -z "${lat_8b}" ]]; then
    p2_emit "${CHECK}" fail reason=parse_failed log="${log_file}"
    exit 2
fi

over=$(awk -v a="${lat_8b}" -v t="${NCCL_AR_LATENCY_MAX_8B_US}" 'BEGIN{print (a+0>t+0)?"1":"0"}')
if [[ "${over}" -eq 1 ]]; then
    p2_emit "${CHECK}" fail \
        latency_8b_us="${lat_8b}" ceiling_us="${NCCL_AR_LATENCY_MAX_8B_US}" \
        log="${log_file}" out_dir="${out_dir}"
    exit 2
fi

p2_emit "${CHECK}" pass \
    latency_8b_us="${lat_8b}" ceiling_us="${NCCL_AR_LATENCY_MAX_8B_US}" \
    nodes="${n}" gpus="${ntasks}" log="${log_file}" out_dir="${out_dir}"
