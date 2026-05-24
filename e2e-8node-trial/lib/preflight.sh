#!/usr/bin/env bash
# Pre-flight discovery from the login node.
#
# Captures everything we need to know about the cluster's surface from
# the login node, before we burn any compute. Writes a structured JSON
# fragment plus a free-form .txt log. Failures here halt the run — if
# Slurm or the shared FS is broken, there's no point launching phases.

set -uo pipefail

: "${E2E_RUN_DIR:?E2E_RUN_DIR must be set}"
PRE="${E2E_RUN_DIR}/preflight"
mkdir -p "${PRE}"

# Free-form transcript of every command we ran.
LOG="${PRE}/preflight.log"
JSON="${PRE}/preflight.json"

emit() { echo "[preflight $(date -u +%H:%M:%S)] $*" | tee -a "${LOG}"; }
run()  { emit "\$ $*"; "$@" 2>&1 | tee -a "${LOG}"; }

# -----------------------------------------------------------------------------
# 1. Identity & basic environment
# -----------------------------------------------------------------------------
emit "=== identity ==="
run id
run hostname
run uname -a
run cat /etc/os-release 2>/dev/null || true

# -----------------------------------------------------------------------------
# 2. Slurm reachability and partition info
# -----------------------------------------------------------------------------
emit "=== slurm ==="
if ! command -v sinfo >/dev/null 2>&1; then
    emit "FATAL: sinfo not found on PATH; is this really a Slurm login node?"
    echo '{"check":"preflight_slurm","status":"fail","reason":"sinfo_missing"}' > "${JSON}"
    exit 1
fi
run sinfo --version
run sinfo -h -N -o "%N %P %C %D %T %f"
run sinfo -h -o "%R"
run scontrol show config 2>&1 | head -40

# Discover a partition if E2E_PARTITION is not set.
if [[ -z "${E2E_PARTITION:-}" ]]; then
    # Prefer the default partition (marked with * in PARTITION column).
    E2E_PARTITION="$(sinfo -h -o "%R %P" | awk '/\*$/{gsub(/\*/,"",$2); print $2; exit}')"
    # Fallback: first listed.
    if [[ -z "${E2E_PARTITION}" ]]; then
        E2E_PARTITION="$(sinfo -h -o "%R" | head -1)"
    fi
    emit "auto-detected partition: ${E2E_PARTITION}"
    export E2E_PARTITION
fi

# Record the per-partition state we'll be using.
run sinfo -p "${E2E_PARTITION}" -h -N -o "%N %C %m %G %T"

# Topology (Slinky may or may not populate this).
run scontrol show topology 2>&1 | head -40 || true

# Save the canonical node list for this partition.
NODELIST="$(sinfo -p "${E2E_PARTITION}" -h -N -o '%N' | sort -u | paste -sd,)"
echo "${NODELIST}" > "${PRE}/nodelist.txt"
NCOUNT="$(sinfo -p "${E2E_PARTITION}" -h -N -o '%N' | sort -u | wc -l)"
emit "partition=${E2E_PARTITION} node_count=${NCOUNT} nodelist=${NODELIST}"

if [[ "${NCOUNT}" -lt "${E2E_NODE_COUNT}" ]]; then
    emit "WARNING: expected ${E2E_NODE_COUNT} nodes, partition has ${NCOUNT}"
fi

# -----------------------------------------------------------------------------
# 3. Shared filesystem check
# -----------------------------------------------------------------------------
# We need E2E_RUN_DIR to be readable+writable from every compute node.
# If $HOME is not shared, srun jobs can't see our results. Probe by
# writing a token here on the login node, then srun a small step on
# every node and confirm they can read+write the same path.
emit "=== shared fs probe ==="
TOKEN="$(date -u +%s)-$$"
TOKEN_FILE="${PRE}/shared_token.${TOKEN}"
echo "login-side wrote at $(date -u +%FT%TZ)" > "${TOKEN_FILE}"

# Quick mount survey on the login node.
run mount | grep -vE 'type (tmpfs|devtmpfs|proc|sysfs|cgroup|fuse|squashfs|overlay|autofs|debugfs|tracefs|securityfs|pstore|configfs|mqueue|bpf|hugetlbfs|fusectl|binfmt_misc)'
run df -h "${E2E_RUN_DIR}"

