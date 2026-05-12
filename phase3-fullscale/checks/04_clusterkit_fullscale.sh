#!/usr/bin/env bash
# 04_clusterkit_fullscale.sh — Test 3.4
# All-pairs bandwidth matrix at 1024 GPUs. Same logic as Phase 2's
# clusterkit check, but at full cluster scale. At this scale we get
# ~1024×1023 = ~1M off-diagonal pairs, so the median is very robust
# against single bad pairs; any outlier > P3_PAIR_OUTLIER_PCT below
# median is a real fabric issue.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../slurm/env.sh
source "${SCRIPT_DIR}/../slurm/env.sh"

CHECK="04_clusterkit_fullscale"

if [[ ! -x "${CLUSTERKIT_BIN}" ]]; then
    p3_emit "${CHECK}" skip reason=clusterkit_not_installed path="${CLUSTERKIT_BIN}"
    exit 0
fi
if ! p3_have_full_scale; then
    p3_emit "${CHECK}" fail reason=allocation_too_small allocated="${SLURM_NNODES:-0}" required="${P3_FULL_NODES}"
    exit 1
fi

out_dir="${P3_RESULTS}/${CHECK}_${SLURM_JOB_ID}"
mkdir -p "${out_dir}"
matrix_log="${out_dir}/clusterkit.log"
matrix_csv="${out_dir}/matrix.csv"

n="${P3_FULL_NODES}"
ntasks=$((n * P3_GPUS_PER_NODE))

p3_log "${CHECK}: launching ClusterKit at ${n}n / ${ntasks} GPUs"
srun --nodes="${n}" \
     --ntasks="${ntasks}" \
     --ntasks-per-node="${P3_GPUS_PER_NODE}" \
     --gpus-per-task=1 \
     --output="${matrix_log}" --error="${matrix_log}" \
     "${CLUSTERKIT_BIN}" --bw --output="${matrix_csv}" \
    || { p3_emit "${CHECK}" fail reason=srun_failed log="${matrix_log}" out_dir="${out_dir}"; exit 2; }

if [[ ! -s "${matrix_csv}" ]]; then
    p3_emit "${CHECK}" fail reason=no_matrix_output out_dir="${out_dir}"
    exit 2
fi

# Same off-diagonal median/min analysis as Phase 2.4 — just at 1024 ranks.
analysis=$(awk -F, -v t="${P3_PAIR_OUTLIER_PCT}" '
    NR == 1 { ncols = NF; next }
    {
        for (j = 2; j <= NF; j++) {
            if (j - 1 == NR - 1) continue
            v = $j + 0
            if (v <= 0) continue
            vals[++k] = v
            if (v < min || min == 0) { min = v; min_i = NR - 1; min_j = j - 1 }
        }
    }
    END {
        if (k < 2) { printf "k=0\n"; exit }
        for (a = 1; a <= k; a++) for (b = a + 1; b <= k; b++) if (vals[a] > vals[b]) {
            tmp = vals[a]; vals[a] = vals[b]; vals[b] = tmp
        }
        if (k % 2) med = vals[(k + 1) / 2]
        else med = (vals[k / 2] + vals[k / 2 + 1]) / 2
        pct = (med > 0) ? (med - min) / med * 100 : 0
        printf "k=%d median=%.3f min=%.3f pct=%.3f min_i=%d min_j=%d over=%d\n",
               k, med, min, pct, min_i, min_j, (pct + 0 > t + 0) ? 1 : 0
    }
' "${matrix_csv}")

if [[ -z "${analysis}" ]] || ! echo "${analysis}" | grep -q "median="; then
    p3_emit "${CHECK}" fail reason=parse_failed out_dir="${out_dir}"
    exit 2
fi

eval "$(echo "${analysis}" | tr ' ' '\n' | sed 's/^/local_/')"

status="pass"; rc=0
if [[ "${local_over:-0}" -eq 1 ]]; then status="fail"; rc=2; fi
p3_emit "${CHECK}" "${status}" \
    median_gbs="${local_median}" min_gbs="${local_min}" pct_below_median="${local_pct}" \
    worst_pair_src="${local_min_i}" worst_pair_dst="${local_min_j}" \
    pair_count="${local_k}" threshold_pct="${P3_PAIR_OUTLIER_PCT}" \
    matrix_csv="${matrix_csv}" out_dir="${out_dir}"
exit "${rc}"
