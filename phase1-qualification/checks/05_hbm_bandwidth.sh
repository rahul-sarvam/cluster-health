#!/usr/bin/env bash
# 05_hbm_bandwidth.sh
# Per-GPU HBM3e bandwidth via BabelStream (cuda-stream). Catches partly-failed
# HBM stacks, which usually present as one GPU ~12.5% slower than the others
# (one of 8 HBM stacks down).
set -uo pipefail
source "${QUAL_ROOT}/slurm/env.sh"

OUT="${QUAL_LOGS}/$(hostname)_babelstream.txt"

# Skip cleanly if BabelStream / cuda-stream isn't installed (e.g. nvcc
# unavailable so bootstrap couldn't build it on this image).
if ! [[ -x "${BABELSTREAM_BIN}" ]]; then
    qual_emit hbm_bandwidth skip reason="babelstream_binary_missing" path="${BABELSTREAM_BIN}"
    exit 0
fi

: > "${OUT}"

triads=()
fail=0
for gpu in $(seq 0 $((EXPECTED_GPU_COUNT-1))); do
    CUDA_VISIBLE_DEVICES="${gpu}" "${BABELSTREAM_BIN}" -s $((1<<28)) -n 50 >> "${OUT}" 2>&1
    triad=$(grep -A1 "Triad" "${OUT}" | tail -n1 | awk '{print $1}')
    triads+=("${triad}")
    awk -v t="${triad}" -v min="${HBM_TRIAD_MIN_GBS}" 'BEGIN {exit !(t+0 < min+0)}' && {
        qual_log "HBM bandwidth too low on GPU ${gpu}: ${triad} GB/s < ${HBM_TRIAD_MIN_GBS}"
        fail=1
    }
done

# Detect intra-node outlier: any GPU > 2% below this node's median.
median=$(printf '%s\n' "${triads[@]}" | sort -n | awk 'BEGIN {c=0} {a[c++]=$1} END {print (c%2==1) ? a[int(c/2)] : (a[c/2-1]+a[c/2])/2.0}')
for i in "${!triads[@]}"; do
    t="${triads[$i]}"
    if awk -v t="${t}" -v m="${median}" 'BEGIN {exit !(t < 0.98*m)}'; then
        qual_log "HBM intra-node outlier: GPU ${i} = ${t} GB/s (node median ${median})"
        fail=1
    fi
done

status="pass"; [[ "${fail}" -eq 1 ]] && status="fail"
triads_json="[$(IFS=,; echo "${triads[*]}")]"
qual_emit hbm_bandwidth "${status}" \
    log_path="${OUT}" \
    triad_gbs="${triads_json}" \
    node_median_gbs="${median}"

exit "${fail}"
