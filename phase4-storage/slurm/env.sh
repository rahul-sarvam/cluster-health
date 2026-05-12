# env.sh — Phase 4 (Storage Scale)
# Sourced by every Phase 4 script. Defines paths, the storage backend
# under test, scale knobs, per-test thresholds, and a `p4_emit` helper
# that mirrors p2_emit / p3_emit.
#
# Storage assumption:
#   ${P4_STORAGE_ROOT} points at a shared parallel filesystem mounted
#   on every compute node (e.g. /mnt/lustre, /mnt/weka, /mnt/vast).
#   Phase 4 writes test data under ${P4_STORAGE_ROOT}/phase4/<test>/.
#   Operator MUST set this knob — there is no safe default.

set -u

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
export P4_ROOT="${P4_ROOT:-/opt/qualification/phase4}"
export P4_RESULTS="${P4_RESULTS:-${P4_ROOT}/results}"
mkdir -p "${P4_RESULTS}" "${P4_ROOT}/logs" "${P4_ROOT}/reference" 2>/dev/null || true

# Shared parallel filesystem under test. MUST be set by the operator.
export P4_STORAGE_ROOT="${P4_STORAGE_ROOT:-/mnt/scratch}"

# Per-test scratch subdirectories. Each check cleans up its own subdir on
# success; on failure we leave the directory in place for forensics.
export P4_IOR_DIR="${P4_IOR_DIR:-${P4_STORAGE_ROOT}/phase4/ior}"
export P4_MDTEST_DIR="${P4_MDTEST_DIR:-${P4_STORAGE_ROOT}/phase4/mdtest}"
export P4_FIO_DIR="${P4_FIO_DIR:-${P4_STORAGE_ROOT}/phase4/fio}"
export P4_ELBENCHO_DIR="${P4_ELBENCHO_DIR:-${P4_STORAGE_ROOT}/phase4/elbencho}"
export P4_MLPERF_DIR="${P4_MLPERF_DIR:-${P4_STORAGE_ROOT}/phase4/mlperf}"
export P4_CKPT_DIR="${P4_CKPT_DIR:-${P4_STORAGE_ROOT}/phase4/ckpt}"
export P4_DALI_SHARD_DIR="${P4_DALI_SHARD_DIR:-${P4_STORAGE_ROOT}/phase4/shards}"

# Tool paths — these are vendor-supplied (apt or upstream tarball).
# bootstrap/install.sh phase4 verifies / installs them.
export INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/qualification}"
export IOR_BIN="${IOR_BIN:-${INSTALL_PREFIX}/ior/bin/ior}"
export MDTEST_BIN="${MDTEST_BIN:-${INSTALL_PREFIX}/ior/bin/mdtest}"
export FIO_BIN="${FIO_BIN:-fio}"
export ELBENCHO_BIN="${ELBENCHO_BIN:-${INSTALL_PREFIX}/bin/elbencho}"
export MLPERF_STORAGE_BIN="${MLPERF_STORAGE_BIN:-mlperf_storage}"

# Python interpreter for the GDS dataloader test (4.8). The script needs
# torch + nvidia-dali + cufile. We don't pin a venv here — bootstrap
# verifies that `import torch, nvidia.dali` succeeds.
export P4_PYTHON="${P4_PYTHON:-python3}"

# -----------------------------------------------------------------------------
# Scale
# -----------------------------------------------------------------------------
export P4_GPUS_PER_NODE="${P4_GPUS_PER_NODE:-8}"
export P4_FULL_NODES="${P4_FULL_NODES:-128}"
export P4_FULL_RANKS="${P4_FULL_RANKS:-$((P4_FULL_NODES * P4_GPUS_PER_NODE))}"   # 1024

# -----------------------------------------------------------------------------
# Thresholds (P0 acceptance numbers from CLUSTER_HEALTH_REFERENCE §8).
# All knobs overridable from the operator's environment.
# -----------------------------------------------------------------------------

# 4.1 IOR sequential. Aggregate read / write GB/s minimums. Vendor-spec
# defaults are placeholders — fill in once the storage vendor publishes
# their sustained number for the 128-OST / 1024-client config.
export P4_IOR_READ_GBS_MIN="${P4_IOR_READ_GBS_MIN:-200}"
export P4_IOR_WRITE_GBS_MIN="${P4_IOR_WRITE_GBS_MIN:-100}"
export P4_IOR_BLOCK_SIZE="${P4_IOR_BLOCK_SIZE:-1g}"           # per-process block
export P4_IOR_TRANSFER_SIZE="${P4_IOR_TRANSFER_SIZE:-1m}"
export P4_IOR_SEGMENTS="${P4_IOR_SEGMENTS:-4}"

# 4.2 mdtest. Global namespace create rate.
export P4_MDTEST_CREATES_PER_SEC_MIN="${P4_MDTEST_CREATES_PER_SEC_MIN:-200000}"
export P4_MDTEST_FILES_PER_RANK="${P4_MDTEST_FILES_PER_RANK:-1024}"
export P4_MDTEST_DEPTH="${P4_MDTEST_DEPTH:-3}"
export P4_MDTEST_ITEMS_PER_TREE_NODE="${P4_MDTEST_ITEMS_PER_TREE_NODE:-100}"

