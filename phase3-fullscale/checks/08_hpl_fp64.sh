#!/usr/bin/env bash
# 08_hpl_fp64.sh — Test 3.8
# NVIDIA HPL FP64 at full cluster. Acceptance: ≥P3_HPL_FP64_PEAK_FRAC_MIN
# of theoretical FP64 peak. For B200, FP64 peak is ~37 TFLOPS per GPU
# Tensor-Core-FP64; 1024 GPUs = ~37,888 TFLOPS theoretical.
#
# HPL.dat must already exist at ${INSTALL_PREFIX}/hpl/HPL.dat — bootstrap
# installs a sample but operators usually tune it for their N (problem
# size) and P×Q (process grid). We honour whatever is already there.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../slurm/env.sh
source "${SCRIPT_DIR}/../slurm/env.sh"

CHECK="08_hpl_fp64"

if [[ ! -x "${HPL_BIN}" ]]; then
    p3_emit "${CHECK}" fail reason=missing_binary path="${HPL_BIN}" \
        hint="Install via NVIDIA HPC Benchmarks container or build from NVIDIA HPL source"
    exit 1
fi

HPL_DAT="${HPL_DAT:-${INSTALL_PREFIX}/hpl/HPL.dat}"
if [[ ! -f "${HPL_DAT}" ]]; then
    p3_emit "${CHECK}" fail reason=missing_hpl_dat path="${HPL_DAT}"
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
log_file="${out_dir}/hpl.log"

# Peak from B200 spec: 37 TF FP64 Tensor Core per GPU. Overridable.
peak_per_gpu_tflops="${P3_FP64_PEAK_PER_GPU_TFLOPS:-37}"
peak_total_tflops=$(awk -v p="${peak_per_gpu_tflops}" -v g="${ntasks}" 'BEGIN{printf "%.3f", p*g}')

p3_log "${CHECK}: launching HPL on ${n}n / ${ntasks} GPUs; theoretical peak ${peak_total_tflops} TFLOPS"

# HPL expects its working directory to contain HPL.dat. We stage it.
work_dir="${out_dir}/work"
mkdir -p "${work_dir}"
cp "${HPL_DAT}" "${work_dir}/HPL.dat"

( cd "${work_dir}" && \
    srun --nodes="${n}" \
         --ntasks="${ntasks}" \
         --ntasks-per-node="${P3_GPUS_PER_NODE}" \
         --gpus-per-task=1 \
         --output="${log_file}" --error="${log_file}" \
         "${HPL_BIN}" ) \
    || { p3_emit "${CHECK}" fail reason=srun_failed log="${log_file}" out_dir="${out_dir}"; exit 2; }

# HPL output format (the line we want):
#   ============================================================================
#   T/V                N    NB     P     Q               Time                 Gflops
#   ----------------------------------------------------------------------------
#   WR03L2L4      <N>    <NB> <P>   <Q>          <time>          <gflops>
gflops=$(awk '/^WR[A-Z0-9]+ +[0-9]+ / {g=$NF} END {print g}' "${log_file}")

if [[ -z "${gflops}" ]]; then
    p3_emit "${CHECK}" fail reason=parse_failed log="${log_file}" out_dir="${out_dir}"
    exit 2
fi

tflops=$(awk -v g="${gflops}" 'BEGIN{printf "%.3f", g/1000}')
frac=$(awk -v t="${tflops}" -v p="${peak_total_tflops}" 'BEGIN{ if (p+0<=0) print 0; else printf "%.4f", t/p }')

under=$(awk -v f="${frac}" -v t="${P3_HPL_FP64_PEAK_FRAC_MIN}" 'BEGIN{print (f+0<t+0)?"1":"0"}')

status="pass"; rc=0
if [[ "${under}" -eq 1 ]]; then status="fail"; rc=2; fi
p3_emit "${CHECK}" "${status}" \
    hpl_tflops="${tflops}" peak_tflops="${peak_total_tflops}" \
    peak_fraction="${frac}" threshold_fraction="${P3_HPL_FP64_PEAK_FRAC_MIN}" \
    log="${log_file}" out_dir="${out_dir}"
exit "${rc}"
