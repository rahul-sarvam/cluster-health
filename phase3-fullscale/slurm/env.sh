# env.sh — Phase 3 (Cross-Spine / Full-Scale)
# Sourced by every Phase 3 script. Defines paths, scales, thresholds,
# and a `p3_emit` helper for structured JSON output.
#
# All knobs are overridable via the caller's environment. The defaults
# are conservative for a 1024× B200 cluster (128 nodes × 8 GPUs);
# tune after the first real run.

set -u

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
export P3_ROOT="${P3_ROOT:-/opt/qualification/phase3}"
export P3_RESULTS="${P3_RESULTS:-${P3_ROOT}/results}"
mkdir -p "${P3_RESULTS}" "${P3_ROOT}/logs" "${P3_ROOT}/reference" 2>/dev/null || true

# Tool paths — set by bootstrap/install.sh.
export INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/qualification}"
export NCCL_TESTS_DIR="${NCCL_TESTS_DIR:-${INSTALL_PREFIX}/nccl-tests/build}"
export CLUSTERKIT_BIN="${CLUSTERKIT_BIN:-/opt/nvidia/hpc_sdk/Linux_x86_64/24.5/comm_libs/clusterkit/bin/clusterkit}"
export HPL_BIN="${HPL_BIN:-${INSTALL_PREFIX}/hpl/bin/xhpl}"
export HPL_MXP_BIN="${HPL_MXP_BIN:-${INSTALL_PREFIX}/hpl-mxp/bin/xhpl_mxp}"
export HPCG_BIN="${HPCG_BIN:-${INSTALL_PREFIX}/hpcg/bin/xhpcg}"
export LLMB_RUN="${LLMB_RUN:-llmb-run}"

# perftest binaries (apt: perftest)
export IB_WRITE_LAT="${IB_WRITE_LAT:-ib_write_lat}"
export IB_READ_LAT="${IB_READ_LAT:-ib_read_lat}"

# UFM REST endpoint. Without UFM_HOST set, check 11 emits skip cleanly.
export UFM_HOST="${UFM_HOST:-}"
export UFM_USER="${UFM_USER:-admin}"
export UFM_PASS_FILE="${UFM_PASS_FILE:-/etc/ufm.pass}"  # not in env for safety

# -----------------------------------------------------------------------------
# Scale
# -----------------------------------------------------------------------------
# Number of nodes per scale point. Phase 3 sbatch grabs the largest
# allocation up-front, then each check uses srun to subset.
export P3_GPUS_PER_NODE="${P3_GPUS_PER_NODE:-8}"
export P3_SCALE_NODES="${P3_SCALE_NODES:-32 64 128}"            # 256 / 512 / 1024 GPUs
export P3_FULL_NODES="${P3_FULL_NODES:-128}"                    # full-cluster (1024 GPUs)

# -----------------------------------------------------------------------------
# Thresholds
# -----------------------------------------------------------------------------
# 3.1 NCCL all-5 — minimum busbw at 1024 GPUs for each collective (GB/s).
export NCCL_AR_BUSBW_MIN_1024GPU_GBS="${NCCL_AR_BUSBW_MIN_1024GPU_GBS:-400}"
export NCCL_AG_BUSBW_MIN_1024GPU_GBS="${NCCL_AG_BUSBW_MIN_1024GPU_GBS:-360}"
export NCCL_RS_BUSBW_MIN_1024GPU_GBS="${NCCL_RS_BUSBW_MIN_1024GPU_GBS:-360}"
export NCCL_AA_BUSBW_MIN_1024GPU_GBS="${NCCL_AA_BUSBW_MIN_1024GPU_GBS:-300}"
export NCCL_SR_BUSBW_MIN_1024GPU_GBS="${NCCL_SR_BUSBW_MIN_1024GPU_GBS:-200}"
# 3.1 Cliff detection: 64→1024 GPU busbw shouldn't drop by more than this %.
export P3_64_TO_1024_CLIFF_PCT="${P3_64_TO_1024_CLIFF_PCT:-5}"

# 3.2 Variance: 100 back-to-back all-reduces.
export P3_VARIANCE_ITERS="${P3_VARIANCE_ITERS:-100}"
export P3_VARIANCE_STD_PCT_MAX="${P3_VARIANCE_STD_PCT_MAX:-2.0}"     # σ/μ ≤ 2%
export P3_VARIANCE_P99_P50_MAX="${P3_VARIANCE_P99_P50_MAX:-1.05}"    # p99/p50 ≤ 1.05

