#!/usr/bin/env bash
# run_all.sh - run every phase-0 sweep end-to-end, then render the markdown report.
#
# Usage:
#   ./run_all.sh                 # run all three sweeps and aggregate
#   ./run_all.sh firmware        # run only firmware baseline + diff
#   ./run_all.sh cables          # run only cable inventory + validate
#   ./run_all.sh bmc             # run only BMC sweep + summary
#   ./run_all.sh report          # render markdown report from existing JSONs
#
# Exit code:
#   0 - everything PASS
#   1 - one or more sweeps had transport-level failure (couldn't reach a node)
#   2 - one or more checks FAILed an inspection rule
#   3 - mixed: some transport failures AND some inspection failures

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

phase="${1:-all}"
rc_firmware=0
rc_cables=0
rc_bmc=0

run_firmware() {
    p0_log "run_all: firmware phase"
    bash "${SCRIPT_DIR}/firmware_baseline.sh" || rc_firmware=$?
    python3 "${SCRIPT_DIR}/aggregate/firmware_diff.py" || rc_firmware=$?
}

run_cables() {
    p0_log "run_all: cables phase"
    bash "${SCRIPT_DIR}/cable_inventory.sh" || rc_cables=$?
    python3 "${SCRIPT_DIR}/aggregate/cable_validate.py" || rc_cables=$?
}

run_bmc() {
    p0_log "run_all: bmc phase"
    bash "${SCRIPT_DIR}/bmc_sweep.sh" || rc_bmc=$?
    python3 "${SCRIPT_DIR}/aggregate/bmc_summary.py" || rc_bmc=$?
}

run_report() {
    p0_log "run_all: rendering report"
    python3 "${SCRIPT_DIR}/aggregate/report.py"
}

case "${phase}" in
    firmware) run_firmware ;;
    cables)   run_cables ;;
    bmc)      run_bmc ;;
    report)   run_report; exit $? ;;
    all|"")
        run_firmware
        run_cables
        run_bmc
        run_report
        ;;
    *)
        echo "Unknown phase: ${phase}" >&2
        echo "Usage: $0 [firmware|cables|bmc|report|all]" >&2
        exit 64
        ;;
esac

# Roll up the three exit codes into a single one.
combined=0
if [[ "${rc_firmware}" -ne 0 || "${rc_cables}" -ne 0 || "${rc_bmc}" -ne 0 ]]; then
    # Differentiate transport (rc=1) from inspection (rc=2).
    has_transport=0; has_inspect=0
    for rc in "${rc_firmware}" "${rc_cables}" "${rc_bmc}"; do
        case "${rc}" in
            0) ;;
            2) has_inspect=1 ;;
            *) has_transport=1 ;;
        esac
    done
    if [[ "${has_transport}" -eq 1 && "${has_inspect}" -eq 1 ]]; then combined=3
    elif [[ "${has_inspect}" -eq 1 ]]; then combined=2
    else combined=1
    fi
fi

p0_log "run_all: done (combined exit=${combined})"
exit "${combined}"
