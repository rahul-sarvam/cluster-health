#!/usr/bin/env bash
# 10_hpcg.sh — Test 3.10
# HPCG at full cluster. The memory-bandwidth-bound counterpart to HPL.
# Acceptance: HPCG ≥ P3_HPCG_HPL_FRAC_MIN of measured HPL performance.
# If HPL (check 08) didn't run or failed to produce a number, we fall
# back to comparing against the theoretical FP64 peak fraction.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../slurm/env.sh
source "${SCRIPT_DIR}/../slurm/env.sh"

CHECK="10_hpcg"

if [[ ! -x "${HPCG_BIN}" ]]; then
    p3_emit "${CHECK}" fail reason=missing_binary path="${HPCG_BIN}" \
        hint="ships with NVIDIA HPC Benchmarks container"
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
log_file="${out_dir}/hpcg.log"

# HPCG.dat lives next to the binary by convention.
HPCG_DAT="${HPCG_DAT:-${INSTALL_PREFIX}/hpcg/hpcg.dat}"
work_dir="${out_dir}/work"
mkdir -p "${work_dir}"
[[ -f "${HPCG_DAT}" ]] && cp "${HPCG_DAT}" "${work_dir}/hpcg.dat"

p3_log "${CHECK}: launching HPCG on ${n}n / ${ntasks} GPUs"

( cd "${work_dir}" && \
    srun --nodes="${n}" \
         --ntasks="${ntasks}" \
         --ntasks-per-node="${P3_GPUS_PER_NODE}" \
         --gpus-per-task=1 \
         --output="${log_file}" --error="${log_file}" \
         "${HPCG_BIN}" ) \
    || { p3_emit "${CHECK}" fail reason=srun_failed log="${log_file}" out_dir="${out_dir}"; exit 2; }

# HPCG prints "Final Summary::HPCG result is VALID with a GFLOP/s rating of=<value>"
hpcg_gflops=$(awk -F'=' '/HPCG result is VALID/ {gsub(/[^0-9.]/,"",$NF); print $NF}' "${log_file}")
if [[ -z "${hpcg_gflops}" ]]; then
    # Fall back to the older field name.
    hpcg_gflops=$(awk '/Final Summary::HPCG/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9.]+$/) v=$i} END{print v}' "${log_file}")
fi

if [[ -z "${hpcg_gflops}" ]]; then
    p3_emit "${CHECK}" fail reason=parse_failed log="${log_file}" out_dir="${out_dir}"
    exit 2
fi
hpcg_tflops=$(awk -v g="${hpcg_gflops}" 'BEGIN{printf "%.4f", g/1000}')

# Compare against HPL result if available.
hpl_json="${P3_RESULTS}/08_hpl_fp64_${SLURM_JOB_ID}.json"
hpl_tflops=""
if [[ -f "${hpl_json}" ]]; then
    hpl_tflops=$(awk -F'"hpl_tflops":' 'NF>1 {sub(/^[ ]*"?/,"",$2); sub(/[",}].*$/,"",$2); print $2; exit}' "${hpl_json}")
fi

if [[ -n "${hpl_tflops}" ]] && awk -v h="${hpl_tflops}" 'BEGIN{exit !(h+0>0)}'; then
    frac=$(awk -v c="${hpcg_tflops}" -v h="${hpl_tflops}" 'BEGIN{printf "%.4f", c/h}')
    ref_label="hpl_tflops"; ref_value="${hpl_tflops}"
else
    # Fall back to theoretical FP64 peak.
    peak_per_gpu_tflops="${P3_FP64_PEAK_PER_GPU_TFLOPS:-37}"
    peak_total_tflops=$(awk -v p="${peak_per_gpu_tflops}" -v g="${ntasks}" 'BEGIN{printf "%.3f", p*g}')
    frac=$(awk -v c="${hpcg_tflops}" -v p="${peak_total_tflops}" 'BEGIN{printf "%.4f", c/p}')
    ref_label="peak_fp64_tflops"; ref_value="${peak_total_tflops}"
fi

under=$(awk -v f="${frac}" -v t="${P3_HPCG_HPL_FRAC_MIN}" 'BEGIN{print (f+0<t+0)?"1":"0"}')
status="pass"; rc=0
if [[ "${under}" -eq 1 ]]; then status="fail"; rc=2; fi
p3_emit "${CHECK}" "${status}" \
    hpcg_tflops="${hpcg_tflops}" reference_label="${ref_label}" reference_value="${ref_value}" \
    fraction="${frac}" threshold_fraction="${P3_HPCG_HPL_FRAC_MIN}" \
    log="${log_file}" out_dir="${out_dir}"
exit "${rc}"
