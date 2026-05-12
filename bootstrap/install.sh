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
#   OSU_TAG          pinned OSU Micro-Benchmarks tag  (default 7.4)
#   HPCSDK_DIR       NVIDIA HPC SDK root (default /opt/nvidia/hpc_sdk/Linux_x86_64/24.5)
#   HPL_BIN          path to xhpl       (default ${INSTALL_PREFIX}/hpl/bin/xhpl)
#   HPL_MXP_BIN      path to xhpl_mxp   (default ${INSTALL_PREFIX}/hpl-mxp/bin/xhpl_mxp)
#   HPCG_BIN         path to xhpcg      (default ${INSTALL_PREFIX}/hpcg/bin/xhpcg)
#   LLMB_RUN         path to llmb-run   (default llmb-run on PATH)
#   IOR_TAG          pinned hpc/ior tag (default 4.0.0)
#   ELBENCHO_TAG     pinned breuner/elbencho tag (default v3.0-11)
#   IOR_BIN          path to ior        (default ${INSTALL_PREFIX}/ior/bin/ior)
#   MDTEST_BIN       path to mdtest     (default ${INSTALL_PREFIX}/ior/bin/mdtest)
#   ELBENCHO_BIN     path to elbencho   (default ${INSTALL_PREFIX}/bin/elbencho)
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
OSU_TAG="${OSU_TAG:-7.4}"
HPCSDK_DIR="${HPCSDK_DIR:-/opt/nvidia/hpc_sdk/Linux_x86_64/24.5}"

# Phase 3 — paths to the NVIDIA HPC Benchmarks suite (xhpl, xhpl_mxp, xhpcg).
# These ship with the NVIDIA HPC Benchmarks container and are not auto-built
# by this script. Override if the operator extracted them somewhere else.
HPL_BIN="${HPL_BIN:-${INSTALL_PREFIX}/hpl/bin/xhpl}"
HPL_MXP_BIN="${HPL_MXP_BIN:-${INSTALL_PREFIX}/hpl-mxp/bin/xhpl_mxp}"
HPCG_BIN="${HPCG_BIN:-${INSTALL_PREFIX}/hpcg/bin/xhpcg}"
LLMB_RUN="${LLMB_RUN:-llmb-run}"

# Phase 4 — storage benchmarks. IOR + mdtest come from one repo (we build
# both from a single source tree). elbencho is a separate build. fio and
# MLPerf Storage are apt / pip respectively.
IOR_TAG="${IOR_TAG:-4.0.0}"
ELBENCHO_TAG="${ELBENCHO_TAG:-v3.0-11}"
IOR_BIN="${IOR_BIN:-${INSTALL_PREFIX}/ior/bin/ior}"
MDTEST_BIN="${MDTEST_BIN:-${INSTALL_PREFIX}/ior/bin/mdtest}"
ELBENCHO_BIN="${ELBENCHO_BIN:-${INSTALL_PREFIX}/bin/elbencho}"

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
# Phase 2 — Intra-Rack Scale
# ---------------------------------------------------------------------------
install_phase2() {
    section "Phase 2 — Intra-Rack Scale"

    # ClusterKit ships inside NVIDIA HPC SDK. We don't auto-install HPC
    # SDK (it's a multi-GB vendor package on its own channel); we just
    # confirm the binary is reachable. If absent, Phase 2's ClusterKit
    # check (04) will skip cleanly — it's not a hard requirement.
    local ck_bin="${HPCSDK_DIR}/comm_libs/clusterkit/bin/clusterkit"
    if [[ -x "${ck_bin}" ]]; then
        mark_skip "vendor:ClusterKit (${ck_bin} present)"
    else
        mark_fail "vendor:ClusterKit" \
            "${ck_bin} not found — install NVIDIA HPC SDK from https://developer.nvidia.com/hpc-sdk (or override HPCSDK_DIR)"
    fi

    # Phase 2 also leans on nccl-tests (already built in Phase 1) and
    # MPI (already verified in Phase 1). The remaining new piece is OSU
    # Micro-Benchmarks for the cross-library sanity check (test 2.5).
    if ! command -v nvcc >/dev/null 2>&1; then
        mark_fail "build:osu-micro-benchmarks" "nvcc missing — skipping OSU build"
        return 0
    fi
    if ! command -v mpicc >/dev/null 2>&1; then
        mark_fail "build:osu-micro-benchmarks" "mpicc missing — skipping OSU build"
        return 0
    fi

    local cuda_home
    cuda_home="$(dirname "$(dirname "$(command -v nvcc)")")"
    local jobs
    jobs="$(nproc 2>/dev/null || echo 4)"

    # OSU Micro-Benchmarks ships as a tarball from MVAPICH (no git).
    # Build with CUDA + MPI, install into ${INSTALL_PREFIX}/osu.
    local osu_target="${INSTALL_PREFIX}/osu/libexec/osu-micro-benchmarks/mpi/collective/osu_allreduce"
    if [[ -e "${osu_target}" ]]; then
        mark_skip "build:osu-micro-benchmarks (exists at ${osu_target})"
        return 0
    fi
    if [[ "${MODE}" == "verify" ]]; then
        mark_fail "build:osu-micro-benchmarks" "missing at ${osu_target} (verify-only)"
        return 0
    fi
    local osu_src="${INSTALL_PREFIX}/src/osu-micro-benchmarks-${OSU_TAG}"
    local osu_tar="${INSTALL_PREFIX}/src/osu-micro-benchmarks-${OSU_TAG}.tar.gz"
    local osu_url="https://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-${OSU_TAG}.tar.gz"
    if [[ ! -d "${osu_src}" ]]; then
        run curl -fSL --retry 3 -o "${osu_tar}" "${osu_url}" \
            && run tar -xzf "${osu_tar}" -C "${INSTALL_PREFIX}/src/" \
            || { mark_fail "build:osu-micro-benchmarks" "download/extract failed (${osu_url})"; return 0; }
    fi
    if ( cd "${osu_src}" \
            && run ./configure --prefix="${INSTALL_PREFIX}/osu" --enable-cuda \
                               --with-cuda="${cuda_home}" CC=mpicc CXX=mpicxx \
            && run make -j"${jobs}" \
            && run make install ); then
        if [[ -e "${osu_target}" ]]; then
            mark_ok "build:osu-micro-benchmarks -> ${osu_target}"
        else
            mark_fail "build:osu-micro-benchmarks" "build claimed success but ${osu_target} missing"
        fi
    else
        mark_fail "build:osu-micro-benchmarks" "configure/make failed"
    fi
}

