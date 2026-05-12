#!/usr/bin/env bash
# 07_noisy_neighbor.sh — Phase 4 test 4.7.
#
# Tail-latency amplification: 512 ranks run a sustained random read
# workload (the "dataloader") while the other 512 ranks run the
# checkpoint storm pattern. We compare the P99 read latency under
# concurrent storm against the same workload's P99 in isolation.
#
# Pass criterion:
#   p99_under_storm / p99_baseline  ≤  P4_NN_TAIL_AMPLIFICATION_MAX  (default 2.0)
#
# Run order:
#   1) baseline:  reader half ONLY, no writer side
#   2) under load: reader half + writer half concurrently
# Both runs share the same file-set on storage.

set -u
CHECK="07_noisy_neighbor"
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

if [[ "${P4_FULL_NODES}" -lt 2 ]]; then
    p4_emit "${CHECK}" "skip" reason="too_few_nodes_for_split" nodes="${P4_FULL_NODES}"
    exit 0
fi

read_nodes=$((P4_FULL_NODES / 2))
write_nodes=$((P4_FULL_NODES - read_nodes))

work_dir="${P4_STORAGE_ROOT}/phase4/noisy_neighbor/${SLURM_JOB_ID:-nojob}"
mkdir -p "${work_dir}/reads" "${work_dir}/writes"
out_dir="${P4_RESULTS}/${CHECK}_${SLURM_JOB_ID:-nojob}"
mkdir -p "${out_dir}/baseline" "${out_dir}/under_load"
log="${P4_RESULTS}/${CHECK}_${SLURM_JOB_ID:-nojob}.log"

# The reader job: pure random reads at moderate queue depth. It is the
# "dataloader" half — what training would feel under noisy-neighbour
# pressure. We export FIO JSON per rank for P99 rollup.
read_fio() {
    local pass="$1"  # "baseline" | "under_load"
    srun --nodes="${read_nodes}" \
         --ntasks-per-node="${P4_GPUS_PER_NODE}" \
         --kill-on-bad-exit=0 \
         bash -c '
            set -e
            f="'"${work_dir}/reads"'/read_${SLURM_NODEID}_${SLURM_LOCALID}.dat"
            j="'"${out_dir}/'"${pass}"'"'"/rank_${SLURM_NODEID}_${SLURM_LOCALID}.json"
            "'"${FIO_BIN}"'" --name=ddread --ioengine=libaio --direct=1 \
                --rw=randread --bs=4k --iodepth=8 \
                --runtime=60 --time_based=1 \
                --size='"${P4_NN_READ_FILE_SIZE}"' --filename="$f" \
                --output-format=json --output="$j" \
                --group_reporting \
                > /dev/null
         ' 2>&1
}

# The writer job: synthetic checkpoint storm pattern, lower priority,
# longer than the reader so the reader sees sustained pressure.
write_pressure() {
    srun --nodes="${write_nodes}" \
         --ntasks-per-node="${P4_GPUS_PER_NODE}" \
         --kill-on-bad-exit=0 \
         bash -c '
            f="'"${work_dir}/writes"'/w_${SLURM_NODEID}_${SLURM_LOCALID}.bin"
            # Loop dd writes for 75s so it outlives the 60s reader run.
            end=$(( $(date +%s) + 75 ))
            while [[ $(date +%s) -lt $end ]]; do
                dd if=/dev/zero of="$f" bs=1M count=512 conv=fdatasync status=none
            done
         ' 2>&1
}

p4_log "noisy-neighbor: baseline pass (readers only)"
read_fio baseline >> "${log}" 2>&1

p4_log "noisy-neighbor: under-load pass (readers + write storm)"
write_pressure >> "${log}" 2>&1 &
write_pid=$!
read_fio under_load >> "${log}" 2>&1
# Best-effort kill the writer if it outlasted the reader.
kill -9 "${write_pid}" 2>/dev/null || true
wait 2>/dev/null || true

# Roll up P99 across all read ranks for each pass.
rollup() {
    local pass="$1"
    python3 - "${out_dir}/${pass}" <<'PY'
import json, os, statistics, sys
d = sys.argv[1]
p99s = []
for fn in sorted(os.listdir(d)):
    if not fn.endswith(".json"): continue
    try:
        data = json.load(open(os.path.join(d, fn)))
    except Exception:
        continue
    for j in data.get("jobs", []):
        clat = j.get("read", {}).get("clat_ns", {}).get("percentile", {}) or {}
        for k in ("99.000000", "99.0", "99"):
            if k in clat:
                p99s.append(float(clat[k]) / 1000.0)   # ns -> us
                break
if not p99s:
    print("null")
else:
    print(json.dumps({
        "median_p99_us": statistics.median(p99s),
        "max_p99_us": max(p99s),
        "ranks": len(p99s),
    }))
PY
}

base_json="$(rollup baseline)"
load_json="$(rollup under_load)"

if [[ "${base_json}" == "null" || "${load_json}" == "null" ]]; then
    p4_emit "${CHECK}" "fail" reason="rollup_missing" log_path="${log}"
    rm -rf "${work_dir}" 2>/dev/null || true
    exit 2
fi

base_p99="$(echo "${base_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["max_p99_us"])')"
load_p99="$(echo "${load_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["max_p99_us"])')"
ratio="$(awk -v b="${base_p99}" -v l="${load_p99}" \
    'BEGIN{ if (b<=0) {print "nan"; exit} printf "%.3f", l/b }')"

verdict="pass"
if awk -v r="${ratio}" -v t="${P4_NN_TAIL_AMPLIFICATION_MAX}" 'BEGIN{exit !(r > t)}'; then
    verdict="fail"
fi

p4_emit "${CHECK}" "${verdict}" \
    read_nodes="${read_nodes}" \
    write_nodes="${write_nodes}" \
    baseline_p99_us="${base_p99}" \
    under_load_p99_us="${load_p99}" \
    amplification_ratio="${ratio}" \
    amplification_max="${P4_NN_TAIL_AMPLIFICATION_MAX}" \
    log_path="${log}" \
    baseline_rollup="${base_json}" \
    under_load_rollup="${load_json}"

rm -rf "${work_dir}" 2>/dev/null || true
exit $([[ "${verdict}" == "pass" ]] && echo 0 || echo 2)
