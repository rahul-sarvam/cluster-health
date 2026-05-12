#!/usr/bin/env bash
# 01_node_sanity.sh
# Sanity: are 8x B200 visible, ECC on, persistence mode on, MIG off, no XIDs.
set -uo pipefail
source "${QUAL_ROOT}/slurm/env.sh"

# Pull a structured dump of every GPU.
mapfile -t GPU_LINES < <(nvidia-smi --query-gpu=index,name,memory.total,persistence_mode,ecc.mode.current,mig.mode.current,pstate,power.draw \
    --format=csv,noheader,nounits)

count="${#GPU_LINES[@]}"
fail=0
issues=()

if [[ "${count}" -ne "${EXPECTED_GPU_COUNT}" ]]; then
    issues+=("gpu_count=${count}_expected=${EXPECTED_GPU_COUNT}")
    fail=1
fi

for line in "${GPU_LINES[@]}"; do
    IFS=, read -r idx name mem persist ecc mig pstate power <<< "${line}"
    idx="${idx// /}"; name="${name## }"; mem="${mem// /}"
    persist="${persist## }"; ecc="${ecc## }"; mig="${mig## }"

    if [[ "${name}" != "${EXPECTED_GPU_MODEL}"* ]]; then
        issues+=("gpu${idx}_wrong_model=${name}")
        fail=1
    fi
    if [[ "${mem}" -lt $((EXPECTED_GPU_MEM_MIB - 1024)) ]]; then
        issues+=("gpu${idx}_low_mem=${mem}")
        fail=1
    fi
    if [[ "${persist}" != "Enabled" ]]; then
        issues+=("gpu${idx}_persistence_off")
        fail=1
    fi
    if [[ "${ecc}" != "Enabled" ]]; then
        issues+=("gpu${idx}_ecc_off")
        fail=1
    fi
    if [[ "${mig}" != "Disabled" ]]; then
        issues+=("gpu${idx}_mig_on")
        fail=1
    fi
done

# Critical XIDs since boot.
xid_count=$(dmesg | grep -cE 'NVRM: Xid.*: (31|43|45|61|63|64|74|79)' || true)
if [[ "${xid_count}" -gt 0 ]]; then
    issues+=("critical_xid_count=${xid_count}")
    fail=1
fi

# Uncorrectable ECC since boot, aggregated.
unc_ecc=$(nvidia-smi --query-gpu=ecc.errors.uncorrected.aggregate.total --format=csv,noheader,nounits | awk '{s+=$1} END {print s+0}')
if [[ "${unc_ecc}" -gt 0 ]]; then
    issues+=("aggregate_uncorrectable_ecc=${unc_ecc}")
    fail=1
fi

status="pass"; [[ "${fail}" -eq 1 ]] && status="fail"
issues_json="[$(printf '"%s",' "${issues[@]}" | sed 's/,$//')]"
qual_emit node_sanity "${status}" \
    gpu_count="${count}" \
    critical_xid_count="${xid_count}" \
    aggregate_uncorrectable_ecc="${unc_ecc}" \
    issues="${issues_json}"

exit "${fail}"
