#!/usr/bin/env bash
# Shared environment for the Phase 0 pre-commission sweeps.
# Source this from every sweep script and from run_all.sh.
#
# Phase 0 runs BEFORE the cluster is signed off. Scripts here are strictly
# read-only — they query firmware, cable telemetry, and BMCs from a
# management host. Nothing is reconfigured. The goal is to catch vendor-side
# setup mistakes (mismatched firmware, miswired cables, unreachable BMCs)
# before anyone spends a day on benchmarks.

set -u

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
export P0_ROOT="${P0_ROOT:-/opt/qualification/phase0}"
export P0_RESULTS="${P0_RESULTS:-${P0_ROOT}/results}"
export P0_LOGS="${P0_LOGS:-${P0_ROOT}/logs}"
export P0_REF="${P0_REF:-${P0_ROOT}/reference}"
mkdir -p "${P0_RESULTS}" "${P0_LOGS}"

# Node and switch inventory. These files MUST exist before any sweep runs.
#   nodes.txt          - one compute hostname per line (128 lines for a 128-node cluster)
#   bmc_hosts.txt      - one BMC address (or hostname) per line, same order as nodes.txt
#   ib_switches.txt    - one IB leaf/spine switch IP per line (optional - mlxlink falls back to host-side)
export P0_NODES="${P0_NODES:-${P0_ROOT}/nodes.txt}"
export P0_BMCS="${P0_BMCS:-${P0_ROOT}/bmc_hosts.txt}"
export P0_IBSW="${P0_IBSW:-${P0_ROOT}/ib_switches.txt}"

# Reference manifests (vendor-provided or filled in at burn-in).
export P0_EXPECTED_FIRMWARE="${P0_EXPECTED_FIRMWARE:-${P0_REF}/expected_firmware.yaml}"
export P0_EXPECTED_TOPOLOGY="${P0_EXPECTED_TOPOLOGY:-${P0_REF}/expected_topology.yaml}"

# -----------------------------------------------------------------------------
# SSH / parallel fanout
# -----------------------------------------------------------------------------
# Use a non-interactive SSH key. Connection multiplexing speeds up large sweeps.
export P0_SSH_USER="${P0_SSH_USER:-root}"
export P0_SSH_OPTS="${P0_SSH_OPTS:--o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${P0_LOGS}/known_hosts}"
# Parallelism for fan-out sweeps. 32 is conservative for a 128-node cluster.
export P0_FANOUT="${P0_FANOUT:-32}"

# -----------------------------------------------------------------------------
# IPMI / Redfish credentials
# -----------------------------------------------------------------------------
# These should come from a secrets manager in production. The defaults here
# are placeholders only - the script will refuse to run if they are unchanged.
export P0_IPMI_USER="${P0_IPMI_USER:-TODO_FILL}"
export P0_IPMI_PASS="${P0_IPMI_PASS:-TODO_FILL}"
# Set to "ipmitool" or "redfish". Redfish is preferred when the BMC supports it.
export P0_BMC_PROTOCOL="${P0_BMC_PROTOCOL:-ipmitool}"

# -----------------------------------------------------------------------------
# Expected hardware pins (cross-checked against vendor manifest).
# -----------------------------------------------------------------------------
export EXPECTED_NODE_COUNT=128
export EXPECTED_GPUS_PER_NODE=8
export EXPECTED_NICS_PER_NODE=8
export EXPECTED_IB_LINK_SPEED="NDR"
export EXPECTED_IB_LINK_WIDTH="4x"
# Each leaf typically lands 8 hosts; 128 hosts => 16 leaves.
export EXPECTED_LEAF_COUNT=16
export EXPECTED_SPINE_COUNT=8

# -----------------------------------------------------------------------------
# Pass / warn thresholds
# -----------------------------------------------------------------------------
# Firmware drift: any node whose firmware tuple differs from the cohort
# majority across more than this many components is flagged FAIL.
export FIRMWARE_DRIFT_MAX_COMPONENTS=0      # zero tolerance for firmware drift
# BMC sweep: how many sensors are allowed to be in non-OK state before flagging.
export BMC_BAD_SENSOR_MAX=0
# BMC SEL: any critical entry within the last 24h fails the node.
export BMC_SEL_WINDOW_HOURS=24
# IB cable: minimum acceptable LinkSpeed string (anything below NDR fails).
export IB_LINK_SPEED_REQUIRED="NDR"
# IB port: ports below this width fail.
export IB_LINK_WIDTH_REQUIRED="4x"

# -----------------------------------------------------------------------------
# Helper: emit a structured JSON fragment for one host x check.
# Usage: p0_emit <check_name> <host> <status: pass|fail|warn> <key=value> [k=v ...]
# -----------------------------------------------------------------------------
p0_emit() {
    local check="$1"; shift
    local host="$1"; shift
    local status="$1"; shift
    local out="${P0_RESULTS}/${host}_${check}.json"
    {
        printf '{"check":"%s","host":"%s","status":"%s","ts":"%s"' \
            "${check}" "${host}" "${status}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        for kv in "$@"; do
            local k="${kv%%=*}"
            local v="${kv#*=}"
            if [[ "${v}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || [[ "${v}" =~ ^(true|false|null|\[|\{) ]]; then
                printf ',"%s":%s' "${k}" "${v}"
            else
                printf ',"%s":"%s"' "${k}" "${v}"
            fi
        done
        printf '}\n'
    } > "${out}"
}

p0_log() {
    echo "[$(date -u +%H:%M:%S)] $*" | tee -a "${P0_LOGS}/run.log"
}

# Refuse to run with placeholder credentials.
p0_check_credentials() {
    if [[ "${P0_IPMI_USER}" == "TODO_FILL" || "${P0_IPMI_PASS}" == "TODO_FILL" ]]; then
        echo "ERROR: P0_IPMI_USER / P0_IPMI_PASS not set. Edit env.sh or export before running." >&2
        return 1
    fi
}

# Resolve the node list; refuse if missing.
p0_require_nodes() {
    if [[ ! -s "${P0_NODES}" ]]; then
        echo "ERROR: ${P0_NODES} does not exist or is empty. Populate one hostname per line." >&2
        return 1
    fi
}
