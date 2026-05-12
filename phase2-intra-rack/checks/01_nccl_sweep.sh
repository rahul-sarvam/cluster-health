#!/usr/bin/env bash
# 01_nccl_sweep.sh — Test 2.1
# NCCL all_reduce sweep at 8 / 16 / 32 / 64 GPUs (= 1 / 2 / 4 / 8 nodes).
# Captures bandwidth degradation curve as we cross 1, 2, 4, 8-node boundaries.
#
# Runs inside a sbatch allocation. Uses srun to subset the allocation down
# to each target scale, runs all_reduce_perf, captures stdout per scale,
# and emits a single JSON fragment with the busbw at the largest message
# size for each scale point. Aggregation lives in
# aggregate/parse_nccl.py / aggregate/analyze_curve.py.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../slurm/env.sh
source "${SCRIPT_DIR}/../slurm/env.sh"

CHECK="01_nccl_sweep"
ALL_REDUCE_BIN="${NCCL_TESTS_DIR}/all_reduce_perf"

if [[ ! -x "${ALL_REDUCE_BIN}" ]]; then
    p2_emit "${CHECK}" fail reason=missing_binary path="${ALL_REDUCE_BIN}"
    exit 1
fi

# Sanity: we must be inside an allocation with at least 8 nodes.
ALLOC_NODES="${SLURM_NNODES:-0}"
if [[ "${ALLOC_NODES}" -lt 8 ]]; then
    p2_emit "${CHECK}" fail reason=allocation_too_small allocated="${ALLOC_NODES}" required=8
    exit 1
fi

# Per-scale output dir.
out_dir="${P2_RESULTS}/${CHECK}_${SLURM_JOB_ID}"
mkdir -p "${out_dir}"

# Pre-build the JSON array of scale results manually as a string we'll
# embed into the final emit. (The aggregator also reads the raw outputs
# directly, so this is mainly for human-friendly status.)
scales_summary='['
sep=''
overall_status="pass"
fail_reasons=""

for n in ${P2_SCALE_NODES}; do
    ntasks=$((n * P2_GPUS_PER_NODE))
    target=$(p2_busbw_target_for_scale "${n}")
    p2_log "${CHECK}: scale=${n} nodes (${ntasks} GPUs) target_busbw>=${target} GB/s"

    log_file="${out_dir}/scale_${n}n.log"
    # all_reduce_perf flags:
    #   -b 8 -e 8G -f 2  : sweep 8 B to 8 GiB doubling each step
    #   -g 1             : one GPU per process
    #   -c 1             : verify correctness on each iter
    #   -n 20 -w 5       : 20 iters, 5 warmup
    srun --nodes="${n}" \
         --ntasks="${ntasks}" \
         --ntasks-per-node="${P2_GPUS_PER_NODE}" \
         --gpus-per-task=1 \
         --output="${log_file}" \
         --error="${log_file}" \
         "${ALL_REDUCE_BIN}" -b 8 -e 8G -f 2 -g 1 -c 1 -n 20 -w 5 \
        || { fail_reasons+="srun_failed_at_${n}n;"; overall_status="fail"; continue; }

    # Pull the last-row busbw (largest message size) from the log.
    # Row format: "<size> <count> <type> <op> <root> <time> <algbw> <busbw> ..."
    busbw=$(awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/ {b=$NF; bb=$(NF-1); a=$(NF-3)} END {print bb}' "${log_file}")
    if [[ -z "${busbw}" ]]; then
        fail_reasons+="parse_failed_at_${n}n;"; overall_status="fail"
        scales_summary+="${sep}{\"nodes\":${n},\"status\":\"parse_failed\"}"
    else
        # Compare against target (float compare in awk).
        below_target=$(awk -v a="${busbw}" -v t="${target}" 'BEGIN{print (a+0<t+0)?"1":"0"}')
        if [[ "${below_target}" -eq 1 ]]; then
            fail_reasons+="below_target_at_${n}n_busbw=${busbw}_target=${target};"
            overall_status="fail"
            scale_status="fail"
        else
            scale_status="pass"
        fi
        scales_summary+="${sep}{\"nodes\":${n},\"gpus\":${ntasks},\"busbw_gbs\":${busbw},\"target_gbs\":${target},\"status\":\"${scale_status}\",\"log\":\"${log_file}\"}"
    fi
    sep=','
done
scales_summary+=']'

if [[ "${overall_status}" == "pass" ]]; then
    p2_emit "${CHECK}" pass scales="${scales_summary}" out_dir="${out_dir}"
else
    # Strip trailing ; from fail_reasons.
    fail_reasons="${fail_reasons%;}"
    p2_emit "${CHECK}" fail reasons="${fail_reasons}" scales="${scales_summary}" out_dir="${out_dir}"
    exit 2
fi
