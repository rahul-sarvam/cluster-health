#!/usr/bin/env bash
# Master orchestrator for the 8-node E2E acceptance trial.
#
# Designed to run on the LOGIN NODE under nohup. It does no GPU work
# itself; every workload step is delegated to srun or sbatch. All
# output lands under ${E2E_RUN_DIR} (default: $HOME/cluster-health-runs/run-<ts>).
#
# Usage:
#     # Standard run (default partition auto-detected, $HOME used as RUN_DIR root)
#     nohup ./e2e-8node-trial/run_all.sh > nohup.out 2>&1 &
#
#     # Override partition / run dir / time budgets:
#     E2E_PARTITION=gpu-a100 \
#     E2E_RUN_DIR=/shared/team/cluster-health/run-test \
#     E2E_PHASE3_TIME=04:00:00 \
#         ./e2e-8node-trial/run_all.sh
#
#     # Skip phases (resume after a failure):
#     E2E_SKIP=preflight,bootstrap,inventory ./e2e-8node-trial/run_all.sh
#
# Exit codes:
#   0  every phase pass / skip-by-design
#   1  at least one warn
#   2  at least one fail
#   3  pre-flight failure (couldn't even get going)

set -uo pipefail

# -----------------------------------------------------------------------------
# Locate paths
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export E2E_REPO_ROOT="${REPO_ROOT}"

# Where the results live. Default: $HOME so the shared FS (usually NFS
# /home) carries them across compute nodes. Override via E2E_RUN_DIR.
TS="$(date -u +%Y%m%d-%H%M%S)"
export E2E_RUN_DIR="${E2E_RUN_DIR:-${HOME}/cluster-health-runs/run-${TS}}"
mkdir -p "${E2E_RUN_DIR}"/{preflight,inventory,phase0,phase1/results,phase1/logs,phase2/results,phase2/logs,phase3/results,phase3/logs,slurm-logs,report}

# Tee the orchestrator's own output.
exec > >(tee -a "${E2E_RUN_DIR}/orchestrator.log") 2>&1

echo "============================================================"
echo " E2E 8-Node Acceptance Trial"
echo "============================================================"
echo " started at:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo " repo:         ${REPO_ROOT}"
echo " run dir:      ${E2E_RUN_DIR}"
echo " orchestrator log: ${E2E_RUN_DIR}/orchestrator.log"
echo "------------------------------------------------------------"
echo " ALL PATHS USED IN THIS RUN:"
echo "   preflight:        ${E2E_RUN_DIR}/preflight/"
echo "   inventory:        ${E2E_RUN_DIR}/inventory/"
echo "   phase0 (cohort):  ${E2E_RUN_DIR}/phase0/"
echo "   phase1 results:   ${E2E_RUN_DIR}/phase1/results/"
echo "   phase1 logs:      ${E2E_RUN_DIR}/phase1/logs/"
echo "   phase2 results:   ${E2E_RUN_DIR}/phase2/results/"
echo "   phase2 logs:      ${E2E_RUN_DIR}/phase2/logs/"
echo "   phase3 results:   ${E2E_RUN_DIR}/phase3/results/"
echo "   phase3 logs:      ${E2E_RUN_DIR}/phase3/logs/"
echo "   slurm stdout:     ${E2E_RUN_DIR}/slurm-logs/"
echo "   report:           ${E2E_RUN_DIR}/report/"
echo "============================================================"
echo

# Per-phase skip toggle (comma-separated names)
E2E_SKIP="${E2E_SKIP:-}"
is_skipped() {
    [[ ",${E2E_SKIP}," == *",$1,"* ]]
}

# -----------------------------------------------------------------------------
# Source overrides (also creates the subdirectories listed above)
# -----------------------------------------------------------------------------
# shellcheck source=env-8node.sh
source "${SCRIPT_DIR}/env-8node.sh"

# Verdict tracker. Each phase contributes a code (0/1/2).
declare -i WORST=0
record() {
    local rc="$1" phase="$2"
    echo "[orchestrator] ${phase} -> rc=${rc}"
    if (( rc > WORST )); then WORST=$rc; fi
}

# -----------------------------------------------------------------------------
# Login-side prep: ensure all our scripts are executable and pandas
# is installed for the per-phase aggregators that run on this pod.
# -----------------------------------------------------------------------------
echo "==> [0/7] login-side prep"
chmod -R +x \
    "${REPO_ROOT}/bootstrap" \
    "${REPO_ROOT}/phase1-qualification" \
    "${REPO_ROOT}/phase2-intra-rack" \
    "${REPO_ROOT}/phase3-fullscale" \
    "${REPO_ROOT}/e2e-8node-trial" 2>/dev/null || true
# pandas + pyyaml are needed by the phase1 aggregator on this pod.
# Use --break-system-packages because Ubuntu 24 / PEP 668 protects /usr.
pip install --quiet --break-system-packages pandas pyyaml 2>/dev/null \
    || echo "    couldn't install pandas/pyyaml on login pod (phase1 cohort aggregator may fail, non-fatal)"

