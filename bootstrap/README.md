# bootstrap/

Single-file installer that lays down every dependency required by every
phase of the cluster health validation work in this repo. One script,
multiple phases, fully idempotent.

## TL;DR

```bash
# First-time setup, run on every host that will participate:
sudo ./install.sh

# Just check what's missing without installing anything:
./install.sh verify

# Preview without touching the system:
DRY_RUN=1 ./install.sh
```

## What it does

`install.sh` is one script with one block per phase. Re-running it is safe
— each step skips if its output is already in place. New phases are added
by appending a new `install_phaseN()` function and an arm to the dispatcher
at the bottom of the script.

| Phase | Source            | What gets installed |
| ----- | ----------------- | --- |
| 0     | apt               | `infiniband-diags`, `ipmitool`, `curl`, `dmidecode`, `python3-pip`, `openssh-client` |
| 0     | pip               | `pyyaml` (optional — aggregators have a fallback parser) |
| 0     | vendor (verify)   | MLNX_OFED (`ibstat`, `mlxlink`, `mlxfwmanager`, `mst`), NVIDIA driver, CUDA, fabric manager |
| 1     | apt               | `build-essential`, `cmake`, `git`, `pkg-config`, `perftest`, `numactl`, `nvme-cli`, `chrony`, `linux-tools-common` |
| 1     | pip               | `pandas`, `pyarrow`, `numpy` |
| 1     | vendor (verify)   | DCGM (`dcgmi`), OpenMPI (`mpirun`) |
| 1     | source build      | `nvbandwidth`, `gpu-burn`, `nccl-tests`, `BabelStream` (cuda-stream) |
| 2     | vendor (verify)   | NVIDIA HPC SDK / `clusterkit` (override path via `HPCSDK_DIR`) |
| 2     | source build      | `osu-micro-benchmarks` (tarball from MVAPICH; CUDA + MPI build) |
| 3     | apt               | `jq` (used by check 11 to count UFM port entries) |
| 3     | vendor (verify)   | HPL FP64 (`xhpl`), HPL-MxP (`xhpl_mxp`), HPCG (`xhpcg`), `llmb-run`. All from the NVIDIA HPC Benchmarks container; override locations via `HPL_BIN` / `HPL_MXP_BIN` / `HPCG_BIN` / `LLMB_RUN`. Phase 3 also re-confirms the Phase 1 `nccl-tests` and Phase 2 `clusterkit` builds. |
| 3     | reminder          | `UFM_HOST` / `UFM_USER` / `UFM_PASS_FILE` — surfaced as a config hint; unset is fine (check 3.11 skips cleanly) |
| 4     | apt               | `fio`, `jq`, `libnuma-dev`, `autoconf`, `automake`, `libtool`, `libboost-program-options-dev`, `libboost-system-dev`, `libncurses-dev`, `libaio-dev`, `uuid-dev` |
| 4     | pip               | `numpy`, `mlperf-storage`. `torch` is hint-only (huge, version-sensitive — operator installs the cu12-matched wheel) |
| 4     | vendor (verify)   | `libcufile` (GPUDirect Storage, ships with CUDA toolkit's `nvidia-gds` package). Test 4.4 / 4.8 skip cleanly if absent. |
| 4     | source build      | `ior` + `mdtest` (single tree from `hpc/ior` @ `IOR_TAG`), `elbencho` (from `breuner/elbencho` @ `ELBENCHO_TAG`, built with `CUDA_SUPPORT=1 CUFILE_SUPPORT=1` when `nvcc` is present, CPU-only otherwise) |
| 4     | reminder          | `P4_STORAGE_ROOT` — surfaced as a config hint; the sbatch wrapper pre-flights this knob and aborts if it's unwritable |

Source builds land at `${INSTALL_PREFIX}/bin/` (or
`${INSTALL_PREFIX}/<tool>/` for multi-file tools). The default prefix is
`/opt/qualification`, matching the paths in
[`phase1-qualification/slurm/env.sh`](../phase1-qualification/slurm/env.sh).

Vendor-supplied components (NVIDIA driver, CUDA toolkit, MLNX_OFED,
fabric manager, DCGM) are **never** auto-installed — those require
vendor channels and coordinated installs. The script verifies they're
present and points at the install pathway if not.

## Where to run it

`install.sh` is host-agnostic — the same script works in both places below.

| Role             | What gets touched                                                                                 |
| ---------------- | ------------------------------------------------------------------------------------------------- |
| Management host  | Phase 0 apt + pip; vendor checks pass even if CUDA isn't present (source builds skip cleanly).    |
| Compute node     | Everything: Phase 0 apt + pip + vendor checks, Phase 1 apt + pip + vendor checks + source builds. |

Typical workflow:

1. Run `install.sh` on the management host first. This gives you
   `ibnetdiscover`, `ipmitool`, and the aggregator Python deps so
   Phase 0 sweeps can run.
2. Run `install.sh` on a single golden node and bake the resulting
   `/opt/qualification/` into your node image (recommended), **or** push
   the script to every node and run in parallel via
   `phase0-precommission/helpers/ssh_fanout.sh` once Phase 0 has
   verified the SSH path works.

## Modes

| Mode     | What it does                                                                  |
| -------- | ----------------------------------------------------------------------------- |
| `all`    | Default. Installs every phase. Skips items already in place.                  |
| `phase0` | Only the Phase 0 block.                                                       |
| `phase1` | Only the Phase 1 block.                                                       |
| `phase2` | Only the Phase 2 block (HPC SDK / ClusterKit verify + OSU build).             |
| `phase3` | Only the Phase 3 block (HPL / HPL-MxP / HPCG / llmb-run verify + UFM hint).   |
| `phase4` | Only the Phase 4 block (IOR/mdtest + elbencho builds, fio, MLPerf Storage, libcufile verify). |
| `verify` | No installs. Reports each item as either present (`SKIP`) or missing (`FAIL`). Useful for a pre-flight gate. |

## Knobs

All knobs are env vars; defaults are sensible.

| Var               | Default               | Purpose                                                  |
| ----------------- | --------------------- | -------------------------------------------------------- |
| `INSTALL_PREFIX`  | `/opt/qualification`  | Where binaries and src land. Must match `env.sh` paths.  |
| `NVBW_TAG`        | `v0.7`                | Pinned NVIDIA/nvbandwidth tag.                           |
| `GPUBURN_REF`     | `master`              | gpu-burn ref (no real release cadence; master is stable).|
| `NCCL_TESTS_TAG`  | `v2.13.10`            | Pinned NVIDIA/nccl-tests tag.                            |
| `BABELSTREAM_TAG` | `v5.0`                | Pinned UoB-HPC/BabelStream tag.                          |
| `OSU_TAG`         | `7.4`                 | Pinned OSU Micro-Benchmarks version.                     |
| `HPCSDK_DIR`      | `/opt/nvidia/hpc_sdk/Linux_x86_64/24.5` | Where ClusterKit is verified.          |
| `HPL_BIN`         | `${INSTALL_PREFIX}/hpl/bin/xhpl`         | Where Phase 3 looks for `xhpl`.       |
| `HPL_MXP_BIN`     | `${INSTALL_PREFIX}/hpl-mxp/bin/xhpl_mxp` | Where Phase 3 looks for `xhpl_mxp`.   |
| `HPCG_BIN`        | `${INSTALL_PREFIX}/hpcg/bin/xhpcg`       | Where Phase 3 looks for `xhpcg`.      |
| `LLMB_RUN`        | `llmb-run` (on PATH)  | DGXC NCCL-recipes launcher used by Phase 3.              |
| `IOR_TAG`         | `4.0.0`               | Pinned `hpc/ior` tag (builds both `ior` and `mdtest`).   |
| `ELBENCHO_TAG`    | `v3.0-11`             | Pinned `breuner/elbencho` tag.                           |
| `IOR_BIN`         | `${INSTALL_PREFIX}/ior/bin/ior`          | Where Phase 4 looks for `ior`.        |
| `MDTEST_BIN`      | `${INSTALL_PREFIX}/ior/bin/mdtest`       | Where Phase 4 looks for `mdtest`.     |
| `ELBENCHO_BIN`    | `${INSTALL_PREFIX}/bin/elbencho`         | Where Phase 4 looks for `elbencho`.   |
| `DRY_RUN`         | `0`                   | Set to `1` to print actions without executing.           |

## Exit codes

| Code | Meaning                                                                  |
| ---- | ------------------------------------------------------------------------ |
| 0    | All requested items installed, skipped, or verified.                     |
| 2    | At least one item FAILED. See the summary block printed at the end.      |
| 3    | Cannot proceed (e.g. not root and not `DRY_RUN=1`).                      |
| 64   | Bad mode argument.                                                       |

## Adding a new phase

Phases 0–4 are now wired up; Phase 5 (long soak) is next. The pattern:

1. Append a function:
   ```bash
   install_phase5() {
       section "Phase 5 — Long Soak"
       apt_pkg <whatever>
       pip_pkg <whatever>
       vendor_check <label> <cmd> <hint>
       build_from_source <name> <repo> <ref> <output_file> <build_cmd>
   }
   ```
2. Add a `phase5` case-arm to the dispatcher and call `install_phase5` from
   the `all`/`verify` arm.
3. Update the usage string at the top of `install.sh` (`Usage:` block and the
   `Unknown mode` error) so the new mode is documented in `--help`-style
   output.
4. Document the new packages and builds in the install table at the top of
   this README, add a `phase5` row to the modes table, and add any new
   knobs to the knobs table.

No other changes needed — the helpers (`apt_pkg`, `pip_pkg`,
`vendor_check`, `build_from_source`) are designed to be reused unchanged.
