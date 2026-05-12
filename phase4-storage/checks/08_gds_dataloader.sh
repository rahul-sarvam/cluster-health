#!/usr/bin/env bash
# 08_gds_dataloader.sh — Phase 4 test 4.8.
#
# Shell wrapper for the real PyTorch + cuFile (GDS) dataloader test.
# The actual measurement lives in dataloader.py next to this script; we
# just orchestrate per-node Python invocations under srun.
#
# Pass criterion:
#   measured_disk_tokens_per_sec / cached_ram_tokens_per_sec
#       ≥ P4_DALI_DISK_RAM_RATIO_MIN  (default 0.80)

set -u
CHECK="08_gds_dataloader"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/../slurm/env.sh"

PY_SCRIPT="${HERE}/dataloader.py"

# Skip if the python deps aren't there. We do the import check here so
# we don't print torch tracebacks across 128 nodes.
if ! "${P4_PYTHON}" -c 'import torch, numpy' >/dev/null 2>&1; then
    p4_emit "${CHECK}" "skip" reason="torch_missing"
    exit 0
fi
if ! ldconfig -p 2>/dev/null | grep -q libcufile; then
    p4_emit "${CHECK}" "skip" reason="libcufile_missing"
    exit 0
fi
if ! p4_check_storage_root; then
    p4_emit "${CHECK}" "skip" reason="storage_root_unavailable" path="${P4_STORAGE_ROOT}"
    exit 0
fi

mkdir -p "${P4_DALI_SHARD_DIR}"
shard_root="${P4_DALI_SHARD_DIR}/${SLURM_JOB_ID:-nojob}"
mkdir -p "${shard_root}"
out_dir="${P4_RESULTS}/${CHECK}_${SLURM_JOB_ID:-nojob}"
mkdir -p "${out_dir}"
log="${P4_RESULTS}/${CHECK}_${SLURM_JOB_ID:-nojob}.log"

p4_log "dataloader run: ${P4_DALI_SHARD_COUNT} shards × ${P4_DALI_BATCH_SIZE} samples"

srun --nodes="${P4_FULL_NODES}" \
     --ntasks-per-node=1 \
     --gpus-per-task=1 \
     "${P4_PYTHON}" "${PY_SCRIPT}" \
        --shard-root "${shard_root}" \
        --shard-count "${P4_DALI_SHARD_COUNT}" \
        --batch-size "${P4_DALI_BATCH_SIZE}" \
        --num-batches "${P4_DALI_NUM_BATCHES}" \
        --out-dir "${out_dir}" \
    > "${log}" 2>&1
rc=$?

# Aggregate per-host result.json. Each rank writes
# ${out_dir}/host_<nodename>.json containing keys
#   disk_tokens_per_sec, ram_tokens_per_sec
agg="$("${P4_PYTHON}" - "${out_dir}" <<'PY'
import json, os, sys, statistics
d = sys.argv[1]
disk, ram = [], []
for fn in sorted(os.listdir(d)):
    if not (fn.startswith("host_") and fn.endswith(".json")): continue
    try:
        data = json.load(open(os.path.join(d, fn)))
    except Exception:
        continue
    if "disk_tokens_per_sec" in data: disk.append(float(data["disk_tokens_per_sec"]))
    if "ram_tokens_per_sec"  in data: ram.append(float(data["ram_tokens_per_sec"]))
if not disk or not ram:
    print("null"); sys.exit(0)
print(json.dumps({
    "median_disk_tokens_per_sec": statistics.median(disk),
    "median_ram_tokens_per_sec":  statistics.median(ram),
    "min_disk_tokens_per_sec":    min(disk),
    "ratio": statistics.median(disk) / statistics.median(ram),
    "hosts_reporting": len(disk),
}))
PY
)"

if [[ "${agg}" == "null" ]]; then
    p4_emit "${CHECK}" "fail" reason="dataloader_no_results" log_path="${log}" rc="${rc}"
    rm -rf "${shard_root}" 2>/dev/null || true
    exit 2
fi

ratio="$(echo "${agg}" | "${P4_PYTHON}" -c 'import json,sys; print(json.load(sys.stdin)["ratio"])')"

verdict="pass"
if awk -v r="${ratio}" -v t="${P4_DALI_DISK_RAM_RATIO_MIN}" 'BEGIN{exit !(r < t)}'; then
    verdict="fail"
fi

p4_emit "${CHECK}" "${verdict}" \
    ratio="${ratio}" \
    ratio_min="${P4_DALI_DISK_RAM_RATIO_MIN}" \
    rollup="${agg}" \
    log_path="${log}"

# Always remove the synthetic shard directory.
rm -rf "${shard_root}" 2>/dev/null || true
exit $([[ "${verdict}" == "pass" ]] && echo 0 || echo 2)