# -----------------------------------------------------------------------------
# PHASE: pre-flight
# -----------------------------------------------------------------------------
if is_skipped preflight; then
    echo "==> [skip] pre-flight"
else
    echo "==> [1/7] pre-flight"
    if bash "${SCRIPT_DIR}/lib/preflight.sh"; then
        record 0 preflight
    else
        record 2 preflight
        echo "FATAL: pre-flight failed; aborting before burning compute"
        echo "  see ${E2E_RUN_DIR}/preflight/preflight.log"
        exit 3
    fi
    # Pick up the auto-discovered partition / nodelist from preflight.
    # shellcheck source=/dev/null
    [[ -r "${E2E_RUN_DIR}/preflight/discovered.env" ]] && \
        source "${E2E_RUN_DIR}/preflight/discovered.env"
    echo "    using partition=${E2E_PARTITION}"
fi

# -----------------------------------------------------------------------------
# PHASE: bootstrap on compute nodes (idempotent)
#   - first install just the apt build deps we need for the workloads
#     we're actually going to run (substrate + collectives focus,
#     so skip Phase 4 storage builds entirely)
#   - then run install.sh phase0 phase1 only (skip phase2/3/4 vendor
#     checks for tooling we know is missing; their checks will skip
#     cleanly at runtime)
# -----------------------------------------------------------------------------
if is_skipped bootstrap; then
    echo "==> [skip] bootstrap"
else
    echo "==> [2a/7] apt build deps on compute nodes (with --gpus-per-node so NVIDIA mounts attach)"
    srun -p "${E2E_PARTITION}" \
         -N "${E2E_NODE_COUNT}" --ntasks-per-node=1 \
         --gpus-per-node="${E2E_GPUS_PER_NODE}" \
         --time=00:15:00 \
         --output="${E2E_RUN_DIR}/slurm-logs/apt-deps-%N.out" \
         --error="${E2E_RUN_DIR}/slurm-logs/apt-deps-%N.err" \
         bash -c '
            set -e
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            # Core deps for our source builds + small utilities the check
            # scripts assume are present (bc, jq, numactl).
            apt-get install -y --no-install-recommends \
                bc \
                build-essential cmake git pkg-config \
                libnccl-dev libnuma-dev \
                openmpi-bin openmpi-common libopenmpi-dev \
                perftest numactl chrony jq python3-pip
            # CUDA toolkit: needed for source builds (nccl-tests, nvbandwidth,
            # gpu-burn, BabelStream). Ubuntu ships nvidia-cuda-toolkit which
            # provides nvcc at /usr/bin/nvcc; ABI-compatible with the libcuda
            # the runtime bind-mounts. Best-effort: a failure here means the
            # collective benchmarks will skip cleanly rather than break the run.
            apt-get install -y --no-install-recommends nvidia-cuda-toolkit \
                || echo "WARN: nvidia-cuda-toolkit install failed; nvcc-dependent checks will skip"
            echo "--- nvcc location and version ---"
            command -v nvcc && nvcc --version || echo "nvcc still not on PATH"
         ' || echo "    apt pre-install returned non-zero — see slurm-logs/apt-deps-*"

    echo "==> [2b/7] build phase1 workloads on compute nodes (nvbandwidth, gpu-burn, nccl-tests, BabelStream)"
    srun -p "${E2E_PARTITION}" \
         -N "${E2E_NODE_COUNT}" --ntasks-per-node=1 \
         --gpus-per-node="${E2E_GPUS_PER_NODE}" \
         --time=00:30:00 \
         --output="${E2E_RUN_DIR}/slurm-logs/bootstrap-%N.out" \
         --error="${E2E_RUN_DIR}/slurm-logs/bootstrap-%N.err" \
         bash "${REPO_ROOT}/bootstrap/install.sh" phase0 phase1 \
         || echo "    bootstrap srun returned non-zero — see slurm-logs/bootstrap-*"
    record 0 bootstrap   # don't fail the run on bootstrap; individual checks will surface what's broken
fi

# -----------------------------------------------------------------------------
# PHASE: per-node inventory (one srun fan-out)
# -----------------------------------------------------------------------------
if is_skipped inventory; then
    echo "==> [skip] inventory"
else
    echo "==> [3/7] per-node inventory"
    srun -p "${E2E_PARTITION}" \
         -N "${E2E_NODE_COUNT}" --ntasks-per-node=1 \
         --gpus-per-node="${E2E_GPUS_PER_NODE}" \
         --time=00:10:00 \
         --output="${E2E_RUN_DIR}/slurm-logs/inventory-%N.out" \
         --error="${E2E_RUN_DIR}/slurm-logs/inventory-%N.err" \
         bash "${SCRIPT_DIR}/lib/inventory.sh" \
         || echo "    inventory srun returned non-zero"
    record 0 inventory

    echo "==> [4/7] cohort drift analysis"
    python3 "${SCRIPT_DIR}/lib/cohort_drift.py" \
        --in-dir "${E2E_RUN_DIR}/inventory" \
        --out "${E2E_RUN_DIR}/phase0/cohort_drift.json" \
        --report "${E2E_RUN_DIR}/phase0/cohort_drift.md" \
        --expected-nodes "${E2E_NODE_COUNT}"
    record $? cohort_drift
