#!/usr/bin/env bash
# 05_mlperf_storage.sh — Phase 4 test 4.5.
#
# Realistic dataloader I/O via MLPerf Storage. The benchmark drives
# Unet3D / ResNet50 / CosmoFlow synthetic accelerator workers that
# request samples from the storage backend at the rate a real GPU
# would. We compare measured samples/sec against the model's published
# reference number for the same accelerator count.
#
# Pass criterion:
#   |measured - reference| / reference  ≤  P4_MLPERF_DEVIATION_PCT  (default 10%)
#
# If the reference is TODO_FILL we emit `warn` to capture the number.

set -u
CHECK="05_mlperf_storage"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/../slurm/env.sh"

if ! command -v "${MLPERF_STORAGE_BIN}" >/dev/null 2>&1; then
    p4_emit "${CHECK}" "skip" reason="mlperf_storage_missing"
    exit 0
fi
if ! p4_check_storage_root; then
    p4_emit "${CHECK}" "skip" reason="storage_root_unavailable" path="${P4_STORAGE_ROOT}"
    exit 0
fi

mkdir -p "${P4_MLPERF_DIR}"
work_dir="${P4_MLPERF_DIR}/${SLURM_JOB_ID:-nojob}"
mkdir -p "${work_dir}"
log="${P4_RESULTS}/${CHECK}_${SLURM_JOB_ID:-nojob}.log"

p4_log "running mlperf_storage ${P4_MLPERF_MODEL} (n=${P4_MLPERF_NUM_ACCEL}) under ${work_dir}"

# mlperf_storage's launcher takes care of spawning the rank emulators
# across hosts; we wrap it in a single srun --nodes=1 --ntasks=1 because
# the binary itself is the orchestrator.
srun --nodes=1 --ntasks=1 --gpus-per-task=0 \
     "${MLPERF_STORAGE_BIN}" run \
        --workload "${P4_MLPERF_MODEL}" \
        --num-accelerators "${P4_MLPERF_NUM_ACCEL}" \
        --accelerator-type "${P4_MLPERF_ACCEL_TYPE}" \
        --storage-root "${work_dir}" \
        --hostfile <(scontrol show hostnames "${SLURM_NODELIST}") \
        --results-dir "${P4_RESULTS}/${CHECK}_${SLURM_JOB_ID:-nojob}_data" \
    > "${log}" 2>&1
rc=$?

# MLPerf Storage prints a summary block of the form:
#   train_au_meanstdev  90.45  0.21
#   train_throughput_samples_per_second  1842.7
samples_per_sec="$(awk '/^train_throughput_samples_per_second/ {print $2; exit}' "${log}")"

if [[ -z "${samples_per_sec}" ]]; then
    p4_emit "${CHECK}" "fail" reason="mlperf_output_unparseable" log="${log}" rc="${rc}"
    exit 2
fi

if [[ "${P4_MLPERF_REF_SAMPLES_PER_SEC}" == "TODO_FILL" ]]; then
    p4_emit "${CHECK}" "warn" \
        reason="reference_not_set" \
        measured_samples_per_sec="${samples_per_sec}" \
        model="${P4_MLPERF_MODEL}" \
        num_accelerators="${P4_MLPERF_NUM_ACCEL}" \
        log_path="${log}"
    exit 0
fi

dev_pct="$(awk -v m="${samples_per_sec}" -v r="${P4_MLPERF_REF_SAMPLES_PER_SEC}" \
    'BEGIN{ if (r==0) {print "nan"; exit} printf "%.2f", (m-r)/r*100 }')"

verdict="pass"
abs_dev="${dev_pct#-}"
if awk -v d="${abs_dev}" -v t="${P4_MLPERF_DEVIATION_PCT}" 'BEGIN{exit !(d > t)}'; then
    verdict="fail"
fi

p4_emit "${CHECK}" "${verdict}" \
    model="${P4_MLPERF_MODEL}" \
    num_accelerators="${P4_MLPERF_NUM_ACCEL}" \
    measured_samples_per_sec="${samples_per_sec}" \
    reference_samples_per_sec="${P4_MLPERF_REF_SAMPLES_PER_SEC}" \
    deviation_pct="${dev_pct}" \
    deviation_pct_max="${P4_MLPERF_DEVIATION_PCT}" \
    log_path="${log}"

if [[ "${verdict}" == "pass" ]]; then
    rm -rf "${work_dir}" 2>/dev/null || true
fi
exit $([[ "${verdict}" == "pass" ]] && echo 0 || echo 2)
