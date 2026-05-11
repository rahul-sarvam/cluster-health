#!/usr/bin/env bash
# install.sh — single-file, incremental bootstrap for all phases of the
# cluster health validation work in this repo.
#
# Design principles:
#   * Idempotent: every install step skips if its output is already present.
#   * Phase-scoped: each phase has its own block; new phases append blocks.
#   * Best-effort: a single failure does NOT abort the run. All failures
#     are collected and printed at the end.
#   * Reproducible: source builds use pinned git tags (overridable via env).
#   * Host-agnostic: the same script runs on a management host AND each
#     compute node. Steps that don't apply on a given host (e.g. the
#     source builds need nvcc; the management host may not have CUDA)
#     are gracefully skipped.
#
# Usage:
#   sudo ./install.sh                 # install everything for every phase
#   sudo ./install.sh phase0          # install Phase 0 deps only
#   sudo ./install.sh phase1          # install Phase 1 deps only
#   ./install.sh verify               # check-only mode; doesn't install
#   DRY_RUN=1 ./install.sh            # print the actions, don't execute
#
# Knobs (env vars):
#   INSTALL_PREFIX   default /opt/qualification
#   NVBW_TAG         pinned nvbandwidth tag           (default v0.7)
#   GPUBURN_REF      pinned gpu-burn ref              (default master)
#   NCCL_TESTS_TAG   pinned NVIDIA/nccl-tests tag     (default v2.13.10)
#   BABELSTREAM_TAG  pinned BabelStream tag           (default v5.0)
#
# Exit codes:
#   0  all install/verify steps succeeded (or were skipped)
#   2  one or more steps FAILED — see summary at end
#   3  cannot proceed (e.g. not root and not DRY_RUN)

set -u

MODE="${1:-all}"
DRY_RUN="${DRY_RUN:-0}"

INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/qualification}"
NVBW_TAG="${NVBW_TAG:-v0.7}"
GPUBURN_REF="${GPUBURN_REF:-master}"
NCCL_TESTS_TAG="${NCCL_TESTS_TAG:-v2.13.10}"
BABELSTREAM_TAG="${BABELSTREAM_TAG:-v5.0}"

# ---------------------------------------------------------------------------
# Tracking
# ---------------------------------------------------------------------------
SUMMARY_OK=()
SUMMARY_SKIP=()
SUMMARY_FAIL=()

mark_ok()    { SUMMARY_OK+=("$1");                         echo "  [OK]    $1"; }
mark_skip()  { SUMMARY_SKIP+=("$1");                       echo "  [SKIP]  $1"; }
mark_fail()  { SUMMARY_FAIL+=("$1 — $2");                  echo "  [FAIL]  $1 — $2" >&2; }

section() { echo; echo "=== $* ==="; }

# Run a command, but only if not in dry-run mode.
run() {
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "  [DRY]   $*"
        return 0
    fi
    "$@"
}

# ---------------------------------------------------------------------------
# Helpers — each returns 0 if the resource ended up present, 1 if not.
# ---------------------------------------------------------------------------

# apt: install a Debian/Ubuntu package, idempotent.
apt_pkg() {
    local pkg="$1"
    if dpkg -l "${pkg}" 2>/dev/null | awk 'NR>5 {print $1}' | grep -q '^ii'; then
        mark_skip "apt:${pkg}"
        return 0
    fi
    if [[ "${MODE}" == "verify" ]]; then
        mark_fail "apt:${pkg}" "missing (verify-only)"
        return 1
    fi
    if [[ "${APT_UPDATED:-0}" -eq 0 ]]; then
        run env DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
        APT_UPDATED=1
    fi
    if run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkg}"; then
        mark_ok "apt:${pkg}"
        return 0
    fi
    mark_fail "apt:${pkg}" "apt-get install failed"
    return 1
}

# pip: install a Python package into the system interpreter, idempotent.
# Falls back gracefully on PEP-668 distros (Ubuntu 23.04+).
pip_pkg() {
    local pkg="$1"
    local import_name="${2:-${1//-/_}}"
    if python3 -c "import ${import_name}" >/dev/null 2>&1; then
        mark_skip "pip:${pkg}"
        return 0
    fi
    if [[ "${MODE}" == "verify" ]]; then
        mark_fail "pip:${pkg}" "missing (verify-only)"
        return 1
    fi
    if run python3 -m pip install --quiet --break-system-packages "${pkg}" 2>/dev/null \
            || run python3 -m pip install --quiet "${pkg}"; then
        mark_ok "pip:${pkg}"
        return 0
    fi
    mark_fail "pip:${pkg}" "pip install failed"
    return 1
}

