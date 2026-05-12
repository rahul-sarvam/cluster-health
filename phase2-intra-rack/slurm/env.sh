#!/usr/bin/env bash
# Shared environment for Phase 2 intra-rack scale tests.
# Source this from every check script and from the sbatch wrapper.
#
# Phase 2 runs ONE Slurm job across a single rack (typically --nodes=8),
# inside which the six checks execute sequentially. Failing the gate at
# this scale means a single rack/leaf-switch has a problem; we want to
# catch it before spending hours on full-cluster work in Phase 3.

set -u

# -----------------------------------------------------------------------------
# Paths (mirror the convention from phase1-qualification and phase0)
# -----------------------------------------------------------------------------
export P2_ROOT="${P2_ROOT:-/opt/qualification/phase2}"
export P2_RESULTS="${P2_RESULTS:-${P2_ROOT}/results}"
export P2_LOGS="${P2_LOGS:-${P2_ROOT}/logs}"
mkdir -p "${P2_RESULTS}" "${P2_LOGS}"

# Tool binary locations (these match bootstrap/install.sh INSTALL_PREFIX).
export NCCL_TESTS_DIR="${NCCL_TESTS_DIR:-/opt/qualification/nccl-tests/build}"
export OSU_DIR="${OSU_DIR:-/opt/qualification/osu/libexec/osu-micro-benchmarks/mpi/collective}"
export CLUSTERKIT_BIN="${CLUSTERKIT_BIN:-/opt/nvidia/hpc_sdk/Linux_x86_64/24.5/comm_libs/clusterkit/bin/clusterkit}"

# Reference topology for check 2.6. Captured once on a known-good run.
export P2_REF_TOPO="${P2_REF_TOPO:-/opt/qualification/phase2/reference/nccl_topo_ref.xml}"

# -----------------------------------------------------------------------------
# Scale & rack assumptions
# -----------------------------------------------------------------------------
# Intra-rack scale points. 1, 2, 4, 8 nodes => 8, 16, 32, 64 GPUs.
export P2_SCALE_NODES="${P2_SCALE_NODES:-1 2 4 8}"
export P2_GPUS_PER_NODE="${P2_GPUS_PER_NODE:-8}"
# Number of rails (HCAs) per node. Used by the rail-isolated check.
export P2_RAIL_COUNT="${P2_RAIL_COUNT:-8}"
# IB HCA device prefix; rail N -> ${P2_IB_HCA_PREFIX}${N}.
export P2_IB_HCA_PREFIX="${P2_IB_HCA_PREFIX:-mlx5_}"

# -----------------------------------------------------------------------------
# Pass/fail thresholds (GB/s = gigabytes/sec; Gb/s = gigabits/sec)
# -----------------------------------------------------------------------------
# busbw target at the largest message size (8 GiB), per scale point.
# Cross-spine fan-out drags busbw down at >1 node compared to intra-node.
export NCCL_AR_BUSBW_MIN_8GPU_GBS=380         # 1 node, same as Phase 1
export NCCL_AR_BUSBW_MIN_16GPU_GBS=350        # 2 nodes
export NCCL_AR_BUSBW_MIN_32GPU_GBS=330        # 4 nodes
export NCCL_AR_BUSBW_MIN_64GPU_GBS=320        # 8 nodes (full rack)

# Small-message latency ceiling (in us) at 8 B, for full-rack scale.
export NCCL_AR_LATENCY_MAX_8B_US=15

# Rail outlier: any single rail more than this % below the median of rails fails.
export P2_RAIL_OUTLIER_PCT=1.0

# ClusterKit pair matrix: any (src,dst) more than this % below the median pair fails.
export P2_PAIR_OUTLIER_PCT=5.0

# OSU vs NCCL agreement: OSU's allreduce/alltoall must be within this % of NCCL.
export P2_OSU_NCCL_AGREEMENT_PCT=3.0

# Monotonicity: when moving up the message-size sweep, busbw should never
# drop by more than this % between adjacent points (within one scale).
export P2_MONOTONICITY_DROP_PCT=5.0

# -----------------------------------------------------------------------------
# NCCL runtime tuning. Keep these vanilla for acceptance; we want the
# default-config behaviour, not a tuned one.
# -----------------------------------------------------------------------------
export NCCL_DEBUG="${NCCL_DEBUG:-WARN}"
export NCCL_DEBUG_SUBSYS="${NCCL_DEBUG_SUBSYS:-INIT,NET}"
# Let NCCL discover topology from the system; do NOT pre-set NCCL_TOPO_FILE.
# Test 2.6 captures the discovered topology.

# -----------------------------------------------------------------------------
# JSON emit helper (mirrors qual_emit / p0_emit)
# Usage: p2_emit <check> <status: pass|fail|warn|skip> <key=value> [...]
# -----------------------------------------------------------------------------
p2_emit() {
    local check="$1"; shift
    local status="$1"; shift
    local jobid="${SLURM_JOB_ID:-local}"
    local out="${P2_RESULTS}/${check}_${jobid}.json"
    {
        printf '{"check":"%s","status":"%s","job_id":"%s","ts":"%s"' \
            "${check}" "${status}" "${jobid}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        for kv in "$@"; do
            local k="${kv%%=*}"
            local v="${kv#*=}"
            if [[ "${v}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || [[ "${v}" =~ ^(true|false|null|\[|\{) ]]; then
                printf ',"%s":%s' "${k}" "${v}"
            else
                printf ',"%s":"%s"' "${k}" "${v}"
            fi
        done
        printf '}\n'
    } > "${out}"
}

p2_log() {
    echo "[$(date -u +%H:%M:%S)] [${SLURMD_NODENAME:-local}] $*" \
        | tee -a "${P2_LOGS}/phase2_${SLURM_JOB_ID:-local}.log"
}

# Resolve threshold given a scale (in nodes).
p2_busbw_target_for_scale() {
    local n="$1"
    case "${n}" in
        1) echo "${NCCL_AR_BUSBW_MIN_8GPU_GBS}" ;;
        2) echo "${NCCL_AR_BUSBW_MIN_16GPU_GBS}" ;;
        4) echo "${NCCL_AR_BUSBW_MIN_32GPU_GBS}" ;;
        8) echo "${NCCL_AR_BUSBW_MIN_64GPU_GBS}" ;;
        *) echo "0" ;;
    esac
}

# Pretty rail device name from index.
p2_rail_dev() {
    local i="$1"
    echo "${P2_IB_HCA_PREFIX}${i}"
}