# ---------------------------------------------------------------------------
# Phase 3 — Cross-Spine / Full-Scale
# ---------------------------------------------------------------------------
# Phase 3 adds three NVIDIA HPC Benchmarks (HPL FP64, HPL-MxP, HPCG), the
# DGXC `llmb-run` wrapper, and `jq` (used by the UFM-REST snapshot check to
# count ports). All of HPL/HPCG/llmb-run ship as vendor-supplied artifacts
# (typically inside the NVIDIA HPC Benchmarks container or the DGXC
# recipes repo); we verify-only, never auto-install, because the operator
# is expected to stage the binaries from the same vendor channel they used
# for CUDA / OFED / Fabric Manager. Phase 3 checks skip cleanly when the
# corresponding binary is absent, so a partial environment still produces
# a meaningful report.
install_phase3() {
    section "Phase 3 — Cross-Spine / Full-Scale"

    # jq — used by check 11 to count UFM port entries. Optional but tiny.
    apt_pkg jq

    # The Phase 3 NCCL all-5 sweep, variance run, SHARP compare, AR-congestion
    # check, and ClusterKit fullscale all reuse the Phase 1/2 builds:
    #   * nccl-tests   (built in Phase 1)
    #   * ClusterKit   (verified in Phase 2)
    # Re-confirm here so a phase3-only run reports cleanly.
    local ar_bin="${INSTALL_PREFIX}/nccl-tests/build/all_reduce_perf"
    if [[ -x "${ar_bin}" ]]; then
        mark_skip "build:nccl-tests (${ar_bin} present)"
    else
        mark_fail "build:nccl-tests" "${ar_bin} not found — run phase1 first"
    fi
    local ck_bin="${HPCSDK_DIR}/comm_libs/clusterkit/bin/clusterkit"
    if [[ -x "${ck_bin}" ]]; then
        mark_skip "vendor:ClusterKit (${ck_bin} present)"
    else
        mark_fail "vendor:ClusterKit" \
            "${ck_bin} not found — run phase2 or override HPCSDK_DIR"
    fi

    # perftest already installed by Phase 1; re-confirm for phase3-only runs.
    if command -v ib_write_lat >/dev/null 2>&1; then
        mark_skip "apt:perftest (ib_write_lat present)"
    else
        mark_fail "apt:perftest" "ib_write_lat missing — run phase1 first"
    fi

    # HPL / HPL-MxP / HPCG — vendor-supplied. We verify-only.
    # Hint paths to the NVIDIA HPC Benchmarks container extracted under
    # ${INSTALL_PREFIX}/{hpl,hpl-mxp,hpcg}/bin/. The operator can also point
    # the *_BIN env vars at any other location.
    if [[ -x "${HPL_BIN}" ]]; then
        mark_skip "vendor:HPL FP64 (${HPL_BIN} present)"
    else
        mark_fail "vendor:HPL FP64" \
            "${HPL_BIN} not found — extract NVIDIA HPC Benchmarks container's xhpl into ${INSTALL_PREFIX}/hpl/bin/ or override HPL_BIN"
    fi
    if [[ -x "${HPL_MXP_BIN}" ]]; then
        mark_skip "vendor:HPL-MxP (${HPL_MXP_BIN} present)"
    else
        mark_fail "vendor:HPL-MxP" \
            "${HPL_MXP_BIN} not found — extract NVIDIA HPC Benchmarks container's xhpl_mxp into ${INSTALL_PREFIX}/hpl-mxp/bin/ or override HPL_MXP_BIN"
    fi
    if [[ -x "${HPCG_BIN}" ]]; then
        mark_skip "vendor:HPCG (${HPCG_BIN} present)"
    else
        mark_fail "vendor:HPCG" \
            "${HPCG_BIN} not found — extract NVIDIA HPC Benchmarks container's xhpcg into ${INSTALL_PREFIX}/hpcg/bin/ or override HPCG_BIN"
    fi

    # llmb-run — DGXC NCCL recipe wrapper. Typically installed by cloning
    # https://github.com/NVIDIA/DGXC-NCCL-Recipes and running `pip install -e .`
    # inside that repo. We don't auto-install (the recipe repo is large and
    # the install path depends on the operator's Python env), but we surface
    # a clear remediation hint when it's missing.
    if command -v "${LLMB_RUN}" >/dev/null 2>&1; then
        mark_skip "vendor:llmb-run (${LLMB_RUN} present)"
    else
        mark_fail "vendor:llmb-run" \
            "${LLMB_RUN} not on PATH — clone https://github.com/NVIDIA/DGXC-NCCL-Recipes and pip-install it, or set LLMB_RUN to its absolute path"
    fi

    # UFM REST tooling. Curl is already an apt dep from Phase 0; we only
    # remind the operator that the UFM_HOST / UFM_PASS_FILE env vars need
    # to point at a real UFM instance for check 11 to do anything useful.
    if [[ -n "${UFM_HOST:-}" ]]; then
        mark_skip "config:UFM_HOST=${UFM_HOST}"
    else
        mark_skip "config:UFM_HOST (unset — check 11 will skip; set UFM_HOST/UFM_USER/UFM_PASS_FILE before phase3 to enable)"
    fi

    # Pin the Phase 3 results directory into place so the sbatch wrapper
    # doesn't have to create it as root during the job.
    if [[ "${MODE}" != "verify" && "${DRY_RUN}" -ne 1 ]]; then
        mkdir -p "${INSTALL_PREFIX}/phase3/results" "${INSTALL_PREFIX}/phase3/logs" \
                 "${INSTALL_PREFIX}/phase3/reference" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Phase 4 — Storage Scale
# ---------------------------------------------------------------------------
# Phase 4 adds four open-source storage benchmarks (IOR + mdtest from
# the hpc/ior repo, fio from apt, elbencho from breuner/elbencho, MLPerf
# Storage via pip) plus PyTorch + numpy for the GDS dataloader test 4.8.
# cuFile / libcufile is vendor-supplied via the CUDA toolkit; we
# verify-only.
install_phase4() {
    section "Phase 4 — Storage Scale"

    # System tools: fio for tests 4.3 and 4.7; jq for log inspection
    # (also installed in Phase 3 but kept here for phase4-only runs).
    apt_pkg fio
    apt_pkg jq
    # libnuma + autotools are needed for the IOR / elbencho builds.
    apt_pkg libnuma-dev
    apt_pkg autoconf
    apt_pkg automake
    apt_pkg libtool

    # cuFile / GPUDirect Storage. Ships with the CUDA toolkit; we just
    # verify that libcufile is on the loader path. Check 4.4 and 4.8
    # skip cleanly if it's missing, so this is fail-with-hint rather
    # than hard-blocking.
    if ldconfig -p 2>/dev/null | grep -q libcufile; then
        mark_skip "vendor:libcufile (GPUDirect Storage)"
    else
        mark_fail "vendor:libcufile" \
            "libcufile.so not on ld cache — install nvidia-gds (cuda-gds-12-x) or check 4.4/4.8 will skip"
    fi

    # Python deps for the GDS dataloader test. torch is sometimes
    # already present from vendor images; if so, skip.
    pip_pkg numpy
    if python3 -c 'import torch' >/dev/null 2>&1; then
        mark_skip "pip:torch (already importable)"
    else
        # torch is huge and version-sensitive; we surface a hint
        # rather than auto-installing the wrong build.
        mark_fail "pip:torch" \
            "import torch failed — install the cu12-matched torch wheel (https://pytorch.org/get-started/locally/) or test 4.8 will skip"
    fi

    # Source build: IOR + mdtest (single repo, both binaries).
    if ! command -v mpicc >/dev/null 2>&1; then
        mark_fail "build:ior" "mpicc missing — run phase1 first or install openmpi-bin libopenmpi-dev"
    else
        local jobs
        jobs="$(nproc 2>/dev/null || echo 4)"
        build_from_source ior \
            "https://github.com/hpc/ior.git" "${IOR_TAG}" \
            "${INSTALL_PREFIX}/ior/bin/ior" \
            "./bootstrap \
                 && ./configure --prefix=${INSTALL_PREFIX}/ior CC=mpicc \
                 && make -j${jobs} \
                 && make install"
        # mdtest is in the same install prefix from the same build.
        if [[ -x "${INSTALL_PREFIX}/ior/bin/mdtest" ]]; then
            mark_skip "build:mdtest (${INSTALL_PREFIX}/ior/bin/mdtest present)"
        else
            mark_fail "build:mdtest" \
                "${INSTALL_PREFIX}/ior/bin/mdtest missing — IOR build did not include mdtest"
        fi
    fi

    # Source build: elbencho. Has its own dependencies (boost, ncurses)
    # that come from apt.
    apt_pkg libboost-program-options-dev
    apt_pkg libboost-system-dev
    apt_pkg libncurses-dev
    apt_pkg libaio-dev
    apt_pkg uuid-dev

    if ! command -v nvcc >/dev/null 2>&1; then
        # elbencho's GDS build needs CUDA. Without it we still build a
        # CPU-only elbencho — useful for tests 4.1/4.6 but skips 4.4.
        mark_skip "build:elbencho (nvcc missing — CPU-only build)"
        build_from_source elbencho \
            "https://github.com/breuner/elbencho.git" "${ELBENCHO_TAG}" \
            "${INSTALL_PREFIX}/bin/elbencho" \
            "make -j$(nproc 2>/dev/null || echo 4) \
                 && install -m 0755 bin/elbencho ${INSTALL_PREFIX}/bin/elbencho"
    else
        local cuda_home
        cuda_home="$(dirname "$(dirname "$(command -v nvcc)")")"
        build_from_source elbencho \
            "https://github.com/breuner/elbencho.git" "${ELBENCHO_TAG}" \
            "${INSTALL_PREFIX}/bin/elbencho" \
            "make -j$(nproc 2>/dev/null || echo 4) CUDA_SUPPORT=1 CUFILE_SUPPORT=1 \
                 CUDA_PATH=${cuda_home} \
                 && install -m 0755 bin/elbencho ${INSTALL_PREFIX}/bin/elbencho"
    fi

    # MLPerf Storage is a pip-installable orchestrator script. Light
    # dependency footprint relative to the actual workloads (which
    # come from inside the package).
    pip_pkg mlperf-storage mlperf_storage

    # Pre-create the phase4 results directory tree.
    if [[ "${MODE}" != "verify" && "${DRY_RUN}" -ne 1 ]]; then
        mkdir -p "${INSTALL_PREFIX}/phase4/results" "${INSTALL_PREFIX}/phase4/logs" \
                 "${INSTALL_PREFIX}/phase4/reference" 2>/dev/null || true
    fi

    # Storage root reminder — there's no safe default for ${P4_STORAGE_ROOT}.
    if [[ -n "${P4_STORAGE_ROOT:-}" ]]; then
        mark_skip "config:P4_STORAGE_ROOT=${P4_STORAGE_ROOT}"
    else
        mark_skip "config:P4_STORAGE_ROOT (unset — set this to the PFS mount point before phase4)"
    fi
}

# ---------------------------------------------------------------------------
# Future phases — placeholder. Each new phase appends an install_phaseN()
# function plus a case-arm in the dispatcher below.
# ---------------------------------------------------------------------------
# install_phase5() { ... }

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${MODE}" in
    all|verify)
        install_phase0
        install_phase1
        install_phase2
        install_phase3
        install_phase4
        ;;
    phase0) install_phase0 ;;
    phase1) install_phase1 ;;
    phase2) install_phase2 ;;
    phase3) install_phase3 ;;
    phase4) install_phase4 ;;
    *)
        echo "Unknown mode: ${MODE}" >&2
        echo "Usage: $0 [all|phase0|phase1|phase2|phase3|phase4|verify]   (DRY_RUN=1 supported)" >&2
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
