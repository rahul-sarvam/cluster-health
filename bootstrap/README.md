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

Source builds land at `${INSTALL_PREFIX}/bin/` (or
`${INSTALL_PREFIX}/<tool>/` for multi-file tools). The default prefix is
`/opt/qualification`, matching the paths in
[`day1-qualification/slurm/env.sh`](../day1-qualification/slurm/env.sh).

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
| `DRY_RUN`         | `0`                   | Set to `1` to print actions without executing.           |

## Exit codes

| Code | Meaning                                                                  |
| ---- | ------------------------------------------------------------------------ |
| 0    | All requested items installed, skipped, or verified.                     |
| 2    | At least one item FAILED. See the summary block printed at the end.      |
| 3    | Cannot proceed (e.g. not root and not `DRY_RUN=1`).                      |
| 64   | Bad mode argument.                                                       |

## Adding a new phase

When Phase 2 (intra-rack) lands:

1. Append a function:
   ```bash
   install_phase2() {
       section "Phase 2 — Intra-Rack Scale"
       apt_pkg <whatever>
       build_from_source <whatever>
   }
   ```
2. Add a `phase2` case-arm to the dispatcher and call `install_phase2` from
   the `all`/`verify` arm.
3. Document the new packages and builds in the table at the top of this
   README.

No other changes needed — the helpers (`apt_pkg`, `pip_pkg`,
`vendor_check`, `build_from_source`) are designed to be reused unchanged.
