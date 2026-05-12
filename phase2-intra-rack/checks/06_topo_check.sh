#!/usr/bin/env bash
# 06_topo_check.sh — Test 2.6
# Dump NCCL's discovered topology from a single-node run and diff it
# against a captured reference. Catches: missing NIC, NIC bound to wrong
# PCIe root, GPU↔NIC affinity misconfig, NVLink fabric not initialized.
#
# Behavior:
#   - If no reference XML is present, we WARN and capture the current
#     dump as the candidate-reference (useful on the first run).
#   - Otherwise we diff and fail on any structural change.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../slurm/env.sh
source "${SCRIPT_DIR}/../slurm/env.sh"

CHECK="06_topo_check"
ALL_REDUCE_BIN="${NCCL_TESTS_DIR}/all_reduce_perf"

if [[ ! -x "${ALL_REDUCE_BIN}" ]]; then
    p2_emit "${CHECK}" fail reason=missing_binary path="${ALL_REDUCE_BIN}"
    exit 1
fi

out_dir="${P2_RESULTS}/${CHECK}_${SLURM_JOB_ID}"
mkdir -p "${out_dir}"
dump_file="${out_dir}/nccl_topo.xml"
run_log="${out_dir}/run.log"

n=1
ntasks=$((n * P2_GPUS_PER_NODE))

p2_log "${CHECK}: capturing NCCL topology dump on a single node"

# A tiny all-reduce just to force NCCL init + topology discovery.
NCCL_TOPO_DUMP_FILE="${dump_file}" \
srun --nodes="${n}" \
     --ntasks="${ntasks}" \
     --ntasks-per-node="${P2_GPUS_PER_NODE}" \
     --gpus-per-task=1 \
     --output="${run_log}" \
     --error="${run_log}" \
     --export=ALL,NCCL_TOPO_DUMP_FILE="${dump_file}",NCCL_DEBUG="${NCCL_DEBUG}" \
     "${ALL_REDUCE_BIN}" -b 8 -e 8 -g 1 -c 1 -n 1 -w 1 \
    || {
        p2_emit "${CHECK}" fail reason=srun_failed log="${run_log}"
        exit 2
    }

if [[ ! -s "${dump_file}" ]]; then
    p2_emit "${CHECK}" fail reason=no_dump_produced log="${run_log}"
    exit 2
fi

# Normalize the XML before diffing: strip volatile bits (PIDs, hostnames,
# absolute serial numbers if they appear). What we want to fingerprint is
# the *structure*: GPU/NIC presence, PCIe path, NVLink edges.
normalize() {
    # Drop comments, drop attributes that change run-to-run.
    sed -E \
        -e 's/host="[^"]*"//g' \
        -e 's/pid="[^"]*"//g' \
        -e 's/\s+/ /g' \
        -e '/<!--/d' \
        "$1"
}

candidate_norm="${out_dir}/nccl_topo.norm.xml"
normalize "${dump_file}" > "${candidate_norm}"

if [[ ! -s "${P2_REF_TOPO}" ]]; then
    p2_log "${CHECK}: no reference topology at ${P2_REF_TOPO}; emitting warn"
    p2_emit "${CHECK}" warn reason=no_reference \
        captured="${candidate_norm}" \
        hint="Bake a known-good run's normalized XML to ${P2_REF_TOPO}." \
        out_dir="${out_dir}"
    exit 0
fi

ref_norm="${out_dir}/nccl_topo_ref.norm.xml"
normalize "${P2_REF_TOPO}" > "${ref_norm}"

diff_file="${out_dir}/topo.diff"
if diff -u "${ref_norm}" "${candidate_norm}" > "${diff_file}"; then
    p2_emit "${CHECK}" pass \
        reference="${P2_REF_TOPO}" \
        captured="${dump_file}" out_dir="${out_dir}"
    exit 0
fi

# Diff is non-empty — fail with pointer to the diff file.
added=$(grep -c '^+[^+]' "${diff_file}" || true)
removed=$(grep -c '^-[^-]' "${diff_file}" || true)
p2_emit "${CHECK}" fail reason=topology_drift \
    lines_added="${added}" lines_removed="${removed}" \
    diff="${diff_file}" reference="${P2_REF_TOPO}" \
    captured="${dump_file}" out_dir="${out_dir}"
exit 2
