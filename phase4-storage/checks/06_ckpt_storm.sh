#!/usr/bin/env bash
# 06_ckpt_storm.sh — Phase 4 test 4.6.
#
# Simultaneous checkpoint write storm. All 1024 GPUs write their own
# DeepSeek-V3-sized shard to a shared directory under wall-clock
# pressure. The pass criterion is a sustained aggregate bandwidth
# floor and an end-to-end deadline.
#
# Pass criterion:
#   agg_gbs           ≥ P4_CKPT_AGG_GBS_MIN  (default 22 GB/s)
#   wall_elapsed_sec  ≤ P4_CKPT_DEADLINE_SEC (default 60 s)
#
# This is a synthetic stand-in for "torch.save(state_dict, path)" —
# fully sequential, O_DIRECT-free, fsync-at-end, mirroring how
# training frameworks actually persist shards.

set -u
CHECK="06_ckpt_storm"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/../slurm/env.sh"

if ! p4_check_storage_root; then
    p4_emit "${CHECK}" "skip" reason="storage_root_unavailable" path="${P4_STORAGE_ROOT}"
    exit 0
fi

mkdir -p "${P4_CKPT_DIR}"
work_dir="${P4_CKPT_DIR}/${SLURM_JOB_ID:-nojob}"
mkdir -p "${work_dir}"
log="${P4_RESULTS}/${CHECK}_${SLURM_JOB_ID:-nojob}.log"

# We need an int byte count and an even multiple of 1 MiB to keep dd
# happy. Shard size knob is a float in GB; convert to MiB count.
shard_mib="$(awk -v gb="${P4_CKPT_SHARD_SIZE_GB}" \
    'BEGIN{ printf "%d", gb * 1024 }')"

p4_log "checkpoint storm: ${P4_FULL_RANKS} ranks × ${shard_mib} MiB into ${work_dir}"

# Capture wall-clock start time on the launcher, before srun begins,
# so we measure end-to-end including any srun stragglers.
start_ns="$(date +%s%N)"

srun --nodes="${P4_FULL_NODES}" \
     --ntasks-per-node="${P4_GPUS_PER_NODE}" \
     --kill-on-bad-exit=1 \
     bash -c '
        set -e
        f="'"${work_dir}"'/shard_${SLURM_NODEID}_${SLURM_LOCALID}.bin"
        # Synthetic shard write: 1 MiB blocks, conv=fdatasync so the
        # entire shard is on stable storage before dd exits. This is
        # what torch.save -> os.fsync emits in aggregate.
        dd if=/dev/zero of="$f" bs=1M count='"${shard_mib}"' \
           conv=fdatasync status=none
     ' >> "${log}" 2>&1
rc=$?

end_ns="$(date +%s%N)"
elapsed_sec="$(awk -v s="${start_ns}" -v e="${end_ns}" \
    'BEGIN{ printf "%.3f", (e-s)/1e9 }')"

if [[ "${rc}" -ne 0 ]]; then
    p4_emit "${CHECK}" "fail" reason="srun_dd_failed" rc="${rc}" \
        elapsed_sec="${elapsed_sec}" log_path="${log}"
    exit 2
fi

# Aggregate bytes: ranks * shard_mib * 1 MiB
total_gib="$(awk -v r="${P4_FULL_RANKS}" -v m="${shard_mib}" \
    'BEGIN{ printf "%.3f", (r * m) / 1024 }')"
agg_gbs="$(awk -v gib="${total_gib}" -v sec="${elapsed_sec}" \
    'BEGIN{ if (sec<=0) {print "nan"; exit} printf "%.2f", (gib * 1.073741824) / sec }')"

verdict="pass"
if awk -v g="${agg_gbs}" -v t="${P4_CKPT_AGG_GBS_MIN}" 'BEGIN{exit !(g < t)}'; then
    verdict="fail"
fi
if awk -v e="${elapsed_sec}" -v d="${P4_CKPT_DEADLINE_SEC}" 'BEGIN{exit !(e > d)}'; then
    verdict="fail"
fi

p4_emit "${CHECK}" "${verdict}" \
    ranks="${P4_FULL_RANKS}" \
    shard_size_gb="${P4_CKPT_SHARD_SIZE_GB}" \
    total_gib="${total_gib}" \
    elapsed_sec="${elapsed_sec}" \
    deadline_sec="${P4_CKPT_DEADLINE_SEC}" \
    agg_gbs="${agg_gbs}" \
    agg_gbs_min="${P4_CKPT_AGG_GBS_MIN}" \
    log_path="${log}"

# Always clean up the shard files — they're large and synthetic.
rm -rf "${work_dir}" 2>/dev/null || true
exit $([[ "${verdict}" == "pass" ]] && echo 0 || echo 2)
