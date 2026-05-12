#!/usr/bin/env bash
# 02_firmware_inventory.sh
# Capture every relevant version. Compare against pins in env.sh.
# We do NOT fail on a mismatch here — we emit and let the aggregator decide,
# because what matters most is that all 128 nodes are IDENTICAL.
set -uo pipefail
source "${QUAL_ROOT}/slurm/env.sh"

driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 | tr -d ' ')
cuda=$(nvcc --version 2>/dev/null | grep -oE 'release [0-9]+\.[0-9]+' | awk '{print $2}')
nccl_h="/usr/include/nccl.h"
nccl_ver="unknown"
if [[ -f "${nccl_h}" ]]; then
    maj=$(grep '#define NCCL_MAJOR' "${nccl_h}" | awk '{print $3}')
    min=$(grep '#define NCCL_MINOR' "${nccl_h}" | awk '{print $3}')
    pat=$(grep '#define NCCL_PATCH' "${nccl_h}" | awk '{print $3}')
    nccl_ver="${maj}.${min}.${pat}"
fi
fm_ver=$(nv-fabricmanager --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
ofed_ver=$(ofed_info -s 2>/dev/null | tr -d ':')
bios_ver=$(dmidecode -s bios-version 2>/dev/null || echo "unknown")
bmc_ver=$(ipmitool mc info 2>/dev/null | awk -F: '/Firmware Revision/ {gsub(/ /,"",$2); print $2}')
kernel=$(uname -r)

# Per-NIC firmware
nic_fw=$(ibstat 2>/dev/null | awk '/^CA / {ca=$2; gsub(/\047/,"",ca)} /Firmware version/ {gsub(/ /,"",$3); print ca"="$3}' | paste -sd, -)
nic_count=$(ibstat -l 2>/dev/null | wc -l)

# Determine match
mismatch=0
issues=()
[[ "${driver}" != "${EXPECTED_DRIVER_VERSION}" && "${EXPECTED_DRIVER_VERSION}" != "TODO_FILL_AT_BURNIN" ]] && { issues+=("driver=${driver}"); mismatch=1; }
[[ "${cuda}" != "${EXPECTED_CUDA_VERSION}" ]] && { issues+=("cuda=${cuda}"); mismatch=1; }
[[ "${nccl_ver}" != "${EXPECTED_NCCL_VERSION}" ]] && { issues+=("nccl=${nccl_ver}"); mismatch=1; }
[[ "${nic_count}" -ne "${EXPECTED_NIC_COUNT}" ]] && { issues+=("nic_count=${nic_count}"); mismatch=1; }

status="pass"; [[ "${mismatch}" -eq 1 ]] && status="warn"
issues_json="[$(printf '"%s",' "${issues[@]}" | sed 's/,$//')]"

qual_emit firmware_inventory "${status}" \
    driver="${driver}" \
    cuda="${cuda}" \
    nccl="${nccl_ver}" \
    fm="${fm_ver}" \
    ofed="${ofed_ver}" \
    bios="${bios_ver}" \
    bmc="${bmc_ver}" \
    kernel="${kernel}" \
    nic_count="${nic_count}" \
    nic_fw="${nic_fw}" \
    issues="${issues_json}"

# Don't fail the gate on a firmware skew — aggregator handles cohort comparison.
exit 0
