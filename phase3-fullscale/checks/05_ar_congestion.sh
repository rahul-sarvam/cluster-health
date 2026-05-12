#!/usr/bin/env bash
# 05_ar_congestion.sh — Test 3.5
# Adaptive Routing under spine collision. We force a known-bad traffic
# pattern (shifted pairs that all hash to the same spine if static
# routing is in use) and measure aggregate bandwidth twice: once with
# AR off, once with AR on. Pass if AR-on recovers ≥P3_AR_RECOVERY_MIN_PCT
# of the uncongested baseline.
#
# Uses NCCL all-reduce on a shifted-pair pattern. The pattern is encoded
# by setting NCCL_ALGO=Tree (which forces every rank to talk to every
# other rank, maximising the chance of spine collision) and
# NCCL_IB_AR_THRESHOLD / NCCL_IB_ADAPTIVE_ROUTING to flip AR.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../slurm/env.sh
source "${SCRIPT_DIR}/../slurm/env.sh"

CHECK="05_ar_congestion"
ALL_REDUCE_BIN="${NCCL_TESTS_DIR}/all_reduce_perf"

if [[ ! -x "${ALL_REDUCE_BIN}" ]]; then
    p3_emit "${CHECK}" fail reason=missing_binary path="${ALL_REDUCE_BIN}"
    exit 1
fi
if ! p3_have_full_scale; then
    p3_emit "${CHECK}" fail reason=allocation_too_small allocated="${SLURM_NNODES:-0}" required="${P3_FULL_NODES}"
    exit 1
fi

out_dir="${P3_RESULTS}/${CHECK}_${SLURM_JOB_ID}"
mkdir -p "${out_dir}"

n="${P3_FULL_NODES}"
ntasks=$((n * P3_GPUS_PER_NODE))

# Baseline: AR on, ring algorithm (locality-aware, no collision).
# Congestion-on-AR-off: AR off, tree algorithm (collision-prone).
# Congestion-on-AR-on:  AR on, tree algorithm.
run_busbw() {
    local label="$1"; shift
    local log="${out_dir}/${label}.log"
    p3_log "${CHECK}: ${label}"
    srun --nodes="${n}" \
         --ntasks="${ntasks}" \
         --ntasks-per-node="${P3_GPUS_PER_NODE}" \
         --gpus-per-task=1 \
         --output="${log}" --error="${log}" \
         --export=ALL,"$@" \
         "${ALL_REDUCE_BIN}" -b 1G -e 8G -f 2 -g 1 -c 1 -n 20 -w 5 \
        || { echo ""; return 1; }
    awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/ {b=$(NF-1)} END {print b}' "${log}"
}

baseline=$(run_busbw baseline NCCL_ALGO=Ring NCCL_IB_ADAPTIVE_ROUTING=1) || true
collision_ar_off=$(run_busbw collision_ar_off NCCL_ALGO=Tree NCCL_IB_ADAPTIVE_ROUTING=0) || true
collision_ar_on=$(run_busbw collision_ar_on NCCL_ALGO=Tree NCCL_IB_ADAPTIVE_ROUTING=1) || true

if [[ -z "${baseline}" || -z "${collision_ar_off}" || -z "${collision_ar_on}" ]]; then
    p3_emit "${CHECK}" fail reason=run_failed \
        baseline="${baseline:-null}" ar_off="${collision_ar_off:-null}" ar_on="${collision_ar_on:-null}" \
        out_dir="${out_dir}"
    exit 2
fi

recovery_pct=$(awk -v b="${baseline}" -v ar="${collision_ar_on}" \
    'BEGIN{ if (b+0<=0) print 0; else printf "%.3f", ar/b*100 }')

over=$(awk -v a="${recovery_pct}" -v t="${P3_AR_RECOVERY_MIN_PCT}" 'BEGIN{print (a+0>=t+0)?"1":"0"}')

# Also report the AR uplift (AR-on vs AR-off under collision).
ar_uplift_pct=$(awk -v on="${collision_ar_on}" -v off="${collision_ar_off}" \
    'BEGIN{ if (off+0<=0) print 0; else printf "%.3f", (on-off)/off*100 }')

if [[ "${over}" -eq 1 ]]; then
    p3_emit "${CHECK}" pass \
        baseline_gbs="${baseline}" ar_off_gbs="${collision_ar_off}" ar_on_gbs="${collision_ar_on}" \
        recovery_pct="${recovery_pct}" ar_uplift_pct="${ar_uplift_pct}" \
        threshold_pct="${P3_AR_RECOVERY_MIN_PCT}" out_dir="${out_dir}"
else
    p3_emit "${CHECK}" fail reason=insufficient_recovery \
        baseline_gbs="${baseline}" ar_off_gbs="${collision_ar_off}" ar_on_gbs="${collision_ar_on}" \
        recovery_pct="${recovery_pct}" ar_uplift_pct="${ar_uplift_pct}" \
        threshold_pct="${P3_AR_RECOVERY_MIN_PCT}" out_dir="${out_dir}"
    exit 2
fi
