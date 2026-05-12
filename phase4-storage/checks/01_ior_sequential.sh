#!/usr/bin/env bash
# 01_ior_sequential.sh — Phase 4 test 4.1.
#
# Aggregate sequential read + write bandwidth at 1024 clients, using
# IOR's POSIX backend on the shared parallel filesystem.
#
# Pass criterion:
#   read_gbs  ≥ P4_IOR_READ_GBS_MIN
#   write_gbs ≥ P4_IOR_WRITE_GBS_MIN
#
# Emits results/01_ior_sequential_<jobid>.json.

set -u
CHECK="01_ior_sequential"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/../slurm/env.sh"

if ! command -v "${IOR_BIN}" >/dev/null 2>&1 && [[ ! -x "${IOR_BIN}" ]]; then
    p4_emit "${CHECK}" "skip" reason="ior_missing" ior_bin="${IOR_BIN}"
    exit 0
fi
if ! p4_check_storage_root; then
    p4_emit "${CHECK}" "skip" reason="storage_root_unavailable" path="${P4_STORAGE_ROOT}"
    exit 0
fi

mkdir -p "${P4_IOR_DIR}"
work_dir="${P4_IOR_DIR}/${SLURM_JOB_ID:-nojob}"
mkdir -p "${work_dir}"

log="${P4_RESULTS}/${CHECK}_${SLURM_JOB_ID:-nojob}.log"
p4_log "running IOR sequential at ${P4_FULL_RANKS} ranks under ${work_dir}"

# IOR knobs:
#   -a POSIX        : POSIX backend (most compatible across PFS)
#   -b ${block}     : per-process block size
#   -t ${xfer}      : transfer (I/O call) size
#   -s ${segs}      : segments per process (larger => longer-running, less peakiness)
#   -F              : file-per-process (avoids single-file-locking pathologies)
#   -e -k           : fsync at end, keep files for read pass
#   -i 1            : one iteration
#   -w -r           : write phase, then read phase
#   -o ${out}       : output file template
srun --nodes="${P4_FULL_NODES}" \
     --ntasks-per-node="${P4_GPUS_PER_NODE}" \
     --kill-on-bad-exit=1 \
     "${IOR_BIN}" \
        -a POSIX \
        -b "${P4_IOR_BLOCK_SIZE}" \
        -t "${P4_IOR_TRANSFER_SIZE}" \
        -s "${P4_IOR_SEGMENTS}" \
        -F -e -k -i 1 -w -r \
        -o "${work_dir}/iorfile" \
    > "${log}" 2>&1
rc=$?

# IOR summary block looks like:
#   access     bw(MiB/s)  IOPS       Latency(s)  block(KiB)  xfer(KiB)  open(s) ...
#   ------     ---------  ----       ----------  ----------  ---------  -------
#   write      102345.67   ...
#   read       204567.89   ...
read_mibs="$(awk '/^read[[:space:]]/{print $2; exit}' "${log}")"
write_mibs="$(awk '/^write[[:space:]]/{print $2; exit}' "${log}")"

if [[ -z "${read_mibs}" || -z "${write_mibs}" ]]; then
    p4_emit "${CHECK}" "fail" reason="ior_output_unparseable" log="${log}" rc="${rc}"
    exit 2
fi

# MiB/s → GB/s (decimal). 1 MiB = 1.048576 MB.
read_gbs="$(awk -v m="${read_mibs}" 'BEGIN{printf "%.2f", m*1.048576/1000}')"
write_gbs="$(awk -v m="${write_mibs}" 'BEGIN{printf "%.2f", m*1.048576/1000}')"

verdict="pass"
if awk -v r="${read_gbs}" -v t="${P4_IOR_READ_GBS_MIN}" 'BEGIN{exit !(r < t)}'; then
    verdict="fail"
fi
if awk -v w="${write_gbs}" -v t="${P4_IOR_WRITE_GBS_MIN}" 'BEGIN{exit !(w < t)}'; then
    verdict="fail"
fi

p4_emit "${CHECK}" "${verdict}" \
    ranks="${P4_FULL_RANKS}" \
    read_gbs="${read_gbs}" \
    write_gbs="${write_gbs}" \
    read_gbs_min="${P4_IOR_READ_GBS_MIN}" \
    write_gbs_min="${P4_IOR_WRITE_GBS_MIN}" \
    log_path="${log}"

# Keep iorfile* around on failure; clean on pass.
if [[ "${verdict}" == "pass" ]]; then
    rm -rf "${work_dir}" 2>/dev/null || true
fi
exit $([[ "${verdict}" == "pass" ]] && echo 0 || echo 2)