# 4.3 FIO. Per-client IOPS + tail latency.
export P4_FIO_IOPS_MIN="${P4_FIO_IOPS_MIN:-50000}"
export P4_FIO_P99_LAT_US_MAX="${P4_FIO_P99_LAT_US_MAX:-1000}"     # 1 ms
export P4_FIO_RUNTIME_SEC="${P4_FIO_RUNTIME_SEC:-120}"
export P4_FIO_FILE_SIZE="${P4_FIO_FILE_SIZE:-8g}"

# 4.4 Elbencho + GDS. % of per-NIC line rate the GDS path must reach.
# 4x NDR ports per node ≈ 400 Gb/s per port nominal — line-rate per NIC.
export P4_ELBENCHO_LINE_RATE_FRAC_MIN="${P4_ELBENCHO_LINE_RATE_FRAC_MIN:-0.90}"
export P4_ELBENCHO_LINE_RATE_GBS="${P4_ELBENCHO_LINE_RATE_GBS:-46}"    # 4x NDR = ~46 GB/s
export P4_ELBENCHO_BLOCK_SIZE="${P4_ELBENCHO_BLOCK_SIZE:-1m}"
export P4_ELBENCHO_FILE_SIZE_GB="${P4_ELBENCHO_FILE_SIZE_GB:-64}"

# 4.5 MLPerf Storage. Reference numbers from MLCommons; defaults TODO_FILL.
export P4_MLPERF_MODEL="${P4_MLPERF_MODEL:-unet3d}"
export P4_MLPERF_ACCEL_TYPE="${P4_MLPERF_ACCEL_TYPE:-h100}"   # closest published profile
export P4_MLPERF_NUM_ACCEL="${P4_MLPERF_NUM_ACCEL:-1024}"
export P4_MLPERF_REF_SAMPLES_PER_SEC="${P4_MLPERF_REF_SAMPLES_PER_SEC:-TODO_FILL}"
export P4_MLPERF_DEVIATION_PCT="${P4_MLPERF_DEVIATION_PCT:-10}"

# 4.6 Checkpoint storm. 1024 GPUs simultaneously write one shard each.
export P4_CKPT_SHARD_SIZE_GB="${P4_CKPT_SHARD_SIZE_GB:-1.3}"     # ≈ DeepSeek-V3 sized
export P4_CKPT_AGG_GBS_MIN="${P4_CKPT_AGG_GBS_MIN:-22}"
export P4_CKPT_DEADLINE_SEC="${P4_CKPT_DEADLINE_SEC:-60}"

# 4.7 Noisy neighbour. Read-tail amplification ratio under storm load.
export P4_NN_TAIL_AMPLIFICATION_MAX="${P4_NN_TAIL_AMPLIFICATION_MAX:-2.0}"
export P4_NN_READ_FILE_SIZE="${P4_NN_READ_FILE_SIZE:-2g}"

# 4.8 GDS PyTorch dataloader. Disk-vs-RAM throughput ratio.
export P4_DALI_DISK_RAM_RATIO_MIN="${P4_DALI_DISK_RAM_RATIO_MIN:-0.80}"
export P4_DALI_SHARD_COUNT="${P4_DALI_SHARD_COUNT:-256}"
export P4_DALI_BATCH_SIZE="${P4_DALI_BATCH_SIZE:-32}"
export P4_DALI_NUM_BATCHES="${P4_DALI_NUM_BATCHES:-200}"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
p4_log() { printf '[p4 %s] %s\n' "$(date -Iseconds)" "$*" >&2; }

# p4_emit <check> <status> [k=v ...]   →   ${P4_RESULTS}/<check>_<jobid>.json
# Identical encoding to p3_emit so the aggregator-shaped tests carry over.
p4_emit() {
    local check="$1" status="$2"; shift 2
    local out="${P4_RESULTS}/${check}_${SLURM_JOB_ID:-nojob}.json"
    local timestamp
    timestamp="$(date -Iseconds)"
    {
        printf '{"check":"%s","status":"%s","ts":"%s","job_id":"%s"' \
               "${check}" "${status}" "${timestamp}" "${SLURM_JOB_ID:-nojob}"
        for kv in "$@"; do
            local k="${kv%%=*}"
            local v="${kv#*=}"
            case "${v}" in
                \[*|\{*|\"*|-[0-9]*|[0-9]*|true|false|null) printf ',"%s":%s' "${k}" "${v}" ;;
                *)                                          printf ',"%s":"%s"' "${k}" "${v}" ;;
            esac
        done
        printf '}\n'
    } > "${out}"
    p4_log "wrote ${out} (${status})"
}

# Sanity-check the shared storage root before any check tries to use it.
# Returns 0 if mounted + writable, 1 otherwise.
p4_check_storage_root() {
    if [[ ! -d "${P4_STORAGE_ROOT}" ]]; then
        p4_log "storage root ${P4_STORAGE_ROOT} not present"
        return 1
    fi
    local probe="${P4_STORAGE_ROOT}/.p4_write_probe_$$"
    if ! ( : > "${probe}" ) 2>/dev/null; then
        p4_log "storage root ${P4_STORAGE_ROOT} not writable"
        return 1
    fi
    rm -f "${probe}"
    return 0
}