# 3.3 SHARP — collnet ON must be at least this much faster than OFF (%).
export P3_SHARP_MIN_GAIN_PCT="${P3_SHARP_MIN_GAIN_PCT:-15}"

# 3.4 ClusterKit fullscale pair-matrix.
export P3_PAIR_OUTLIER_PCT="${P3_PAIR_OUTLIER_PCT:-5}"

# 3.5 Adaptive Routing. AR-on should recover at least this % of uncongested BW.
export P3_AR_RECOVERY_MIN_PCT="${P3_AR_RECOVERY_MIN_PCT:-80}"

# 3.6 IB latency sweep.
export P3_IB_INTRA_LEAF_LAT_MAX_US="${P3_IB_INTRA_LEAF_LAT_MAX_US:-1.2}"
export P3_IB_CROSS_SPINE_LAT_MAX_US="${P3_IB_CROSS_SPINE_LAT_MAX_US:-1.8}"

# 3.7 FEC / pre-FEC BER. Per-port ceiling.
export P3_PRE_FEC_BER_MAX="${P3_PRE_FEC_BER_MAX:-1e-7}"
# Symbol errors / post-FEC errors at start vs end — should be 0 delta.

# 3.8/9/10 HPC. % of theoretical peak we'll accept.
export P3_HPL_FP64_PEAK_FRAC_MIN="${P3_HPL_FP64_PEAK_FRAC_MIN:-0.60}"   # ≥60% of FP64 peak
export P3_HPL_MXP_REF_DEVIATION_PCT="${P3_HPL_MXP_REF_DEVIATION_PCT:-5}" # within 5% of NV ref
export P3_HPCG_HPL_FRAC_MIN="${P3_HPCG_HPL_FRAC_MIN:-0.03}"             # ≥3% of HPL peak

# Reference numbers from NVIDIA's published B200 results — TODO_FILL after
# we know which DGX OS / NVIDIA reference release we're targeting.
export P3_HPL_MXP_REF_TFLOPS="${P3_HPL_MXP_REF_TFLOPS:-TODO_FILL}"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
p3_log() { printf '[p3 %s] %s\n' "$(date -Iseconds)" "$*" >&2; }

# p3_emit <check_name> <status> [k=v ...]
# Writes ${P3_RESULTS}/<check>_<jobid>.json.
p3_emit() {
    local check="$1" status="$2"; shift 2
    local out="${P3_RESULTS}/${check}_${SLURM_JOB_ID:-nojob}.json"
    local timestamp
    timestamp="$(date -Iseconds)"
    {
        printf '{"check":"%s","status":"%s","ts":"%s","job_id":"%s"' \
               "${check}" "${status}" "${timestamp}" "${SLURM_JOB_ID:-nojob}"
        for kv in "$@"; do
            local k="${kv%%=*}"
            local v="${kv#*=}"
            # If v already looks like a JSON value (starts with [ { " - 0-9 or t/f/n),
            # emit raw; otherwise wrap in quotes.
            case "${v}" in
                \[*|\{*|\"*|-[0-9]*|[0-9]*|true|false|null) printf ',"%s":%s' "${k}" "${v}" ;;
                *)                                          printf ',"%s":"%s"' "${k}" "${v}" ;;
            esac
        done
        printf '}\n'
    } > "${out}"
    p3_log "wrote ${out} (${status})"
}

# Whether the current Slurm allocation is full-scale.
p3_have_full_scale() {
    [[ "${SLURM_NNODES:-0}" -ge "${P3_FULL_NODES}" ]]
}

# Lookup the busbw target for a given GPU count (for the all-5 sweep).
# Falls back to the 1024-GPU number for anything not explicitly listed.
p3_busbw_target_for_collective() {
    local collective="$1" gpus="$2"
    # We only define minimums at 1024 GPUs; smaller scales are sanity-checked
    # by Phase 2. So at < 1024, target = 0 (any positive number passes).
    if [[ "${gpus}" -lt 1024 ]]; then echo 0; return; fi
    case "${collective}" in
        all_reduce)    echo "${NCCL_AR_BUSBW_MIN_1024GPU_GBS}" ;;
        all_gather)    echo "${NCCL_AG_BUSBW_MIN_1024GPU_GBS}" ;;
        reduce_scatter) echo "${NCCL_RS_BUSBW_MIN_1024GPU_GBS}" ;;
        alltoall)      echo "${NCCL_AA_BUSBW_MIN_1024GPU_GBS}" ;;
        sendrecv)      echo "${NCCL_SR_BUSBW_MIN_1024GPU_GBS}" ;;
        *)             echo 0 ;;
    esac
}