# vendor: verify a vendor-supplied component is present, never installs.
# We deliberately do NOT auto-install drivers, OFED, CUDA, DCGM, fabric
# manager — those come from vendor channels and require coordinated installs.
vendor_check() {
    local label="$1"
    local cmd="$2"
    local hint="$3"
    if command -v "${cmd}" >/dev/null 2>&1; then
        mark_skip "vendor:${label} (${cmd} present)"
        return 0
    fi
    mark_fail "vendor:${label}" "${cmd} not found — ${hint}"
    return 1
}

# build_from_source: clone, build, install a tool from upstream source.
# Skips if the output_file already exists.
build_from_source() {
    local name="$1"
    local repo="$2"
    local ref="$3"
    local output_file="$4"
    local build_cmd="$5"

    if [[ -e "${output_file}" ]]; then
        mark_skip "build:${name} (exists at ${output_file})"
        return 0
    fi
    if [[ "${MODE}" == "verify" ]]; then
        mark_fail "build:${name}" "missing at ${output_file} (verify-only)"
        return 1
    fi

    local src_dir="${INSTALL_PREFIX}/src/${name}"
    if [[ ! -d "${src_dir}/.git" ]]; then
        rm -rf "${src_dir}"
        if ! run git clone --depth 1 --branch "${ref}" "${repo}" "${src_dir}"; then
            mark_fail "build:${name}" "git clone ${repo}@${ref} failed"
            return 1
        fi
    else
        ( cd "${src_dir}" && run git fetch --depth 1 origin "${ref}" 2>/dev/null \
                          && run git checkout -q "${ref}" 2>/dev/null ) || true
    fi

    if ( cd "${src_dir}" && eval "${build_cmd}" ); then
        if [[ -e "${output_file}" ]]; then
            mark_ok "build:${name} -> ${output_file}"
            return 0
        fi
        mark_fail "build:${name}" "build claimed success but ${output_file} missing"
        return 1
    fi
    mark_fail "build:${name}" "build command failed"
    return 1
}

# ---------------------------------------------------------------------------
# Pre-flight: privilege check (skipped in verify / dry-run).
# ---------------------------------------------------------------------------
if [[ "${MODE}" != "verify" && "${DRY_RUN}" -ne 1 && "${EUID}" -ne 0 ]]; then
    echo "ERROR: must run as root (or set DRY_RUN=1, or use 'verify' mode)" >&2
    exit 3
fi

mkdir -p "${INSTALL_PREFIX}/bin" "${INSTALL_PREFIX}/src" 2>/dev/null || true

echo "install.sh: mode=${MODE} dry_run=${DRY_RUN} prefix=${INSTALL_PREFIX}"

# ---------------------------------------------------------------------------
# Phase 0 — Pre-Commission
# ---------------------------------------------------------------------------
install_phase0() {
    section "Phase 0 — Pre-Commission"

    # System packages — apt covers all of these.
    apt_pkg infiniband-diags        # ibnetdiscover, iblinkinfo, ibdiagnet, ibstat
    apt_pkg ipmitool                # BMC reachability (default protocol)
    apt_pkg curl                    # Redfish protocol path
    apt_pkg dmidecode               # firmware_baseline reads bios fields
    apt_pkg python3
    apt_pkg python3-pip
    apt_pkg openssh-client          # for the SSH fan-out

    # Python — pyyaml is optional (aggregators have a fallback parser) but nicer.
    pip_pkg pyyaml yaml

    # Vendor stack — must already be installed via vendor channels.
    vendor_check "MLNX_OFED (ibstat)"           ibstat \
        "install MLNX_OFED: https://network.nvidia.com/products/infiniband-drivers/linux/mlnx_ofed/"
    vendor_check "MLNX_OFED (mlxlink)"          mlxlink \
        "ships with MLNX_OFED"
    vendor_check "MLNX_OFED (mlxfwmanager)"     mlxfwmanager \
        "ships with MLNX_OFED"
    vendor_check "MLNX_OFED (mst)"              mst \
        "ships with MLNX_OFED"
    vendor_check "NVIDIA driver"                nvidia-smi \
        "install via NVIDIA driver repo or DGX image"
    vendor_check "CUDA toolkit (nvcc)"          nvcc \
        "install via NVIDIA cuda-toolkit-12-x apt package"
    vendor_check "Fabric Manager"               nv-fabricmanager \
        "install nvidia-fabricmanager-XXX apt package"
}

