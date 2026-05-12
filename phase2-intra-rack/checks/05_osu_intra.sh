#!/usr/bin/env bash
# 05_osu_intra.sh — Test 2.5
# OSU Micro-Benchmarks at full-rack scope. Two collectives:
#   - osu_allreduce  (compare against NCCL all-reduce from 2.1)
#   - osu_alltoall   (most fabric-stressing pattern)
#
# We report numbers at three message sizes: 1 KiB (latency-dominated),
# 1 MiB (transition), and 64 MiB (bandwidth-dominated). The principal
# value here is a cross-check on NCCL: if OSU disagrees with NCCL by
# more than P2_OSU_NCCL_AGREEMENT_PCT, that's a flag.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../slurm/env.sh
source "${SCRIPT_DIR}/../slurm/env.sh"

CHECK="05_osu_intra"
OSU_ALLREDUCE="${OSU_DIR}/osu_allreduce"
OSU_ALLTOALL="${OSU_DIR}/osu_alltoall"

if [[ ! -x "${OSU_ALLREDUCE}" ]] || [[ ! -x "${OSU_ALLTOALL}" ]]; then
    p2_emit "${CHECK}" skip reason=osu_not_installed dir="${OSU_DIR}"
    exit 0
fi

if ! command -v mpirun >/dev/null 2>&1; then
    p2_emit "${CHECK}" skip reason=mpirun_missing
    exit 0
fi

ALLOC_NODES="${SLURM_NNODES:-0}"
if [[ "${ALLOC_NODES}" -lt 8 ]]; then
    p2_emit "${CHECK}" fail reason=allocation_too_small allocated="${ALLOC_NODES}" required=8
    exit 1
fi

out_dir="${P2_RESULTS}/${CHECK}_${SLURM_JOB_ID}"
mkdir -p "${out_dir}"

n=8
ntasks=$((n * P2_GPUS_PER_NODE))

# Helper: run one OSU binary, save log, return path.
run_osu() {
    local bin="$1"
    local label="$2"
    local log="${out_dir}/${label}.log"
    p2_log "${CHECK}: running ${label}"
    srun --nodes="${n}" \
         --ntasks="${ntasks}" \
         --ntasks-per-node="${P2_GPUS_PER_NODE}" \
         --gpus-per-task=1 \
         --output="${log}" \
         --error="${log}" \
         "${bin}" -d cuda -m 1:67108864 -f \
        && echo "${log}" || echo ""
}

ar_log=$(run_osu "${OSU_ALLREDUCE}" "allreduce")
aa_log=$(run_osu "${OSU_ALLTOALL}" "alltoall")

if [[ -z "${ar_log}" ]] || [[ -z "${aa_log}" ]]; then
    p2_emit "${CHECK}" fail reason=srun_failed out_dir="${out_dir}"
    exit 2
fi

# OSU output format (collective): one row per size, columns:
#   Size  Avg Latency(us)  Min Latency(us)  Max Latency(us)  Iterations
# We extract avg latency at 1024, 1048576, 67108864 bytes.
extract_latency() {
    local file="$1"
    local size="$2"
    awk -v s="${size}" '
        /^#/ { next }
        NF >= 2 && $1 == s { print $2; exit }
    ' "${file}"
}

ar_1k=$(extract_latency "${ar_log}" 1024)
ar_1m=$(extract_latency "${ar_log}" 1048576)
ar_64m=$(extract_latency "${ar_log}" 67108864)
aa_1k=$(extract_latency "${aa_log}" 1024)
aa_1m=$(extract_latency "${aa_log}" 1048576)
aa_64m=$(extract_latency "${aa_log}" 67108864)

if [[ -z "${ar_64m}" ]] || [[ -z "${aa_64m}" ]]; then
    p2_emit "${CHECK}" fail reason=parse_failed ar_log="${ar_log}" aa_log="${aa_log}"
    exit 2
fi

# OSU vs NCCL agreement check happens in the aggregator (which has both
# datasets at hand). Here we only emit a structurally-valid summary.
p2_emit "${CHECK}" pass \
    ar_1k_us="${ar_1k:-null}" ar_1m_us="${ar_1m:-null}" ar_64m_us="${ar_64m:-null}" \
    aa_1k_us="${aa_1k:-null}" aa_1m_us="${aa_1m:-null}" aa_64m_us="${aa_64m:-null}" \
    ar_log="${ar_log}" aa_log="${aa_log}" out_dir="${out_dir}"
