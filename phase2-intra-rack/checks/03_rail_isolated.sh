#!/usr/bin/env bash
# 03_rail_isolated.sh — Test 2.3
# Rail-isolated all-reduce: pin NCCL to exactly one HCA at a time, run an
# all_reduce, record the busbw. Repeat for every rail. A single bad rail
# (cable, transceiver, NIC, or leaf-port) shows up as one outlier.
#
# Default: scope is full rack (8 nodes, 64 GPUs). One run per rail.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../slurm/env.sh
source "${SCRIPT_DIR}/../slurm/env.sh"

CHECK="03_rail_isolated"
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

n=8
ntasks=$((n * P2_GPUS_PER_NODE))

rails_summary='['
sep=''
rail_busbws=()

for r in $(seq 0 $((P2_RAIL_COUNT - 1))); do
    rail_dev="$(p2_rail_dev "${r}")"
    log_file="${out_dir}/rail_${r}.log"
    p2_log "${CHECK}: rail ${r} (${rail_dev})"

    # Pin NCCL to a single HCA via NCCL_IB_HCA. The leading '^' inverts
    # the list to "exclude all but this one"; here we just list the one we want.
    NCCL_IB_HCA="${rail_dev}" \
    NCCL_DEBUG="${NCCL_DEBUG}" \
    srun --nodes="${n}" \
         --ntasks="${ntasks}" \
         --ntasks-per-node="${P2_GPUS_PER_NODE}" \
         --gpus-per-task=1 \
         --output="${log_file}" \
         --error="${log_file}" \
         --export=ALL,NCCL_IB_HCA="${rail_dev}",NCCL_DEBUG="${NCCL_DEBUG}" \
         "${ALL_REDUCE_BIN}" -b 1G -e 8G -f 2 -g 1 -c 1 -n 20 -w 5 \
        || { rails_summary+="${sep}{\"rail\":${r},\"dev\":\"${rail_dev}\",\"status\":\"srun_failed\"}"; sep=','; continue; }

    busbw=$(awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/ {bb=$(NF-1)} END {print bb}' "${log_file}")
    if [[ -z "${busbw}" ]]; then
        rails_summary+="${sep}{\"rail\":${r},\"dev\":\"${rail_dev}\",\"status\":\"parse_failed\"}"
        sep=','
        continue
    fi
    rail_busbws+=("${busbw}")
    rails_summary+="${sep}{\"rail\":${r},\"dev\":\"${rail_dev}\",\"busbw_gbs\":${busbw},\"log\":\"${log_file}\"}"
    sep=','
done
rails_summary+=']'

# Compute median + outlier check in awk so we have zero Python dep here.
if [[ "${#rail_busbws[@]}" -lt 2 ]]; then
    p2_emit "${CHECK}" fail reason=too_few_rails_measured rails="${rails_summary}"
    exit 2
fi

# Median:
median=$(printf '%s\n' "${rail_busbws[@]}" | sort -n | awk '
    { a[NR] = $1 }
    END {
        if (NR % 2) print a[(NR+1)/2]
        else print (a[NR/2] + a[NR/2 + 1]) / 2
    }')

# Min:
min=$(printf '%s\n' "${rail_busbws[@]}" | sort -n | head -1)

# Outlier % below median:
pct_below=$(awk -v min="${min}" -v med="${median}" 'BEGIN{
    if (med==0) print "0";
    else printf "%.3f", (med-min)/med*100
}')

over=$(awk -v p="${pct_below}" -v t="${P2_RAIL_OUTLIER_PCT}" 'BEGIN{print (p+0>t+0)?"1":"0"}')
if [[ "${over}" -eq 1 ]]; then
    p2_emit "${CHECK}" fail \
        median_gbs="${median}" min_gbs="${min}" pct_below_median="${pct_below}" \
        threshold_pct="${P2_RAIL_OUTLIER_PCT}" rails="${rails_summary}" \
        out_dir="${out_dir}"
    exit 2
fi

p2_emit "${CHECK}" pass \
    median_gbs="${median}" min_gbs="${min}" pct_below_median="${pct_below}" \
    threshold_pct="${P2_RAIL_OUTLIER_PCT}" rails="${rails_summary}" \
    out_dir="${out_dir}"
