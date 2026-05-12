#!/usr/bin/env bash
# 04_clusterkit_intra.sh — Test 2.4
# ClusterKit pair-matrix at intra-rack scope (8 nodes, 64 GPUs).
# Produces an N×N bandwidth matrix between every pair of ranks; we then
# look for any pair that is materially below the median pair. The point
# is to catch one bad rail/leaf-port that the all-reduce in 2.1 can hide
# in the average.
#
# ClusterKit ships with the NVIDIA HPC SDK. If the binary isn't present
# we emit a `skip` rather than failing, since it's optional tooling.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../slurm/env.sh
source "${SCRIPT_DIR}/../slurm/env.sh"

CHECK="04_clusterkit_intra"

if [[ ! -x "${CLUSTERKIT_BIN}" ]]; then
    p2_emit "${CHECK}" skip reason=clusterkit_not_installed path="${CLUSTERKIT_BIN}"
    exit 0
fi

ALLOC_NODES="${SLURM_NNODES:-0}"
if [[ "${ALLOC_NODES}" -lt 8 ]]; then
    p2_emit "${CHECK}" fail reason=allocation_too_small allocated="${ALLOC_NODES}" required=8
    exit 1
fi

out_dir="${P2_RESULTS}/${CHECK}_${SLURM_JOB_ID}"
mkdir -p "${out_dir}"
matrix_log="${out_dir}/clusterkit.log"

n=8
ntasks=$((n * P2_GPUS_PER_NODE))

p2_log "${CHECK}: launching ClusterKit pair matrix at ${n} nodes / ${ntasks} GPUs"

# ClusterKit's standard invocation: one task per GPU, --bw to measure
# pairwise bandwidth (GB/s), --output writes the matrix to disk.
srun --nodes="${n}" \
     --ntasks="${ntasks}" \
     --ntasks-per-node="${P2_GPUS_PER_NODE}" \
     --gpus-per-task=1 \
     --output="${matrix_log}" \
     --error="${matrix_log}" \
     "${CLUSTERKIT_BIN}" --bw --output="${out_dir}/matrix.csv" \
    || {
        p2_emit "${CHECK}" fail reason=srun_failed log="${matrix_log}" out_dir="${out_dir}"
        exit 2
    }

if [[ ! -s "${out_dir}/matrix.csv" ]]; then
    p2_emit "${CHECK}" fail reason=no_matrix_output log="${matrix_log}" out_dir="${out_dir}"
    exit 2
fi

# Analyze the matrix in awk: ignore diagonal (self pair), find median and
# min over the off-diagonal pairs, compute pct-below-median for the worst.
# ClusterKit's CSV layout: first row = column headers (rank IDs), first
# column = row headers (rank IDs), each interior cell = GB/s.
analysis=$(awk -F, -v t="${P2_PAIR_OUTLIER_PCT}" '
    NR == 1 { ncols = NF; next }
    {
        for (j = 2; j <= NF; j++) {
            if (j - 1 == NR - 1) continue   # skip diagonal
            v = $j + 0
            if (v <= 0) continue
            vals[++k] = v
            if (v < min || min == 0) { min = v; min_i = NR - 1; min_j = j - 1 }
        }
    }
    END {
        if (k < 2) {
            printf "k=0\n"
            exit
        }
        # sort vals
        for (a = 1; a <= k; a++) for (b = a + 1; b <= k; b++) if (vals[a] > vals[b]) {
            tmp = vals[a]; vals[a] = vals[b]; vals[b] = tmp
        }
        if (k % 2) med = vals[(k + 1) / 2]
        else med = (vals[k / 2] + vals[k / 2 + 1]) / 2
        pct = (med > 0) ? (med - min) / med * 100 : 0
        printf "k=%d median=%.3f min=%.3f pct=%.3f min_i=%d min_j=%d over=%d\n", \
               k, med, min, pct, min_i, min_j, (pct + 0 > t + 0) ? 1 : 0
    }
' "${out_dir}/matrix.csv")

if [[ -z "${analysis}" ]] || ! echo "${analysis}" | grep -q "median="; then
    p2_emit "${CHECK}" fail reason=parse_failed log="${matrix_log}" out_dir="${out_dir}"
    exit 2
fi

# Pull fields out of the awk output line.
eval "$(echo "${analysis}" | tr ' ' '\n' | sed 's/^/local_/')"

if [[ "${local_over:-0}" -eq 1 ]]; then
    p2_emit "${CHECK}" fail \
        median_gbs="${local_median}" min_gbs="${local_min}" \
        pct_below_median="${local_pct}" \
        worst_pair_src="${local_min_i}" worst_pair_dst="${local_min_j}" \
        pair_count="${local_k}" \
        threshold_pct="${P2_PAIR_OUTLIER_PCT}" \
        matrix_csv="${out_dir}/matrix.csv" \
        log="${matrix_log}" out_dir="${out_dir}"
    exit 2
fi

p2_emit "${CHECK}" pass \
    median_gbs="${local_median}" min_gbs="${local_min}" \
    pct_below_median="${local_pct}" \
    worst_pair_src="${local_min_i}" worst_pair_dst="${local_min_j}" \
    pair_count="${local_k}" \
    threshold_pct="${P2_PAIR_OUTLIER_PCT}" \
    matrix_csv="${out_dir}/matrix.csv" \
    log="${matrix_log}" out_dir="${out_dir}"
