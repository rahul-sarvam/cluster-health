#!/usr/bin/env bash
# 04_elbencho_gds.sh — Phase 4 test 4.4.
#
# GPUDirect Storage (GDS) path bandwidth. Uses elbencho's `--gds` mode
# to read into device memory through cuFile, bypassing the CPU bounce.
#
# Pass criterion:
#   measured_gbs / line_rate_gbs ≥ P4_ELBENCHO_LINE_RATE_FRAC_MIN  (default 0.90)
# where line_rate_gbs is the configured per-NIC line rate (4x NDR ≈ 46 GB/s).

set -u
CHECK="04_elbencho_gds"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/../slurm/env.sh"

if [[ ! -x "${ELBENCHO_BIN}" ]] && ! command -v "${ELBENCHO_BIN}" >/dev/null 2>&1; then
    p4_emit "${CHECK}" "skip" reason="elbencho_missing" elbencho_bin="${ELBENCHO_BIN}"
    exit 0
fi
if ! p4_check_storage_root; then
    p4_emit "${CHECK}" "skip" reason="storage_root_unavailable" path="${P4_STORAGE_ROOT}"
    exit 0
fi

# GDS requires the cufile.so library to be present on every node.
if ! ldconfig -p 2>/dev/null | grep -q libcufile; then
    p4_emit "${CHECK}" "skip" reason="libcufile_missing"
    exit 0
fi

mkdir -p "${P4_ELBENCHO_DIR}"
work_dir="${P4_ELBENCHO_DIR}/${SLURM_JOB_ID:-nojob}"
mkdir -p "${work_dir}"
log="${P4_RESULTS}/${CHECK}_${SLURM_JOB_ID:-nojob}.log"

# elbencho knobs:
#   --gds                    : read via cuFile into GPU device memory
#   --gpuids 0-7             : one GPU per rank (8 ranks per node)
#   -t ${THREADS}            : threads per rank
#   --blocksize ${block}     : I/O size
#   --size ${size}           : per-thread file size
#   -w / -r                  : write phase, read phase
#   --hosts                  : the host list (Slurm gives it to us)
p4_log "running elbencho+GDS across ${P4_FULL_NODES} nodes under ${work_dir}"

# We don't drive elbencho via its built-in multi-host launcher because
# we already have an srun-shaped allocation. Instead, each rank runs a
# single-process elbencho bound to its GPU, on its own subdirectory.
srun --nodes="${P4_FULL_NODES}" \
     --ntasks-per-node="${P4_GPUS_PER_NODE}" \
     --kill-on-bad-exit=1 \
     bash -c '
        set -e
        sub="'"${work_dir}"'/n${SLURM_NODEID}_g${SLURM_LOCALID}"
        mkdir -p "$sub"
        gpu="${SLURM_LOCALID}"
        "'"${ELBENCHO_BIN}"'" --gds --gpuids "${gpu}" \
            -t 1 --blocksize "'"${P4_ELBENCHO_BLOCK_SIZE}"'" \
            --size "'"${P4_ELBENCHO_FILE_SIZE_GB}"'g" \
            -w -r --direct \
            --csvfile "'"${P4_RESULTS}/${CHECK}_${SLURM_JOB_ID:-nojob}"'/rank_${SLURM_NODEID}_${SLURM_LOCALID}.csv" \
            --no-svcelapsed \
            "$sub" >> "'"${log}"'" 2>&1
     '
rc=$?

# Per-rank CSV: each rank emits one row with read MB/s in a known column.
# Rather than guess column indices across elbencho versions, scan the log
# for the "READ" summary line:
#   ENTRIES   bytes/s   ...
read_mibs="$(awk '
    BEGIN{best=0}
    /READ/ && /MB\/s/ {
        for (i=1; i<=NF; i++)
            if ($i ~ /^[0-9.]+$/ && $i+0 > best) best = $i+0
    }
    END{ if (best > 0) print best }
' "${log}")"

if [[ -z "${read_mibs}" ]]; then
    p4_emit "${CHECK}" "fail" reason="elbencho_output_unparseable" log="${log}" rc="${rc}"
    exit 2
fi

# Aggregate across ranks: each rank reported its own MB/s; sum gives
# aggregate. Per-NIC normalisation = aggregate / (nodes * nics_per_node).
# We assume 8 NICs per node (one per GPU), which is the standard B200 BOM.
nics_total=$((P4_FULL_NODES * P4_GPUS_PER_NODE))
per_nic_gbs="$(awk -v m="${read_mibs}" -v n="${nics_total}" \
    'BEGIN{printf "%.2f", (m*1.048576/1000)/n}')"

frac="$(awk -v p="${per_nic_gbs}" -v line="${P4_ELBENCHO_LINE_RATE_GBS}" \
    'BEGIN{printf "%.3f", p/line}')"

verdict="pass"
if awk -v f="${frac}" -v t="${P4_ELBENCHO_LINE_RATE_FRAC_MIN}" 'BEGIN{exit !(f < t)}'; then
    verdict="fail"
fi

p4_emit "${CHECK}" "${verdict}" \
    nics="${nics_total}" \
    per_nic_gbs="${per_nic_gbs}" \
    line_rate_gbs="${P4_ELBENCHO_LINE_RATE_GBS}" \
    fraction_of_line_rate="${frac}" \
    fraction_of_line_rate_min="${P4_ELBENCHO_LINE_RATE_FRAC_MIN}" \
    log_path="${log}"

if [[ "${verdict}" == "pass" ]]; then
    rm -rf "${work_dir}" 2>/dev/null || true
fi
exit $([[ "${verdict}" == "pass" ]] && echo 0 || echo 2)
