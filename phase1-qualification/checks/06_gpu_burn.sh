#!/usr/bin/env bash
# 06_gpu_burn.sh
# 30 minute thermal stress. Catches: bad cooling, bad PSU phase, early
# clock throttling, GPUs that error under sustained FP16 GEMM load.
set -uo pipefail
source "${QUAL_ROOT}/slurm/env.sh"

OUT="${QUAL_LOGS}/$(hostname)_gpu_burn.txt"
TELE="${QUAL_LOGS}/$(hostname)_gpu_burn_telemetry.csv"

# Skip cleanly if gpu-burn isn't installed (e.g. nvcc unavailable so
# bootstrap couldn't build it on this image).
if ! [[ -d "${GPU_BURN_DIR}" && -x "${GPU_BURN_DIR}/gpu_burn" ]]; then
    qual_emit gpu_burn skip reason="gpu_burn_binary_missing" path="${GPU_BURN_DIR}"
    exit 0
fi

# Start telemetry collector in the background, sample every 2s.
(
    echo "ts,gpu,temp_c,power_w,sm_clock_mhz,mem_clock_mhz,pstate,throttle"
    while true; do
        nvidia-smi --query-gpu=timestamp,index,temperature.gpu,power.draw,clocks.sm,clocks.mem,pstate,clocks_event_reasons.hw_thermal_slowdown \
            --format=csv,noheader,nounits 2>/dev/null
        sleep 2
    done
) > "${TELE}" &
TELE_PID=$!

cd "${GPU_BURN_DIR}"
./gpu_burn "${GPU_BURN_SECONDS}" > "${OUT}" 2>&1
burn_rc=$?

kill "${TELE_PID}" 2>/dev/null || true
wait "${TELE_PID}" 2>/dev/null || true

# Parse gpu-burn output: "Faulty GPUs" line or per-GPU summary.
faulty=$(grep -cE 'FAULTY|errors' "${OUT}" || true)

# Inspect telemetry for thermal violations and SBE growth.
max_temp=$(awk -F, 'NR>1 {if($3>m) m=$3} END {print m+0}' "${TELE}")
thermal_throttle=$(awk -F, 'NR>1 && $8 ~ /Active/ {c++} END {print c+0}' "${TELE}")
peak_power=$(awk -F, 'NR>1 {if($4>m) m=$4} END {print m+0}' "${TELE}")

# SBE delta over the burn window.
sbe_before=$(grep -A0 "^before:" "${OUT}" | awk '{print $2}' 2>/dev/null || echo 0)
sbe_after=$(nvidia-smi --query-gpu=ecc.errors.corrected.aggregate.total --format=csv,noheader,nounits | awk '{s+=$1} END {print s+0}')

fail=0
if [[ "${burn_rc}" -ne 0 ]] || [[ "${faulty}" -gt 0 ]]; then
    fail=1
fi
if [[ "${thermal_throttle}" -gt 0 ]]; then
    qual_log "Thermal throttling observed ${thermal_throttle} times during burn"
    fail=1
fi
if awk -v m="${max_temp}" 'BEGIN {exit !(m > 85)}'; then
    qual_log "Max GPU temp ${max_temp}C exceeds soft ceiling 85C"
    fail=1
fi

status="pass"; [[ "${fail}" -eq 1 ]] && status="fail"
qual_emit gpu_burn "${status}" \
    log_path="${OUT}" \
    telemetry_csv="${TELE}" \
    burn_rc="${burn_rc}" \
    faulty_indicators="${faulty}" \
    max_temp_c="${max_temp}" \
    thermal_throttle_events="${thermal_throttle}" \
    peak_power_w="${peak_power}" \
    sbe_after="${sbe_after}"

exit "${fail}"
