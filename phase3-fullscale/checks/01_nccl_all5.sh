#!/usr/bin/env bash
# 01_nccl_all5.sh — Test 3.1
# Run all five NCCL collectives at the three full-cluster scale points
# (256 / 512 / 1024 GPUs). Captures the bandwidth degradation curve as
# we cross spine boundaries.
#
# Acceptance criteria (defaults; override in env.sh):
#   - all_reduce busbw at 1024 GPUs ≥ NCCL_AR_BUSBW_MIN_1024GPU_GBS
#   - no >P3_64_TO_1024_CLIFF_PCT cliff between 64 and 1024 GPUs

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../slurm/env.sh
source "${SCRIPT_DIR}/../slurm/env.sh"

CHECK="01_nccl_all5"

# Each collective has its own NCCL test binary.
declare -A BIN_MAP=(
    [all_reduce]="${NCCL_TESTS_DIR}/all_reduce_perf"
    [all_gather]="${NCCL_TESTS_DIR}/all_gather_perf"
    [reduce_scatter]="${NCCL_TESTS_DIR}/reduce_scatter_perf"
    [alltoall]="${NCCL_TESTS_DIR}/alltoall_perf"
    [sendrecv]="${NCCL_TESTS_DIR}/sendrecv_perf"
)

for c in "${!BIN_MAP[@]}"; do
    if [[ ! -x "${BIN_MAP[$c]}" ]]; then
        p3_emit "${CHECK}" fail reason=missing_binary collective="${c}" path="${BIN_MAP[$c]}"
        exit 1
    fi
done

if ! p3_have_full_scale; then
    p3_emit "${CHECK}" fail reason=allocation_too_small allocated="${SLURM_NNODES:-0}" required="${P3_FULL_NODES}"
    exit 1
fi

out_dir="${P3_RESULTS}/${CHECK}_${SLURM_JOB_ID}"
mkdir -p "${out_dir}"

results_summary='['; sep=''
overall_status="pass"
fail_reasons=""

for n in ${P3_SCALE_NODES}; do
    ntasks=$((n * P3_GPUS_PER_NODE))
    for c in all_reduce all_gather reduce_scatter alltoall sendrecv; do
        bin="${BIN_MAP[$c]}"
        target=$(p3_busbw_target_for_collective "${c}" "${ntasks}")
        log_file="${out_dir}/${c}_${n}n.log"
        p3_log "${CHECK}: ${c} at ${n}n / ${ntasks} GPUs (target≥${target})"

        srun --nodes="${n}" \
             --ntasks="${ntasks}" \
             --ntasks-per-node="${P3_GPUS_PER_NODE}" \
             --gpus-per-task=1 \
             --output="${log_file}" --error="${log_file}" \
             "${bin}" -b 8 -e 8G -f 2 -g 1 -c 1 -n 20 -w 5 \
            || { fail_reasons+="srun_failed:${c}@${n}n;"; overall_status="fail"
                 results_summary+="${sep}{\"collective\":\"${c}\",\"nodes\":${n},\"gpus\":${ntasks},\"status\":\"srun_failed\"}"
                 sep=','; continue; }

        # Pull last-row busbw from the log (column N-1 of last numeric row).
        busbw=$(awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/ {b=$(NF-1)} END {print b}' "${log_file}")
        if [[ -z "${busbw}" ]]; then
            fail_reasons+="parse_failed:${c}@${n}n;"; overall_status="fail"
            results_summary+="${sep}{\"collective\":\"${c}\",\"nodes\":${n},\"gpus\":${ntasks},\"status\":\"parse_failed\"}"
            sep=','; continue
        fi
        below=$(awk -v a="${busbw}" -v t="${target}" 'BEGIN{print (a+0<t+0)?"1":"0"}')
        if [[ "${below}" -eq 1 ]] && [[ "${target}" -gt 0 ]] 2>/dev/null; then
            fail_reasons+="below_target:${c}@${n}n_busbw=${busbw}_target=${target};"
            overall_status="fail"
            point_status="fail"
        else
            point_status="pass"
        fi
        results_summary+="${sep}{\"collective\":\"${c}\",\"nodes\":${n},\"gpus\":${ntasks},\"busbw_gbs\":${busbw},\"target_gbs\":${target},\"status\":\"${point_status}\"}"
        sep=','
    done
done
results_summary+=']'

if [[ "${overall_status}" == "pass" ]]; then
    p3_emit "${CHECK}" pass results="${results_summary}" out_dir="${out_dir}"
else
    fail_reasons="${fail_reasons%;}"
    p3_emit "${CHECK}" fail reasons="${fail_reasons}" results="${results_summary}" out_dir="${out_dir}"
    exit 2
fi
