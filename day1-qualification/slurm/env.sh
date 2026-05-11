#!/usr/bin/env bash
# Shared environment for the Day-1 per-node qualification gate.
# Source this from every check script and from run_node.sh.

set -u

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
export QUAL_ROOT="${QUAL_ROOT:-/opt/qualification/day1}"
export QUAL_RESULTS="${QUAL_RESULTS:-${QUAL_ROOT}/results}"
export QUAL_LOGS="${QUAL_LOGS:-${QUAL_ROOT}/logs}"
mkdir -p "${QUAL_RESULTS}" "${QUAL_LOGS}"

# Tool binary locations. TODO: pin to absolute paths once cluster is imaged.
export NVBANDWIDTH_BIN="${NVBANDWIDTH_BIN:-/usr/local/bin/nvbandwidth}"
export GPU_BURN_DIR="${GPU_BURN_DIR:-/opt/gpu-burn}"
export NCCL_TESTS_DIR="${NCCL_TESTS_DIR:-/opt/nccl-tests/build}"
export BABELSTREAM_BIN="${BABELSTREAM_BIN:-/opt/babelstream/cuda-stream}"
export PERFTEST_DIR="${PERFTEST_DIR:-/usr/bin}"  # ib_write_bw, ib_write_lat
export DCGMI_BIN="${DCGMI_BIN:-/usr/bin/dcgmi}"

# -----------------------------------------------------------------------------
# Expected hardware / software pins. Edit before running.
# -----------------------------------------------------------------------------
export EXPECTED_GPU_MODEL="NVIDIA B200"
export EXPECTED_GPU_COUNT=8
export EXPECTED_GPU_MEM_MIB=196608          # 192 GB
export EXPECTED_DRIVER_VERSION="TODO_FILL_AT_BURNIN"
export EXPECTED_CUDA_VERSION="12.6"
export EXPECTED_NCCL_VERSION="2.23.4"
export EXPECTED_FM_VERSION="TODO_FILL_AT_BURNIN"
export EXPECTED_OFED_VERSION="MLNX_OFED_LINUX-24.10"
export EXPECTED_NIC_COUNT=8
export EXPECTED_NIC_SPEED_GBPS=400          # NDR
export EXPECTED_NIC_LINK_WIDTH="4x"

# -----------------------------------------------------------------------------
# Pass/fail thresholds. Edit to match contractual targets.
# -----------------------------------------------------------------------------
# Per-GPU HBM3e triad (BabelStream), GB/s. B200 nominal ~ 7.5 TB/s.
export HBM_TRIAD_MIN_GBS=7000
# nvbandwidth P2P bidirectional, GB/s. NVL5 per-GPU bidir ~ 1800 GB/s.
export NVBW_P2P_BIDIR_MIN_GBS=1700
# 8-GPU intra-node all_reduce busbw at 8 GiB, GB/s.
export NCCL_INTRA_AR_BUSBW_MIN_GBS=380
# ib_write_bw line rate per NIC, Gb/s.
export IB_WRITE_BW_MIN_GBPS=380
# GPUDirect vs host-mem bandwidth ratio.
export IB_GDR_HOSTMEM_RATIO_MIN=0.97
# Pre-FEC BER ceiling.
export MLXLINK_PRE_FEC_BER_MAX=1e-7
# Cohort outlier definition: more than this many % below cohort median = flagged.
export COHORT_OUTLIER_PCT=1.0
# Max permitted PTP offset, microseconds.
export PTP_OFFSET_MAX_US=100
# gpu-burn duration, seconds.
export GPU_BURN_SECONDS=1800

# -----------------------------------------------------------------------------
# Helper: write a structured JSON fragment for a single check.
# Usage: qual_emit <check_name> <status: pass|fail|warn> <key=value> [key=value ...]
# -----------------------------------------------------------------------------
qual_emit() {
    local check="$1"; shift
    local status="$1"; shift
    local out="${QUAL_RESULTS}/$(hostname)_${check}.json"
    {
        printf '{"check":"%s","host":"%s","status":"%s","ts":"%s"' \
            "${check}" "$(hostname)" "${status}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        for kv in "$@"; do
            local k="${kv%%=*}"
            local v="${kv#*=}"
            # Quote string values, leave numeric/JSON values bare.
            if [[ "${v}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || [[ "${v}" =~ ^(true|false|null|\[|\{) ]]; then
                printf ',"%s":%s' "${k}" "${v}"
            else
                printf ',"%s":"%s"' "${k}" "${v}"
            fi
        done
        printf '}\n'
    } > "${out}"
}

qual_log() {
    echo "[$(date -u +%H:%M:%S)] [$(hostname)] $*" | tee -a "${QUAL_LOGS}/$(hostname).log"
}