fi

# -----------------------------------------------------------------------------
# PHASE 1 — per-node qualification (array job)
# -----------------------------------------------------------------------------
if is_skipped phase1; then
    echo "==> [skip] phase 1"
else
    echo "==> [5/7] phase 1 — per-node qualification (sbatch array=0-$((E2E_NODE_COUNT-1)))"
    sbatch --wait \
        --partition="${E2E_PARTITION}" \
        --array="0-$((E2E_NODE_COUNT-1))" \
        --time="${E2E_PHASE1_TIME}" \
        --output="${E2E_RUN_DIR}/slurm-logs/phase1-%A_%a.out" \
        --error="${E2E_RUN_DIR}/slurm-logs/phase1-%A_%a.err" \
        --export=ALL \
        "${SCRIPT_DIR}/sbatch/phase1_8node.sbatch"
    record $? phase1

    # NOTE: the existing phase1-qualification/aggregate/report.py expects a
    # full chain (parse_results.py --gather → cohort_analysis.py → report.py)
    # to produce cohort.parquet / outliers.csv first. Our executive aggregator
    # at the end of run_all.sh handles cross-host summary from the per-host
    # JSONs directly, so we skip the phase1 cohort aggregator here. If you
    # want the full per-host outlier table, run the chain manually post-run.
fi

# -----------------------------------------------------------------------------
# PHASE 2 — intra-cluster collectives
# -----------------------------------------------------------------------------
if is_skipped phase2; then
    echo "==> [skip] phase 2"
else
    echo "==> [6/7] phase 2 — intra-cluster collectives (sbatch nodes=${E2E_NODE_COUNT})"
    sbatch --wait \
        --partition="${E2E_PARTITION}" \
        --nodes="${E2E_NODE_COUNT}" \
        --time="${E2E_PHASE2_TIME}" \
        --output="${E2E_RUN_DIR}/slurm-logs/phase2-%j.out" \
        --error="${E2E_RUN_DIR}/slurm-logs/phase2-%j.err" \
        --export=ALL \
        "${SCRIPT_DIR}/sbatch/phase2_8node.sbatch"
    record $? phase2
fi

# -----------------------------------------------------------------------------
# PHASE 3 — collective sweep at 8-node scale
# -----------------------------------------------------------------------------
if is_skipped phase3; then
    echo "==> [skip] phase 3"
else
    echo "==> [7/7] phase 3 — collective sweep + HPL at 8-node scale (sbatch nodes=${E2E_NODE_COUNT})"
    sbatch --wait \
        --partition="${E2E_PARTITION}" \
        --nodes="${E2E_NODE_COUNT}" \
        --time="${E2E_PHASE3_TIME}" \
        --output="${E2E_RUN_DIR}/slurm-logs/phase3-%j.out" \
        --error="${E2E_RUN_DIR}/slurm-logs/phase3-%j.err" \
        --export=ALL \
        "${SCRIPT_DIR}/sbatch/phase3_8node.sbatch"
    record $? phase3
fi

# -----------------------------------------------------------------------------
# Executive aggregation
# -----------------------------------------------------------------------------
echo "==> aggregation"
python3 "${SCRIPT_DIR}/lib/aggregate_executive.py" \
    --run-dir "${E2E_RUN_DIR}" \
    --out "${E2E_RUN_DIR}/report/REPORT.md" \
    --summary-json "${E2E_RUN_DIR}/report/summary.json"
AGG_RC=$?
record "${AGG_RC}" aggregate

# -----------------------------------------------------------------------------
# Tarball
# -----------------------------------------------------------------------------
echo "==> tarball"
TARBALL="${HOME}/cluster-health-runs/run-${TS}.tar.gz"
mkdir -p "$(dirname "${TARBALL}")"
tar czf "${TARBALL}" -C "$(dirname "${E2E_RUN_DIR}")" "$(basename "${E2E_RUN_DIR}")"
echo "    tarball:    ${TARBALL}"
echo "    size:       $(du -h "${TARBALL}" | awk '{print $1}')"
ls -la "${TARBALL}"

# -----------------------------------------------------------------------------
# Final
# -----------------------------------------------------------------------------
echo "============================================================"
echo " finished at:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo " worst code:   ${WORST}"
echo " report:       ${E2E_RUN_DIR}/report/REPORT.md"
echo " tarball:      ${TARBALL}"
echo "============================================================"

exit "${WORST}"