# ---------------------------------------------------------------------------
# Phase 1 — Per-Node Qualification Gate
# ---------------------------------------------------------------------------
install_phase1() {
    section "Phase 1 — Per-Node Qualification Gate"

    # Build toolchain for the source builds below.
    apt_pkg build-essential
    apt_pkg cmake
    apt_pkg git
    apt_pkg pkg-config

    # System tools used by check scripts 1.1, 1.8, 1.9, 1.10.
    apt_pkg perftest                # ib_write_bw, ib_write_lat
    apt_pkg numactl                 # 10_host_health
    apt_pkg nvme-cli                # 10_host_health
    apt_pkg chrony                  # 10_host_health PTP/NTP probe
    apt_pkg linux-tools-common      # turbostat, perf — handy for debug

    # Python deps for the aggregator pipeline.
    pip_pkg pandas
    pip_pkg pyarrow
    pip_pkg numpy

    # Vendor checks.
    vendor_check "DCGM (dcgmi)"     dcgmi \
        "install datacenter-gpu-manager apt package"
    vendor_check "OpenMPI (mpirun)" mpirun \
        "apt: openmpi-bin libopenmpi-dev OR HPC-X from MLNX_OFED"

    # Source builds — need nvcc; if missing, skip the whole block.
    if ! command -v nvcc >/dev/null 2>&1; then
        mark_fail "build:phase1-workloads" "nvcc missing — skipping all source builds"
        return 0
    fi

    local cuda_home
    cuda_home="$(dirname "$(dirname "$(command -v nvcc)")")"
    local jobs
    jobs="$(nproc 2>/dev/null || echo 4)"

    # 1. nvbandwidth ---------------------------------------------------------
    build_from_source nvbandwidth \
        "https://github.com/NVIDIA/nvbandwidth.git" "${NVBW_TAG}" \
        "${INSTALL_PREFIX}/bin/nvbandwidth" \
        "cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
             && cmake --build build -j${jobs} \
             && install -m 0755 build/nvbandwidth ${INSTALL_PREFIX}/bin/nvbandwidth"

    # 2. gpu-burn ------------------------------------------------------------
    build_from_source gpu-burn \
        "https://github.com/wilicc/gpu-burn.git" "${GPUBURN_REF}" \
        "${INSTALL_PREFIX}/gpu-burn/gpu_burn" \
        "make CUDAPATH=${cuda_home} -j${jobs} \
             && mkdir -p ${INSTALL_PREFIX}/gpu-burn \
             && install -m 0755 gpu_burn ${INSTALL_PREFIX}/gpu-burn/gpu_burn \
             && install -m 0644 compare.ptx ${INSTALL_PREFIX}/gpu-burn/compare.ptx"

    # 3. nccl-tests ----------------------------------------------------------
    # Build with MPI if mpicc is present; without otherwise. NCCL paths are
    # auto-detected by the Makefile.
    local mpi_flag
    if command -v mpicc >/dev/null 2>&1; then mpi_flag="MPI=1"; else mpi_flag="MPI=0"; fi
    build_from_source nccl-tests \
        "https://github.com/NVIDIA/nccl-tests.git" "${NCCL_TESTS_TAG}" \
        "${INSTALL_PREFIX}/nccl-tests/build/all_reduce_perf" \
        "make ${mpi_flag} CUDA_HOME=${cuda_home} -j${jobs} \
             && mkdir -p ${INSTALL_PREFIX}/nccl-tests/build \
             && cp build/*_perf ${INSTALL_PREFIX}/nccl-tests/build/"

    # 4. BabelStream (cuda-stream) ------------------------------------------
    build_from_source BabelStream \
        "https://github.com/UoB-HPC/BabelStream.git" "${BABELSTREAM_TAG}" \
        "${INSTALL_PREFIX}/bin/cuda-stream" \
        "cmake -S . -B build -DMODEL=cuda -DCMAKE_CUDA_COMPILER=${cuda_home}/bin/nvcc \
             && cmake --build build -j${jobs} \
             && install -m 0755 build/cuda-stream ${INSTALL_PREFIX}/bin/cuda-stream"
}

# ---------------------------------------------------------------------------
# Future phases — placeholder. Each new phase appends an install_phaseN()
# function plus a case-arm in the dispatcher below.
# ---------------------------------------------------------------------------
# install_phase2() { ... }
# install_phase3() { ... }

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${MODE}" in
    all|verify)
        install_phase0
        install_phase1
        ;;
    phase0) install_phase0 ;;
    phase1) install_phase1 ;;
    *)
        echo "Unknown mode: ${MODE}" >&2
        echo "Usage: $0 [all|phase0|phase1|verify]   (DRY_RUN=1 supported)" >&2
        exit 64
        ;;
esac

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
echo
echo "================================================================"
echo "  install.sh summary"
echo "================================================================"
printf "  installed  : %d\n" "${#SUMMARY_OK[@]}"
printf "  skipped    : %d (already present or verify-only)\n" "${#SUMMARY_SKIP[@]}"
printf "  failed     : %d\n" "${#SUMMARY_FAIL[@]}"
if [[ "${#SUMMARY_FAIL[@]}" -gt 0 ]]; then
    echo
    echo "  FAILURES:"
    for f in "${SUMMARY_FAIL[@]}"; do
        echo "    - ${f}"
    done
    echo
    echo "Resolve the items above and re-run; install.sh is idempotent and"
    echo "will skip whatever is already in place."
    exit 2
fi
echo
echo "All required items are in place."
