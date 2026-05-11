#!/usr/bin/env bash
# bmc_sweep.sh
# Reach every BMC, verify it's online, dump sensors, system event log (SEL),
# FRU inventory, and power/PSU/fan state. Output one JSON-friendly text file
# per BMC; bmc_summary.py distills these into pass/warn/fail.
#
# Supports two transports (chosen via P0_BMC_PROTOCOL):
#   - ipmitool: lowest common denominator, every BMC supports it
#   - redfish:  preferred where available (richer schema, less prone to LAN-stale-session bugs)
#
# Read-only. No control-plane mutation (no power cycles, no LED toggles).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

p0_check_credentials || exit 1

if [[ ! -s "${P0_BMCS}" ]]; then
    echo "ERROR: ${P0_BMCS} does not exist or is empty. Populate one BMC host per line." >&2
    exit 1
fi

ts="$(date -u +%Y%m%dT%H%M%SZ)"
out_dir="${P0_RESULTS}/bmc_${ts}"
mkdir -p "${out_dir}"

p0_log "bmc_sweep: starting; protocol=${P0_BMC_PROTOCOL}; outputs -> ${out_dir}"

# -----------------------------------------------------------------------------
# Per-BMC probes
# -----------------------------------------------------------------------------
probe_one_ipmitool() {
    local bmc="$1"
    local base=("ipmitool" "-I" "lanplus" "-H" "${bmc}"
                "-U" "${P0_IPMI_USER}" "-P" "${P0_IPMI_PASS}")
    local outf="${out_dir}/${bmc}.txt"
    {
        echo "===== MC INFO ====="; "${base[@]}" mc info 2>&1
        echo "===== POWER STATUS ====="; "${base[@]}" chassis power status 2>&1
        echo "===== SDR ====="; "${base[@]}" sdr 2>&1
        echo "===== SENSOR ====="; "${base[@]}" sensor 2>&1
        echo "===== SEL ====="; "${base[@]}" sel list 2>&1 | tail -200
        echo "===== FRU ====="; "${base[@]}" fru print 2>&1
    } > "${outf}" 2>&1
}

probe_one_redfish() {
    local bmc="$1"
    local outf="${out_dir}/${bmc}.txt"
    local curl_opts=(-sk --max-time 30 -u "${P0_IPMI_USER}:${P0_IPMI_PASS}")
    {
        echo "===== SYSTEMS ====="
        curl "${curl_opts[@]}" "https://${bmc}/redfish/v1/Systems/" 2>&1
        echo "===== SYSTEM ROOT ====="
        # We try the most common embedded id; the aggregator parses these defensively.
        for sysid in System.Embedded.1 Self 1 System.1; do
            curl "${curl_opts[@]}" "https://${bmc}/redfish/v1/Systems/${sysid}" 2>&1
            echo
        done
        echo "===== CHASSIS ====="
        curl "${curl_opts[@]}" "https://${bmc}/redfish/v1/Chassis/" 2>&1
        echo "===== THERMAL ====="
        curl "${curl_opts[@]}" "https://${bmc}/redfish/v1/Chassis/System.Embedded.1/Thermal" 2>&1
        echo "===== POWER ====="
        curl "${curl_opts[@]}" "https://${bmc}/redfish/v1/Chassis/System.Embedded.1/Power" 2>&1
        echo "===== SEL ====="
        curl "${curl_opts[@]}" "https://${bmc}/redfish/v1/Managers/iDRAC.Embedded.1/LogServices/Sel/Entries" 2>&1
    } > "${outf}" 2>&1
}

# -----------------------------------------------------------------------------
# Driver loop with bounded parallelism (no xargs ssh fanout here; we want
# per-BMC quoting to stay sane and avoid passing credentials over xargs).
# -----------------------------------------------------------------------------
slot=0
pids=()
mapfile -t BMCS < "${P0_BMCS}"
for bmc in "${BMCS[@]}"; do
    bmc="$(echo "${bmc}" | tr -d '\r' | xargs)"
    [[ -z "${bmc}" ]] && continue
    (
        case "${P0_BMC_PROTOCOL}" in
            redfish)   probe_one_redfish   "${bmc}" ;;
            ipmitool)  probe_one_ipmitool  "${bmc}" ;;
            *)         echo "Unknown P0_BMC_PROTOCOL=${P0_BMC_PROTOCOL}" >&2 ;;
        esac
        # Per-BMC pass/fail fragment (transport-level only; bmc_summary.py
        # does the sensor-aware analysis).
        if [[ -s "${out_dir}/${bmc}.txt" ]]; then
            p0_emit bmc "${bmc}" pass path="${out_dir}/${bmc}.txt" proto="${P0_BMC_PROTOCOL}"
        else
            p0_emit bmc "${bmc}" fail reason=empty_output proto="${P0_BMC_PROTOCOL}"
        fi
    ) &
    pids+=($!)
    slot=$((slot+1))
    if [[ "${slot}" -ge "${P0_FANOUT}" ]]; then
        wait -n
        slot=$((slot-1))
    fi
done
wait

p0_log "bmc_sweep: complete. Raw outputs in ${out_dir}"
echo "${out_dir}" > "${P0_RESULTS}/.bmc_latest"
