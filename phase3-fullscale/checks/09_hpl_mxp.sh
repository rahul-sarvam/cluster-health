#!/usr/bin/env bash
# 09_hpl_mxp.sh — Test 3.9
# Mixed-precision HPL (HPL-MxP, formerly HPL-AI). Pass if result is within
# P3_HPL_MXP_REF_DEVIATION_PCT of NVIDIA's published B200 reference at
# the same node count. The reference number lives in env.sh as
# P3_HPL_MXP_REF_TFLOPS — that's a TODO_FILL placeholder until the
# operator pins it to a specific NVIDIA reference release.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../slurm/env.sh
source "${SCRIPT_DIR}/../slurm/env.sh"

CHECK="09_hpl_mxp"

if [[ ! -x "${HPL_MXP_BIN}" ]]; then
    p3_emit "${CHECK}" fail reason=missing_binary path="${HPL_MXP_BIN}" \
        hint="ships with NVIDIA HPC Benchmarks container"
    exit 1
fi

HPL_MXP_DAT="${HPL_MXP_DAT:-${INSTALL_PREFIX}/hpl-mxp/HPL-MxP.dat}"
if [[ ! -f "${HPL_MXP_DAT}" ]]; then
    p3_emit "${CHECK}" fail reason=missing_dat path="${HPL_MXP_DAT}"
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
log_file="${out_dir}/hpl_mxp.log"

work_dir="${out_dir}/work"
mkdir -p "${work_dir}"
cp "${HPL_MXP_DAT}" "${work_dir}/HPL-MxP.dat"

p3_log "${CHECK}: launching HPL-MxP on ${n}n / ${ntasks} GPUs"

( cd "${work_dir}" && \
    srun --nodes="${n}" \
         --ntasks="${ntasks}" \
         --ntasks-per-node="${P3_GPUS_PER_NODE}" \
         --gpus-per-task=1 \
         --output="${log_file}" --error="${log_file}" \
         "${HPL_MXP_BIN}" ) \
    || { p3_emit "${CHECK}" fail reason=srun_failed log="${log_file}" out_dir="${out_dir}"; exit 2; }

# HPL-MxP output: similar table to HPL, last column is Gflops.
gflops=$(awk '/^WR[A-Z0-9]+ +[0-9]+ / {g=$NF} END {print g}' "${log_file}")
if [[ -z "${gflops}" ]]; then
    p3_emit "${CHECK}" fail reason=parse_failed log="${log_file}" out_dir="${out_dir}"
    exit 2
fi
tflops=$(awk -v g="${gflops}" 'BEGIN{printf "%.3f", g/1000}')

if [[ "${P3_HPL_MXP_REF_TFLOPS}" == "TODO_FILL" ]]; then
    # No reference yet — emit warn so we still see the number.
    p3_emit "${CHECK}" warn reason=no_reference_pinned \
        measured_tflops="${tflops}" log="${log_file}" out_dir="${out_dir}" \
        hint="Set P3_HPL_MXP_REF_TFLOPS once a target NVIDIA reference release is chosen."
    exit 0
fi

deviation_pct=$(awk -v m="${tflops}" -v r="${P3_HPL_MXP_REF_TFLOPS}" \
    'BEGIN{ if (r+0<=0) print 0; else printf "%.3f", (m-r)/r*100 }')
abs_dev=$(awk -v d="${deviation_pct}" 'BEGIN{print (d+0<0)?-d:d}')
over=$(awk -v a="${abs_dev}" -v t="${P3_HPL_MXP_REF_DEVIATION_PCT}" 'BEGIN{print (a+0>t+0)?"1":"0"}')

status="pass"; rc=0
if [[ "${over}" -eq 1 ]]; then status="fail"; rc=2; fi
p3_emit "${CHECK}" "${status}" \
    measured_tflops="${tflops}" reference_tflops="${P3_HPL_MXP_REF_TFLOPS}" \
    deviation_pct="${deviation_pct}" threshold_pct="${P3_HPL_MXP_REF_DEVIATION_PCT}" \
    log="${log_file}" out_dir="${out_dir}"
exit "${rc}"
