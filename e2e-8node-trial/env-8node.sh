#!/usr/bin/env bash
# Overrides for the 8-node E2E acceptance trial.
#
# Sourced by run_all.sh on the login node, and re-sourced inside every
# sbatch job (via --export=ALL). All variables here either narrow the
# 128-node-targeted defaults in the per-phase env.sh files OR redirect
# their output paths into ${E2E_RUN_DIR} so that everything we produce
# lives under one tree that can be tarballed at the end.
#
# THIS FILE MUST BE SOURCED, NOT EXECUTED.

set -u

# -----------------------------------------------------------------------------
# Cluster shape
# -----------------------------------------------------------------------------
export E2E_NODE_COUNT="${E2E_NODE_COUNT:-8}"
export E2E_GPUS_PER_NODE="${E2E_GPUS_PER_NODE:-8}"

# Slurm partition. Discovered by preflight.sh if not set.
export E2E_PARTITION="${E2E_PARTITION:-}"

# Time budgets per phase (Slurm wall-clock).
export E2E_PHASE1_TIME="${E2E_PHASE1_TIME:-01:30:00}"   # 8-node array; each task ~10 min × 1 = 10 min, plus margin
export E2E_PHASE2_TIME="${E2E_PHASE2_TIME:-02:00:00}"
export E2E_PHASE3_TIME="${E2E_PHASE3_TIME:-02:30:00}"

# -----------------------------------------------------------------------------
# Run directory (single root for everything we produce)
# -----------------------------------------------------------------------------
# E2E_RUN_DIR is set by run_all.sh before sourcing this file. Re-derive
# the per-phase paths from it so the existing phase scripts write here.
: "${E2E_RUN_DIR:?run_all.sh must set E2E_RUN_DIR before sourcing env-8node.sh}"

# Repo root — derived from this file's location so it works from anywhere.
E2E_TRIAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export E2E_REPO_ROOT="$(cd "${E2E_TRIAL_DIR}/.." && pwd)"

# -----------------------------------------------------------------------------
# Phase 1 — per-node qualification overrides
# -----------------------------------------------------------------------------
export QUAL_ROOT="${E2E_REPO_ROOT}/phase1-qualification"
export QUAL_RESULTS="${E2E_RUN_DIR}/phase1/results"
export QUAL_LOGS="${E2E_RUN_DIR}/phase1/logs"

# Threshold knobs that are 128-node-sized in the original env.sh and
# need narrowing for an 8-node trial.
export COHORT_OUTLIER_PCT="${COHORT_OUTLIER_PCT:-2.0}"  # looser at small N
# Trim gpu-burn to keep within an 8h budget. Original default 1800s.
export GPU_BURN_SECONDS="${GPU_BURN_SECONDS:-300}"

# -----------------------------------------------------------------------------
# Phase 2 — intra-rack / intra-cluster overrides
# -----------------------------------------------------------------------------
export P2_ROOT="${E2E_REPO_ROOT}/phase2-intra-rack"
export P2_RESULTS="${E2E_RUN_DIR}/phase2/results"
export P2_LOGS="${E2E_RUN_DIR}/phase2/logs"

# -----------------------------------------------------------------------------
# Phase 3 — full-scale, narrowed to the 8 nodes we have
# -----------------------------------------------------------------------------
export P3_ROOT="${E2E_REPO_ROOT}/phase3-fullscale"
export P3_RESULTS="${E2E_RUN_DIR}/phase3/results"
export P3_LOGS="${E2E_RUN_DIR}/phase3/logs"

# At 8 nodes (64 GPUs), the published B200 NCCL all-reduce busbw is
# much lower than the 1024-GPU number. Set conservative floors here;
# tune up after the first real run. These act as the contractual
# "should-pass" line — anything well above is fine.
export P3_FULL_NODES="${E2E_NODE_COUNT}"
export P3_SCALE_NODES="${P3_SCALE_NODES:-1 2 4 8}"
export NCCL_AR_BUSBW_MIN_1024GPU_GBS="${NCCL_AR_BUSBW_MIN_1024GPU_GBS:-300}"  # nominal floor at 64 GPUs
export NCCL_AG_BUSBW_MIN_1024GPU_GBS="${NCCL_AG_BUSBW_MIN_1024GPU_GBS:-270}"
export NCCL_RS_BUSBW_MIN_1024GPU_GBS="${NCCL_RS_BUSBW_MIN_1024GPU_GBS:-270}"
export NCCL_AA_BUSBW_MIN_1024GPU_GBS="${NCCL_AA_BUSBW_MIN_1024GPU_GBS:-200}"
export NCCL_SR_BUSBW_MIN_1024GPU_GBS="${NCCL_SR_BUSBW_MIN_1024GPU_GBS:-150}"

# Skip checks that require platform-side introspection we don't have on
# a managed Slinky platform. Each check that respects this variable
# emits a `skip` JSON fragment so the aggregator records the gap.
export E2E_SKIP_BMC="${E2E_SKIP_BMC:-1}"          # no IPMI from tenant
export E2E_SKIP_UFM="${E2E_SKIP_UFM:-1}"          # no UFM REST from tenant
export E2E_SKIP_MLXLINK="${E2E_SKIP_MLXLINK:-1}"  # no switch-side port access
export E2E_SKIP_SHARP_ABTEST="${E2E_SKIP_SHARP_ABTEST:-1}"  # SHARP is provider-controlled
export E2E_SKIP_AR_ABTEST="${E2E_SKIP_AR_ABTEST:-1}"       # AR is provider-controlled
# Translate the skip flags into the variables the existing checks read.
unset UFM_HOST 2>/dev/null || true
export UFM_HOST=""   # forces 11_ufm_snapshot.sh to skip cleanly
export P0_IPMI_USER="${P0_IPMI_USER:-}"  # left unset → BMC scripts refuse to run
export P0_IPMI_PASS="${P0_IPMI_PASS:-}"

# HPL / HPL-MxP / HPCG only run if their binaries are present in the
# NVIDIA HPC Benchmarks container, which we may not have on this
# cluster. Bootstrap will attempt to verify; if absent the checks
# skip cleanly.

# -----------------------------------------------------------------------------
# Tool path hints. Bootstrap installs into ${INSTALL_PREFIX}.
# -----------------------------------------------------------------------------
export INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/qualification}"
export NCCL_TESTS_DIR="${NCCL_TESTS_DIR:-${INSTALL_PREFIX}/nccl-tests/build}"
export NVBANDWIDTH_BIN="${NVBANDWIDTH_BIN:-${INSTALL_PREFIX}/bin/nvbandwidth}"
export GPU_BURN_DIR="${GPU_BURN_DIR:-${INSTALL_PREFIX}/gpu-burn}"
export BABELSTREAM_BIN="${BABELSTREAM_BIN:-${INSTALL_PREFIX}/bin/cuda-stream}"

# -----------------------------------------------------------------------------
# Create the per-phase directories now (login-node-side; preflight
# verifies they're visible on compute nodes via the shared FS check).
# -----------------------------------------------------------------------------
mkdir -p \
    "${QUAL_RESULTS}" "${QUAL_LOGS}" \
    "${P2_RESULTS}"   "${P2_LOGS}" \
    "${P3_RESULTS}"   "${P3_LOGS}" \
    "${E2E_RUN_DIR}/preflight" \
    "${E2E_RUN_DIR}/inventory" \
    "${E2E_RUN_DIR}/phase0" \
    "${E2E_RUN_DIR}/slurm-logs" \
    "${E2E_RUN_DIR}/report"

return 0 2>/dev/null || true
