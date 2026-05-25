#!/usr/bin/env bash
# 07_intra_node_nccl.sh
# 8-GPU intra-node NCCL all_reduce and alltoall sanity. This is the first
# software-stack-end-to-end check: if this fails but nvbandwidth passed,
# the issue is in NCCL config / SHARP / topology, not the silicon.
set -uo pipefail
source "${QUAL_ROOT}/slurm/env.sh"

OUT_AR="${QUAL_LOGS}/$(hostname)_nccl_ar.txt"
OUT_A2A="${QUAL_LOGS}/$(hostname)_nccl_a2a.txt"

# Skip cleanly if nccl-tests aren't built (nvcc unavailable so bootstrap
# couldn't build them on this image).
if ! [[ -x "${NCCL_TESTS_DIR}/all_reduce_perf" ]]; then
    qual_emit intra_node_nccl skip reason="nccl_tests_not_built" path="${NCCL_TESTS_DIR}/all_reduce_perf"
    exit 0
fi

export NCCL_DEBUG=INFO
export NCCL_DEBUG_SUBSYS=INIT,GRAPH,TUNING
# Force intra-node only.
export NCCL_IB_DISABLE=1

mpirun -np "${EXPECTED_GPU_COUNT}" --bind-to none \
    "${NCCL_TESTS_DIR}/all_reduce_perf" -b 8 -e 8G -f 2 -g 1 -w 5 -n 20 \
    > "${OUT_AR}" 2>&1

mpirun -np "${EXPECTED_GPU_COUNT}" --bind-to none \
    "${NCCL_TESTS_DIR}/alltoall_perf" -b 8 -e 8G -f 2 -g 1 -w 5 -n 20 \
    > "${OUT_A2A}" 2>&1

# Extract busbw at 8 GiB message size from the table tail.
ar_bw=$(awk '/^[ ]+8589934592/ {print $11; exit}' "${OUT_AR}")
a2a_bw=$(awk '/^[ ]+8589934592/ {print $11; exit}' "${OUT_A2A}")

# Topology sanity: confirm NVSwitch / SHARP detection in the log.
nvswitch_ok=$(grep -c "NVL.*via" "${OUT_AR}" || true)
sharp_status=$(grep -E "SHARP|collnet" "${OUT_AR}" | head -n3 | tr '\n' ';')

fail=0
if [[ -z "${ar_bw}" ]] || awk -v b="${ar_bw}" -v m="${NCCL_INTRA_AR_BUSBW_MIN_GBS}" 'BEGIN {exit !(b < m)}'; then
    fail=1
fi

status="pass"; [[ "${fail}" -eq 1 ]] && status="fail"
qual_emit intra_node_nccl "${status}" \
    ar_log="${OUT_AR}" \
    a2a_log="${OUT_A2A}" \
    ar_busbw_8gib_gbs="${ar_bw:-0}" \
    a2a_busbw_8gib_gbs="${a2a_bw:-0}" \
    nvswitch_topo_lines="${nvswitch_ok}" \
    sharp_status="${sharp_status}"

exit "${fail}"
