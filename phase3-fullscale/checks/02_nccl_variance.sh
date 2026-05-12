#!/usr/bin/env bash
# 02_nccl_variance.sh — Test 3.2
# 100 back-to-back full-cluster all_reduces. Captures the stability of
# the fabric under repeated stress. A wide distribution implies adaptive
# routing instability, congestion, or a flapping link.
#
# Pass criteria (defaults):
#   - σ/μ ≤ P3_VARIANCE_STD_PCT_MAX (2%)
#   - p99/p50 ≤ P3_VARIANCE_P99_P50_MAX (1.05)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../slurm/env.sh
source "${SCRIPT_DIR}/../slurm/env.sh"

CHECK="02_nccl_variance"
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
iters="${P3_VARIANCE_ITERS}"
samples_file="${out_dir}/samples.txt"
: > "${samples_file}"

p3_log "${CHECK}: running ${iters} all-reduce iterations at ${n}n / ${ntasks} GPUs"

# We run one srun per iteration so the result distribution captures full
# init+collective+teardown variance. -n 1 -w 1 keeps each run short
# (~seconds). All iterations write to the same shared log directory.
for i in $(seq 1 "${iters}"); do
    log="${out_dir}/iter_${i}.log"
    srun --nodes="${n}" \
         --ntasks="${ntasks}" \
         --ntasks-per-node="${P3_GPUS_PER_NODE}" \
         --gpus-per-task=1 \
         --output="${log}" --error="${log}" \
         "${ALL_REDUCE_BIN}" -b 1G -e 1G -g 1 -c 1 -n 1 -w 1 \
        || { echo "srun_failed" >> "${samples_file}"; continue; }
    busbw=$(awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/ {b=$(NF-1)} END {print b}' "${log}")
    if [[ -n "${busbw}" ]]; then echo "${busbw}" >> "${samples_file}"
    else                          echo "parse_failed" >> "${samples_file}"
    fi
done

# Compute μ, σ, p50, p99 in awk over the numeric samples only.
stats=$(awk '
    /^[0-9.]+$/ { v=$1+0; samples[++n]=v; sum+=v }
    END {
        if (n < 10) { printf "n=%d\n", n; exit }
        mean = sum / n
        var = 0
        for (i = 1; i <= n; i++) var += (samples[i] - mean) ^ 2
        std = sqrt(var / n)
        # sort
        for (a = 1; a <= n; a++) for (b = a + 1; b <= n; b++) if (samples[a] > samples[b]) {
            t = samples[a]; samples[a] = samples[b]; samples[b] = t
        }
        p50 = samples[int((n + 1) * 0.50)]
        p99 = samples[int((n + 1) * 0.99)]
        printf "n=%d mean=%.4f std=%.4f std_pct=%.4f p50=%.4f p99=%.4f p99_p50=%.4f\n",
               n, mean, std, (mean > 0 ? std / mean * 100 : 0), p50, p99,
               (p50 > 0 ? p99 / p50 : 0)
    }
' "${samples_file}")

if ! echo "${stats}" | grep -q "mean="; then
    p3_emit "${CHECK}" fail reason=too_few_samples samples_file="${samples_file}"
    exit 2
fi

# Parse stats line into local_* vars.
eval "$(echo "${stats}" | tr ' ' '\n' | sed 's/^/local_/')"

over_std=$(awk -v a="${local_std_pct}" -v t="${P3_VARIANCE_STD_PCT_MAX}" 'BEGIN{print (a+0>t+0)?"1":"0"}')
over_p99=$(awk -v a="${local_p99_p50}" -v t="${P3_VARIANCE_P99_P50_MAX}" 'BEGIN{print (a+0>t+0)?"1":"0"}')

if [[ "${over_std}" -eq 1 ]] || [[ "${over_p99}" -eq 1 ]]; then
    p3_emit "${CHECK}" fail \
        iterations="${local_n}" mean_gbs="${local_mean}" std_gbs="${local_std}" \
        std_pct="${local_std_pct}" p50_gbs="${local_p50}" p99_gbs="${local_p99}" \
        p99_p50_ratio="${local_p99_p50}" \
        threshold_std_pct="${P3_VARIANCE_STD_PCT_MAX}" \
        threshold_p99_p50="${P3_VARIANCE_P99_P50_MAX}" \
        samples_file="${samples_file}" out_dir="${out_dir}"
    exit 2
fi

p3_emit "${CHECK}" pass \
    iterations="${local_n}" mean_gbs="${local_mean}" std_gbs="${local_std}" \
    std_pct="${local_std_pct}" p50_gbs="${local_p50}" p99_gbs="${local_p99}" \
    p99_p50_ratio="${local_p99_p50}" \
    threshold_std_pct="${P3_VARIANCE_STD_PCT_MAX}" \
    threshold_p99_p50="${P3_VARIANCE_P99_P50_MAX}" \
    samples_file="${samples_file}" out_dir="${out_dir}"
