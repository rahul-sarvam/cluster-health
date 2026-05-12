#!/usr/bin/env bash
# 03_fio_mixed.sh — Phase 4 test 4.3.
#
# Per-client random IOPS + low-queue-depth latency. Runs an FIO randrw
# job per node (8 jobs per node, one per GPU rail / CPU complex), then
# rolls up min/median/max IOPS and worst-rank P99 latency.
#
# Pass criterion:
#   min per-client IOPS ≥ P4_FIO_IOPS_MIN
#   worst rank P99 lat  ≤ P4_FIO_P99_LAT_US_MAX

set -u
CHECK="03_fio_mixed"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/../slurm/env.sh"

if ! command -v "${FIO_BIN}" >/dev/null 2>&1; then
    p4_emit "${CHECK}" "skip" reason="fio_missing"
    exit 0
fi
if ! p4_check_storage_root; then
    p4_emit "${CHECK}" "skip" reason="storage_root_unavailable" path="${P4_STORAGE_ROOT}"
    exit 0
fi

mkdir -p "${P4_FIO_DIR}"
work_dir="${P4_FIO_DIR}/${SLURM_JOB_ID:-nojob}"
mkdir -p "${work_dir}"
out_dir="${P4_RESULTS}/${CHECK}_${SLURM_JOB_ID:-nojob}"
mkdir -p "${out_dir}"

# Run one FIO worker per (node, gpu-slot) — 8 per node. Each writes
# its own file_${SLURM_NODEID}_${SLURM_LOCALID} into the shared dir,
# then exports a JSON summary to ${out_dir}/.
p4_log "running fio randrw at ${P4_FULL_RANKS} clients under ${work_dir}"
srun --nodes="${P4_FULL_NODES}" \
     --ntasks-per-node="${P4_GPUS_PER_NODE}" \
     --kill-on-bad-exit=1 \
     bash -c '
        set -e
        f="'"${work_dir}"'/fio_${SLURM_NODEID}_${SLURM_LOCALID}.dat"
        j="'"${out_dir}"'/rank_${SLURM_NODEID}_${SLURM_LOCALID}.json"
        "'"${FIO_BIN}"'" --name=randrw --ioengine=libaio --direct=1 \
            --rw=randrw --rwmixread=70 --bs=4k --iodepth=8 \
            --runtime='"${P4_FIO_RUNTIME_SEC}"' --time_based=1 \
            --size='"${P4_FIO_FILE_SIZE}"' --filename="$f" \
            --output-format=json --output="$j" \
            --group_reporting \
            > /dev/null
     ' 2>&1 | tee "${P4_RESULTS}/${CHECK}_${SLURM_JOB_ID:-nojob}.log" >/dev/null
rc=$?

# Roll up: walk every rank_*.json, pull read iops + clat p99 (in ns),
# and compute min / median / max IOPS plus the worst rank P99.
agg="$(python3 - "${out_dir}" <<'PY'
import json, os, statistics, sys
results_dir = sys.argv[1]
iops_list, p99_us_list = [], []
ranks = 0
for fn in sorted(os.listdir(results_dir)):
    if not fn.startswith("rank_") or not fn.endswith(".json"):
        continue
    try:
        d = json.load(open(os.path.join(results_dir, fn)))
    except (OSError, json.JSONDecodeError):
        continue
    for j in d.get("jobs", []):
        r = j.get("read", {}) or {}
        # FIO emits iops as a number; clat_ns as {percentile:{"99.000000": ns}}
        if "iops" in r:
            iops_list.append(float(r["iops"]))
        p = r.get("clat_ns", {}).get("percentile", {}) or {}
        # Pick the closest 99.x key.
        for k in ("99.000000", "99.0", "99"):
            if k in p:
                p99_us_list.append(float(p[k]) / 1000.0)  # ns -> us
                break
    ranks += 1
out = {
    "ranks_reporting": ranks,
    "min_iops": min(iops_list) if iops_list else None,
    "median_iops": statistics.median(iops_list) if iops_list else None,
    "max_iops": max(iops_list) if iops_list else None,
    "worst_p99_us": max(p99_us_list) if p99_us_list else None,
    "median_p99_us": statistics.median(p99_us_list) if p99_us_list else None,
}
print(json.dumps(out))
PY
)"

if [[ -z "${agg}" ]] || ! echo "${agg}" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    p4_emit "${CHECK}" "fail" reason="rollup_failed" out_dir="${out_dir}" rc="${rc}"
    exit 2
fi

min_iops="$(echo "${agg}"   | python3 -c 'import json,sys; print(json.load(sys.stdin)["min_iops"])')"
worst_p99="$(echo "${agg}"  | python3 -c 'import json,sys; print(json.load(sys.stdin)["worst_p99_us"])')"
ranks_rep="$(echo "${agg}"  | python3 -c 'import json,sys; print(json.load(sys.stdin)["ranks_reporting"])')"

verdict="pass"
if [[ "${min_iops}" == "None" ]] || \
   awk -v v="${min_iops}" -v t="${P4_FIO_IOPS_MIN}" 'BEGIN{exit !(v < t)}'; then
    verdict="fail"
fi
if [[ "${worst_p99}" == "None" ]] || \
   awk -v v="${worst_p99}" -v t="${P4_FIO_P99_LAT_US_MAX}" 'BEGIN{exit !(v > t)}'; then
    verdict="fail"
fi

p4_emit "${CHECK}" "${verdict}" \
    ranks="${ranks_rep}" \
    min_iops="${min_iops}" \
    worst_p99_us="${worst_p99}" \
    iops_min_target="${P4_FIO_IOPS_MIN}" \
    p99_us_max_target="${P4_FIO_P99_LAT_US_MAX}" \
    rollup="${agg}"

if [[ "${verdict}" == "pass" ]]; then
    rm -rf "${work_dir}" 2>/dev/null || true
fi
exit $([[ "${verdict}" == "pass" ]] && echo 0 || echo 2)
