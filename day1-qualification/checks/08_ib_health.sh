#!/usr/bin/env bash
# 08_ib_health.sh
# IB / NDR health per NIC port:
#   - Link width = 4x, link speed = NDR
#   - mlxlink: pre-FEC and post-FEC BER, 0 symbol errors
#   - Cable diagnostics (FW, SN, length)
# This is the check that catches the cables that pass ib_write_bw but
# silently raise pre-FEC BER and fail under sustained load.
set -uo pipefail
source "${QUAL_ROOT}/slurm/env.sh"

OUT="${QUAL_LOGS}/$(hostname)_ib_health.txt"
: > "${OUT}"

# Enumerate NIC names (mlx5_0, mlx5_1, ...).
mapfile -t NICS < <(ibstat -l 2>/dev/null)

fail=0
results=()
for nic in "${NICS[@]}"; do
    # ibstat per-NIC summary
    state=$(ibstat "${nic}" | awk '/State:/ {print $2; exit}')
    rate=$(ibstat "${nic}" | awk '/Rate:/ {print $2; exit}')
    width=$(ibstat "${nic}" | awk '/Width:/ {print $2; exit}')
    {
        echo "=== ${nic} ==="
        ibstat "${nic}"
        echo
        echo "--- mlxlink ${nic} ---"
        mlxlink -d "${nic}" -m -c -e --show_fec 2>&1 || true
        echo "--- counters ${nic} ---"
        # Pre/post FEC BER and symbol errors via mlxlink JSON
        mlxlink -d "${nic}" --json 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception as e:
    print('parse_error:', e); sys.exit(0)
def find(d, key):
    if isinstance(d, dict):
        for k,v in d.items():
            if k == key: return v
            r = find(v, key)
            if r is not None: return r
    if isinstance(d, list):
        for v in d:
            r = find(v, key)
            if r is not None: return r
    return None
print('raw_phys_err_per_lane:', find(d, 'Raw Physical Errors Per Lane'))
print('effective_ber:',         find(d, 'Effective Physical BER'))
print('raw_ber:',                find(d, 'Raw Physical BER'))
print('symbol_errors:',          find(d, 'Symbol Errors'))
"
    } >> "${OUT}" 2>&1

    pre_fec_ber=$(grep "raw_ber:" "${OUT}" | tail -n1 | awk '{print $2}')
    eff_ber=$(grep "effective_ber:" "${OUT}" | tail -n1 | awk '{print $2}')
    sym_err=$(grep "symbol_errors:" "${OUT}" | tail -n1 | awk '{print $2}')

    nic_fail=0
    if [[ "${state}" != "Active" ]]; then nic_fail=1; fi
    if [[ "${rate}" != "${EXPECTED_NIC_SPEED_GBPS}" ]] && [[ "${rate}" != "NDR" ]]; then nic_fail=1; fi
    if [[ "${width}" != "${EXPECTED_NIC_LINK_WIDTH}" ]]; then nic_fail=1; fi
    if awk -v b="${pre_fec_ber:-0}" -v m="${MLXLINK_PRE_FEC_BER_MAX}" 'BEGIN {exit !(b+0 > m+0)}'; then
        nic_fail=1
    fi
    if [[ "${sym_err:-0}" =~ ^[0-9]+$ ]] && [[ "${sym_err}" -gt 0 ]]; then
        nic_fail=1
    fi

    [[ "${nic_fail}" -eq 1 ]] && fail=1
    results+=("{\"nic\":\"${nic}\",\"state\":\"${state}\",\"rate\":\"${rate}\",\"width\":\"${width}\",\"pre_fec_ber\":\"${pre_fec_ber}\",\"eff_ber\":\"${eff_ber}\",\"sym_err\":\"${sym_err}\",\"fail\":${nic_fail}}")
done

per_nic_json="[$(IFS=,; echo "${results[*]}")]"
status="pass"; [[ "${fail}" -eq 1 ]] && status="fail"
qual_emit ib_health "${status}" \
    log_path="${OUT}" \
    nic_count="${#NICS[@]}" \
    per_nic="${per_nic_json}"

exit "${fail}"
