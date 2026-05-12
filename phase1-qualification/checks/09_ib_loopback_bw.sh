#!/usr/bin/env bash
# 09_ib_loopback_bw.sh
# Per-NIC line rate and GPUDirect RDMA verification by pairing local NICs
# (mlx5_0 <-> mlx5_1, mlx5_2 <-> mlx5_3, ...). Runs ib_write_bw with system
# memory and with --use_cuda, then computes the ratio. GPUDirect should be
# within ~3% of host-memory bandwidth.
#
# NOTE: For a true cross-rack BER stress test you want pair-with-leaf-neighbor
# instead of intra-node pairing; that's part of phase 2 (intra-rack), not
# the Day-1 gate. Here we are only confirming this node's NICs themselves
# can drive line rate.
set -uo pipefail
source "${QUAL_ROOT}/slurm/env.sh"

OUT="${QUAL_LOGS}/$(hostname)_ib_loopback.txt"
: > "${OUT}"

mapfile -t NICS < <(ibstat -l 2>/dev/null)
n="${#NICS[@]}"
if (( n % 2 != 0 )); then
    qual_emit ib_loopback_bw fail reason="odd_nic_count_${n}"
    exit 1
fi

declare -a results
fail=0
for ((i=0; i<n; i+=2)); do
    server="${NICS[$i]}"
    client="${NICS[$((i+1))]}"

    # Host-memory line rate
    "${PERFTEST_DIR}/ib_write_bw" -d "${server}" -F --report_gbits -D 10 > "${OUT}.server" 2>&1 &
    SPID=$!
    sleep 2
    "${PERFTEST_DIR}/ib_write_bw" -d "${client}" -F --report_gbits -D 10 127.0.0.1 > "${OUT}.client" 2>&1 || true
    wait "${SPID}" || true
    host_bw=$(awk '/^[ ]+[0-9]+[ ]+[0-9]+[ ]+/ {print $4}' "${OUT}.client" | tail -n1)

    # GPU-memory line rate (--use_cuda, GPU 0)
    "${PERFTEST_DIR}/ib_write_bw" -d "${server}" -F --report_gbits -D 10 --use_cuda=0 > "${OUT}.server" 2>&1 &
    SPID=$!
    sleep 2
    "${PERFTEST_DIR}/ib_write_bw" -d "${client}" -F --report_gbits -D 10 --use_cuda=$((i+1)) 127.0.0.1 > "${OUT}.client" 2>&1 || true
    wait "${SPID}" || true
    gpu_bw=$(awk '/^[ ]+[0-9]+[ ]+[0-9]+[ ]+/ {print $4}' "${OUT}.client" | tail -n1)

    ratio=$(awk -v g="${gpu_bw:-0}" -v h="${host_bw:-1}" 'BEGIN {printf "%.4f", g/h}')
    cat "${OUT}.server" "${OUT}.client" >> "${OUT}"

    pair_fail=0
    if awk -v b="${host_bw:-0}" -v m="${IB_WRITE_BW_MIN_GBPS}" 'BEGIN {exit !(b+0 < m+0)}'; then pair_fail=1; fi
    if awk -v r="${ratio:-0}" -v m="${IB_GDR_HOSTMEM_RATIO_MIN}" 'BEGIN {exit !(r+0 < m+0)}'; then pair_fail=1; fi
    [[ "${pair_fail}" -eq 1 ]] && fail=1

    results+=("{\"server\":\"${server}\",\"client\":\"${client}\",\"host_gbps\":${host_bw:-0},\"gpu_gbps\":${gpu_bw:-0},\"gdr_ratio\":${ratio},\"fail\":${pair_fail}}")
done

per_pair_json="[$(IFS=,; echo "${results[*]}")]"
status="pass"; [[ "${fail}" -eq 1 ]] && status="fail"
qual_emit ib_loopback_bw "${status}" \
    log_path="${OUT}" \
    per_pair="${per_pair_json}"

exit "${fail}"