# Fan out to every compute node and read+write the same path.
if srun -p "${E2E_PARTITION}" -N "${E2E_NODE_COUNT}" --ntasks-per-node=1 \
        --output="${PRE}/shared_fs_probe.%N.out" \
        --error="${PRE}/shared_fs_probe.%N.err" \
        --time=00:02:00 \
        bash -c "
            if [[ ! -r '${TOKEN_FILE}' ]]; then
                echo 'NOT_READABLE on \$(hostname)'; exit 2
            fi
            head -1 '${TOKEN_FILE}'
            echo \"compute-side \$(hostname) wrote at \$(date -u +%FT%TZ)\" >> '${PRE}/shared_token_writeback.\$(hostname).txt'
        " >>"${LOG}" 2>&1; then
    emit "shared fs OK on all ${E2E_NODE_COUNT} nodes"
    SHARED_FS_OK=1
else
    emit "shared fs probe FAILED — compute nodes cannot see ${E2E_RUN_DIR}"
    SHARED_FS_OK=0
fi

# Count the writebacks we got.
WRITEBACK_COUNT="$(ls "${PRE}"/shared_token_writeback.*.txt 2>/dev/null | wc -l)"
emit "writebacks received: ${WRITEBACK_COUNT}/${E2E_NODE_COUNT}"

# -----------------------------------------------------------------------------
# 4. GPU / IB / driver visibility from a compute node (single-node probe)
# -----------------------------------------------------------------------------
emit "=== compute-node probe (single node) ==="
srun -p "${E2E_PARTITION}" -N 1 --ntasks-per-node=1 \
     --gpus-per-node=8 --time=00:05:00 \
     --output="${PRE}/compute_probe.out" \
     --error="${PRE}/compute_probe.err" \
     bash -c '
        echo "=== hostname ==="; hostname
        echo "=== nvidia-smi -L ==="; nvidia-smi -L 2>&1 || echo "nvidia-smi missing"
        echo "=== nvidia-smi --query-gpu (one-line) ==="
        nvidia-smi --query-gpu=index,name,driver_version,vbios_version,memory.total --format=csv,noheader 2>&1 || true
        echo "=== nvcc --version ==="; nvcc --version 2>&1 || echo "nvcc missing"
        echo "=== ofed_info -n ==="; ofed_info -n 2>&1 || echo "ofed_info missing"
        echo "=== ibstat -s ==="; ibstat 2>&1 | head -20 || echo "ibstat missing"
        echo "=== dpkg -l libnccl2 ==="; dpkg -l libnccl2 2>&1 | tail -3 || echo "libnccl2 missing"
        echo "=== fabricmanager ==="; systemctl is-active nvidia-fabricmanager 2>&1 || true
        echo "=== peermem ==="; lsmod | grep nvidia_peermem 2>&1 || echo "peermem not loaded"
        echo "=== mount (head) ==="; mount | head -20
        echo "=== shared probe readable? ==="; ls -la "'"${TOKEN_FILE}"'" 2>&1
     ' >>"${LOG}" 2>&1 || emit "compute-node probe rc=$?"

# -----------------------------------------------------------------------------
# 5. Emit structured summary
# -----------------------------------------------------------------------------
cat > "${JSON}" <<EOF
{
  "check": "preflight",
  "status": "$( [[ "${SHARED_FS_OK}" -eq 1 && "${NCOUNT}" -ge "${E2E_NODE_COUNT}" ]] && echo pass || echo warn )",
  "ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "partition": "${E2E_PARTITION}",
  "nodelist": "${NODELIST}",
  "expected_node_count": ${E2E_NODE_COUNT},
  "observed_node_count": ${NCOUNT},
  "shared_fs_ok": $( [[ "${SHARED_FS_OK}" -eq 1 ]] && echo true || echo false ),
  "writeback_count": ${WRITEBACK_COUNT},
  "run_dir": "${E2E_RUN_DIR}"
}
EOF

# Persist the partition for downstream sbatch jobs (sourcable).
cat > "${PRE}/discovered.env" <<EOF
export E2E_PARTITION="${E2E_PARTITION}"
export E2E_NODELIST="${NODELIST}"
export E2E_OBSERVED_NODE_COUNT="${NCOUNT}"
EOF

emit "preflight complete; summary at ${JSON}"
[[ "${SHARED_FS_OK}" -eq 1 ]]
