#!/usr/bin/env bash
# 03_sharp_compare.sh — Test 3.3
# SHARP on vs SHARP off: do two full-cluster all-reduces, one with
# NCCL_COLLNET_ENABLE=1 (SHARP in-network reduction), one with =0
# (point-to-point fallback). Confirm SHARP is faster by at least
# P3_SHARP_MIN_GAIN_PCT, and that SHARP actually engaged (the log
# contains a sharp-related message).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../slurm/env.sh
source "${SCRIPT_DIR}/../slurm/env.sh"

CHECK="03_sharp_compare"
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

run_with() {
    local label="$1" collnet="$2"
    local log="${out_dir}/${label}.log"
    p3_log "${CHECK}: ${label} (NCCL_COLLNET_ENABLE=${collnet})"
    srun --nodes="${n}" \
         --ntasks="${ntasks}" \
         --ntasks-per-node="${P3_GPUS_PER_NODE}" \
         --gpus-per-task=1 \
         --output="${log}" --error="${log}" \
         --export=ALL,NCCL_COLLNET_ENABLE="${collnet}",NCCL_DEBUG=INFO,NCCL_DEBUG_SUBSYS=COLL \
         "${ALL_REDUCE_BIN}" -b 1G -e 8G -f 2 -g 1 -c 1 -n 20 -w 5 \
        || { echo "srun_failed"; return 1; }
    # Last-row busbw at largest size.
    awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/ {b=$(NF-1)} END {print b}' "${log}"
}

off_busbw=$(run_with sharp_off 0) || true
on_busbw=$(run_with sharp_on 1)   || true

if [[ -z "${off_busbw}" || -z "${on_busbw}" \
      || "${off_busbw}" == "srun_failed" || "${on_busbw}" == "srun_failed" ]]; then
    p3_emit "${CHECK}" fail reason=run_failed off_busbw="${off_busbw:-null}" on_busbw="${on_busbw:-null}" out_dir="${out_dir}"
    exit 2
fi

# Verify SHARP actually engaged in the ON run.
sharp_present=0
if grep -qiE "SHARP|collnet" "${out_dir}/sharp_on.log"; then sharp_present=1; fi

gain_pct=$(awk -v on="${on_busbw}" -v off="${off_busbw}" \
    'BEGIN{ if (off+0<=0) print 0; else printf "%.3f", (on-off)/off*100 }')

over=$(awk -v g="${gain_pct}" -v t="${P3_SHARP_MIN_GAIN_PCT}" 'BEGIN{print (g+0>=t+0)?"1":"0"}')

if [[ "${over}" -eq 1 ]] && [[ "${sharp_present}" -eq 1 ]]; then
    p3_emit "${CHECK}" pass \
        off_busbw_gbs="${off_busbw}" on_busbw_gbs="${on_busbw}" \
        sharp_gain_pct="${gain_pct}" sharp_log_present=true \
        threshold_pct="${P3_SHARP_MIN_GAIN_PCT}" out_dir="${out_dir}"
else
    reason="below_gain_threshold"
    [[ "${sharp_present}" -eq 0 ]] && reason="sharp_not_engaged_in_log"
    p3_emit "${CHECK}" fail reason="${reason}" \
        off_busbw_gbs="${off_busbw}" on_busbw_gbs="${on_busbw}" \
        sharp_gain_pct="${gain_pct}" sharp_log_present="$( [[ "${sharp_present}" -eq 1 ]] && echo true || echo false )" \
        threshold_pct="${P3_SHARP_MIN_GAIN_PCT}" out_dir="${out_dir}"
    exit 2
fi
