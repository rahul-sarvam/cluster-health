#!/usr/bin/env bash
# 11_ufm_snapshot.sh — Test 3.11
# Pull full port-counter snapshot from UFM via REST. Captured at the
# start (baseline) AND end (final) of Phase 3 so the aggregator can
# diff. Looking for:
#   - any port that renegotiated to a lower speed during Phase 3
#   - any port with symbol errors / link-down events / etc.
#
# UFM_HOST must be set; without it we skip cleanly.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../slurm/env.sh
source "${SCRIPT_DIR}/../slurm/env.sh"

CHECK="11_ufm_snapshot"
PHASE="${P3_PHASE:-baseline}"
case "${PHASE}" in baseline|final) ;; *) PHASE=baseline ;; esac

if [[ -z "${UFM_HOST}" ]]; then
    p3_emit "${CHECK}_${PHASE}" skip reason=ufm_host_not_set
    exit 0
fi
if ! command -v curl >/dev/null 2>&1; then
    p3_emit "${CHECK}_${PHASE}" fail reason=curl_missing
    exit 1
fi
if [[ ! -r "${UFM_PASS_FILE}" ]]; then
    p3_emit "${CHECK}_${PHASE}" skip reason=ufm_pass_file_unreadable path="${UFM_PASS_FILE}"
    exit 0
fi

out_dir="${P3_RESULTS}/${CHECK}_${SLURM_JOB_ID}/${PHASE}"
mkdir -p "${out_dir}"

ufm_pass="$(cat "${UFM_PASS_FILE}")"

# UFM REST: GET /ufmRest/resources/ports — every port with its current
# state, speed, width, and counter set.
ports_out="${out_dir}/ports.json"
http_code=$(curl -sS -o "${ports_out}" -w '%{http_code}' \
    -u "${UFM_USER}:${ufm_pass}" \
    "https://${UFM_HOST}/ufmRest/resources/ports" || echo 000)

if [[ "${http_code}" != "200" ]]; then
    p3_emit "${CHECK}_${PHASE}" fail reason=ufm_http_error http_code="${http_code}" out_dir="${out_dir}"
    exit 2
fi

# Also pull links + topology so we can correlate to the physical layout.
curl -sS -u "${UFM_USER}:${ufm_pass}" \
     -o "${out_dir}/links.json" \
     "https://${UFM_HOST}/ufmRest/resources/links" || true
curl -sS -u "${UFM_USER}:${ufm_pass}" \
     -o "${out_dir}/events.json" \
     "https://${UFM_HOST}/ufmRest/app/events?from_date=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%S)" || true

ports_count=0
if command -v jq >/dev/null 2>&1; then
    ports_count=$(jq 'length' "${ports_out}" 2>/dev/null || echo 0)
fi

p3_emit "${CHECK}_${PHASE}" pass phase="${PHASE}" ports_count="${ports_count}" out_dir="${out_dir}"
