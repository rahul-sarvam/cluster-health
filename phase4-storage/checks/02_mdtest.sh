#!/usr/bin/env bash
# 02_mdtest.sh — Phase 4 test 4.2.
#
# Metadata create/stat/open throughput at 1024 ranks against the global
# namespace.
#
# Pass criterion:
#   global_creates_per_sec ≥ P4_MDTEST_CREATES_PER_SEC_MIN

set -u
CHECK="02_mdtest"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/../slurm/env.sh"

if ! command -v "${MDTEST_BIN}" >/dev/null 2>&1 && [[ ! -x "${MDTEST_BIN}" ]]; then
    p4_emit "${CHECK}" "skip" reason="mdtest_missing" mdtest_bin="${MDTEST_BIN}"
    exit 0
fi
if ! p4_check_storage_root; then
    p4_emit "${CHECK}" "skip" reason="storage_root_unavailable" path="${P4_STORAGE_ROOT}"
    exit 0
fi

mkdir -p "${P4_MDTEST_DIR}"
work_dir="${P4_MDTEST_DIR}/${SLURM_JOB_ID:-nojob}"
mkdir -p "${work_dir}"
log="${P4_RESULTS}/${CHECK}_${SLURM_JOB_ID:-nojob}.log"

# mdtest knobs:
#   -n ${N}         : N files per task
#   -z ${depth}     : directory tree depth
#   -b ${branch}    : items per tree node
#   -F              : files only (no directories)
#   -u              : unique working directory per task
#   -d ${dir}       : working dir
p4_log "running mdtest at ${P4_FULL_RANKS} ranks under ${work_dir}"
srun --nodes="${P4_FULL_NODES}" \
     --ntasks-per-node="${P4_GPUS_PER_NODE}" \
     --kill-on-bad-exit=1 \
     "${MDTEST_BIN}" \
        -n "${P4_MDTEST_FILES_PER_RANK}" \
        -z "${P4_MDTEST_DEPTH}" \
        -b "${P4_MDTEST_ITEMS_PER_TREE_NODE}" \
        -F -u \
        -d "${work_dir}" \
        -i 1 \
    > "${log}" 2>&1
rc=$?

# mdtest summary table (one row per operation). Looks like:
#   SUMMARY rate: (of 1 iterations)
#      Operation                  Max            Min           Mean        Std Dev
#      ---------                  ---            ---           ----        -------
#      File creation     :     217845.123      ...
#      File stat         :     ...
#      File read         :     ...
#      File removal      :     ...
creates_per_sec="$(awk '
    /File creation/ {
        # column 4 is Max rate in ops/sec
        gsub(",", "", $4); print $4; exit
    }' "${log}")"

if [[ -z "${creates_per_sec}" ]]; then
    p4_emit "${CHECK}" "fail" reason="mdtest_output_unparseable" log="${log}" rc="${rc}"
    exit 2
fi

verdict="pass"
if awk -v c="${creates_per_sec}" -v t="${P4_MDTEST_CREATES_PER_SEC_MIN}" \
       'BEGIN{exit !(c < t)}'; then
    verdict="fail"
fi

p4_emit "${CHECK}" "${verdict}" \
    ranks="${P4_FULL_RANKS}" \
    creates_per_sec="${creates_per_sec}" \
    creates_per_sec_min="${P4_MDTEST_CREATES_PER_SEC_MIN}" \
    files_per_rank="${P4_MDTEST_FILES_PER_RANK}" \
    log_path="${log}"

if [[ "${verdict}" == "pass" ]]; then
    rm -rf "${work_dir}" 2>/dev/null || true
fi
exit $([[ "${verdict}" == "pass" ]] && echo 0 || echo 2)
