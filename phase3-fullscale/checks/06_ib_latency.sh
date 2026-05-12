#!/usr/bin/env bash
# 06_ib_latency.sh — Test 3.6
# `ib_write_lat` between two ranks (a) on the same leaf and (b) across
# the spine. Catches a particular class of pathology where bandwidth
# looks fine but tail-latency-sensitive workloads (param-server, RPCs)
# silently slow down because some routes traverse extra hops.
#
# We don't enumerate all leaves — that would take hours. We pick:
#   - the first node and its physical neighbour (same leaf, by hostname order)
#   - the first node and the last node in the allocation (likely cross-spine)
# This is a smoke test, not exhaustive coverage. Phase 3.4 (ClusterKit
# fullscale) covers all-pairs.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../slurm/env.sh
source "${SCRIPT_DIR}/../slurm/env.sh"

CHECK="06_ib_latency"

if ! command -v "${IB_WRITE_LAT}" >/dev/null 2>&1; then
    p3_emit "${CHECK}" fail reason=missing_binary path="${IB_WRITE_LAT}"
    exit 1
fi
if ! p3_have_full_scale; then
    p3_emit "${CHECK}" fail reason=allocation_too_small allocated="${SLURM_NNODES:-0}" required="${P3_FULL_NODES}"
    exit 1
fi

out_dir="${P3_RESULTS}/${CHECK}_${SLURM_JOB_ID}"
mkdir -p "${out_dir}"

# Map: position-in-nodelist → hostname.
mapfile -t HOSTS < <(scontrol show hostnames "${SLURM_JOB_NODELIST}")
NHOSTS=${#HOSTS[@]}
if [[ "${NHOSTS}" -lt 2 ]]; then
    p3_emit "${CHECK}" fail reason=too_few_nodes_in_alloc count="${NHOSTS}"
    exit 1
fi

intra_leaf_a="${HOSTS[0]}"   ; intra_leaf_b="${HOSTS[1]}"
cross_spine_a="${HOSTS[0]}"  ; cross_spine_b="${HOSTS[$((NHOSTS - 1))]}"

# ib_write_lat takes a server arg and a client. We start a server on host A
# in the background, then run the client on host B.
run_pair() {
    local label="$1" server="$2" client="$3" port_offset="$4"
    local server_log="${out_dir}/${label}_server.log"
    local client_log="${out_dir}/${label}_client.log"
    local port=$((18515 + port_offset))
    p3_log "${CHECK}: ${label}: server=${server} client=${client} port=${port}"
    srun --nodes=1 --ntasks=1 --nodelist="${server}" \
         --output="${server_log}" --error="${server_log}" \
         "${IB_WRITE_LAT}" -p "${port}" -F -n 5000 &
    local server_pid=$!
    sleep 3   # server bring-up
    srun --nodes=1 --ntasks=1 --nodelist="${client}" \
         --output="${client_log}" --error="${client_log}" \
         "${IB_WRITE_LAT}" -p "${port}" -F -n 5000 "${server}"
    local client_rc=$?
    wait "${server_pid}" 2>/dev/null || true
    if [[ "${client_rc}" -ne 0 ]]; then echo ""; return 1; fi
    # perftest format: the row starting "  <bytes>  <iters>  <t_min>  <t_max>  <t_typical>  <t_avg>  <t_stdev>  <99% percentile>"
    # We take the typical (median) latency at the smallest message (2 bytes).
    awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9.]+[[:space:]]+[0-9.]+[[:space:]]+[0-9.]+/ {print $5; exit}' "${client_log}"
}

intra_us=$(run_pair intra_leaf "${intra_leaf_a}" "${intra_leaf_b}" 0) || true
cross_us=$(run_pair cross_spine "${cross_spine_a}" "${cross_spine_b}" 1) || true

if [[ -z "${intra_us}" ]] || [[ -z "${cross_us}" ]]; then
    p3_emit "${CHECK}" fail reason=run_failed intra_us="${intra_us:-null}" cross_us="${cross_us:-null}" out_dir="${out_dir}"
    exit 2
fi

intra_over=$(awk -v a="${intra_us}" -v t="${P3_IB_INTRA_LEAF_LAT_MAX_US}" 'BEGIN{print (a+0>t+0)?"1":"0"}')
cross_over=$(awk -v a="${cross_us}" -v t="${P3_IB_CROSS_SPINE_LAT_MAX_US}" 'BEGIN{print (a+0>t+0)?"1":"0"}')

if [[ "${intra_over}" -eq 1 ]] || [[ "${cross_over}" -eq 1 ]]; then
    p3_emit "${CHECK}" fail \
        intra_leaf_us="${intra_us}" cross_spine_us="${cross_us}" \
        intra_leaf_pair="${intra_leaf_a},${intra_leaf_b}" \
        cross_spine_pair="${cross_spine_a},${cross_spine_b}" \
        intra_ceiling_us="${P3_IB_INTRA_LEAF_LAT_MAX_US}" \
        cross_ceiling_us="${P3_IB_CROSS_SPINE_LAT_MAX_US}" \
        out_dir="${out_dir}"
    exit 2
fi

p3_emit "${CHECK}" pass \
    intra_leaf_us="${intra_us}" cross_spine_us="${cross_us}" \
    intra_leaf_pair="${intra_leaf_a},${intra_leaf_b}" \
    cross_spine_pair="${cross_spine_a},${cross_spine_b}" \
    intra_ceiling_us="${P3_IB_INTRA_LEAF_LAT_MAX_US}" \
    cross_ceiling_us="${P3_IB_CROSS_SPINE_LAT_MAX_US}" \
    out_dir="${out_dir}"
