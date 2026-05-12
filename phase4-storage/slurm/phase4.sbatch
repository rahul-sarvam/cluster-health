#!/usr/bin/env bash
#SBATCH --job-name=phase4-storage
#SBATCH --nodes=128
#SBATCH --ntasks-per-node=8
#SBATCH --gpus-per-node=8
#SBATCH --time=08:00:00
#SBATCH --exclusive
#SBATCH --output=phase4-storage/results/phase4_%j.out
#SBATCH --error=phase4-storage/results/phase4_%j.err
#
# Phase 4 — Storage Scale orchestrator.
#
# Runs all eight storage tests sequentially against the shared parallel
# filesystem (${P4_STORAGE_ROOT}). One allocation, one job ID, one
# aggregated Markdown report at the end.
#
# Test order matters:
#   1. IOR sequential       — pure sequential read/write floor
#   2. mdtest               — metadata throughput
#   3. FIO mixed            — small-IO + low-QD latency baseline
#   4. elbencho + GDS       — GPUDirect Storage path
#   5. MLPerf Storage       — realistic dataloader emulation
#   6. ckpt storm           — burst write at deadline
#   7. noisy-neighbor       — reader tail under writer pressure
#   8. GDS PyTorch dataloader — real torch + cuFile end-to-end
#
# Each check emits its own JSON fragment into ${P4_RESULTS}; the
# aggregator reads them all + the per-test logs and renders one
# Markdown report with PASS/WARN/FAIL verdicts.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"
source "slurm/env.sh"

JOB="${SLURM_JOB_ID:-manual$$}"
export SLURM_JOB_ID="${JOB}"

p4_log "Phase 4 start: job=${JOB} nodes=${SLURM_NNODES:-?} storage=${P4_STORAGE_ROOT}"

# Pre-flight: storage root must exist and be writable. If it isn't,
# fail fast so we don't burn an 8-hour allocation on a config issue.
if ! p4_check_storage_root; then
    p4_emit "00_preflight" "fail" reason="storage_root_unavailable" path="${P4_STORAGE_ROOT}"
    p4_log "ABORT: storage root unavailable; running aggregator on partial results"
    "${P4_PYTHON}" aggregate/report.py \
        --results-dir "${P4_RESULTS}" \
        --job-id "${JOB}" \
        --out "${P4_RESULTS}/phase4_report_${JOB}.md" \
        || true
    exit 1
fi
p4_emit "00_preflight" "pass" path="${P4_STORAGE_ROOT}"

overall_rc=0

# Run a single check; track its rc. We treat any non-zero rc as
# substantive failure (the check script itself decides between "skip"
# (0) and "fail" (2)), but never abort the whole phase on it.
run_check() {
    local name="$1"; shift
    p4_log "----- ${name} starting -----"
    if bash "$@"; then
        p4_log "----- ${name} OK -----"
    else
        local rc=$?
        p4_log "----- ${name} rc=${rc} -----"
        if [[ ${rc} -gt overall_rc ]]; then overall_rc=${rc}; fi
    fi
}

run_check "4.1 IOR sequential"    checks/01_ior_sequential.sh
run_check "4.2 mdtest"            checks/02_mdtest.sh
run_check "4.3 FIO mixed"         checks/03_fio_mixed.sh
run_check "4.4 elbencho+GDS"      checks/04_elbencho_gds.sh
run_check "4.5 MLPerf Storage"    checks/05_mlperf_storage.sh
run_check "4.6 checkpoint storm"  checks/06_ckpt_storm.sh
run_check "4.7 noisy neighbor"    checks/07_noisy_neighbor.sh
run_check "4.8 GDS dataloader"    checks/08_gds_dataloader.sh

p4_log "all checks complete; rolling up"

"${P4_PYTHON}" aggregate/report.py \
    --results-dir "${P4_RESULTS}" \
    --job-id "${JOB}" \
    --out "${P4_RESULTS}/phase4_report_${JOB}.md"
agg_rc=$?

if [[ ${agg_rc} -gt overall_rc ]]; then overall_rc=${agg_rc}; fi
p4_log "Phase 4 done (rc=${overall_rc})"
exit ${overall_rc}
