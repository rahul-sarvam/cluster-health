# phase4-storage/

Phase 4 — Storage Scale. Eight checks that run as a single Slurm job
across the full cluster (128 nodes × 8 GPUs = 1024 clients) to exercise
the shared parallel filesystem the way DeepSeek-V3 training will:
sustained streaming bandwidth, metadata throughput, per-client IOPS +
tail latency, GPUDirect Storage line rate, MLPerf Storage emulators, a
1024-rank checkpoint write storm, a noisy-neighbour stress, and a
PyTorch + cuFile end-to-end dataloader test.

## TL;DR

```bash
# One-time, on every compute node:
cd ../bootstrap && sudo ./install.sh phase4

# REQUIRED: point at the parallel filesystem under test:
export P4_STORAGE_ROOT=/mnt/scratch     # or /mnt/lustre, /mnt/weka, /mnt/vast, ...

# From a login node:
sbatch slurm/phase4.sbatch
```

The sbatch wrapper grabs a single `--nodes=128 --ntasks-per-node=8
--exclusive` allocation, pre-flights `${P4_STORAGE_ROOT}` so an 8h
allocation isn't burned on an unreachable filesystem, runs checks
01–08 sequentially, and finally runs
[`aggregate/report.py`](aggregate/report.py) which renders Markdown and
exits with rc=0/1/2 (PASS/WARN/FAIL).

## What runs

| #   | Check                                                                                              | What it catches                                                                |
| --- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| 4.1 | [`checks/01_ior_sequential.sh`](checks/01_ior_sequential.sh)                                       | Aggregate read + write GB/s under POSIX IOR with 1024 file-per-process clients. |
| 4.2 | [`checks/02_mdtest.sh`](checks/02_mdtest.sh)                                                       | Global-namespace metadata create rate at 1024 ranks.                            |
| 4.3 | [`checks/03_fio_mixed.sh`](checks/03_fio_mixed.sh)                                                 | Per-client random 70/30 IOPS and tail latency (P99).                            |
| 4.4 | [`checks/04_elbencho_gds.sh`](checks/04_elbencho_gds.sh)                                           | GPUDirect Storage bandwidth as a fraction of per-NIC line rate.                 |
| 4.5 | [`checks/05_mlperf_storage.sh`](checks/05_mlperf_storage.sh)                                       | Realistic dataloader I/O patterns (Unet3D / ResNet50 / CosmoFlow accelerator emulators). |
| 4.6 | [`checks/06_ckpt_storm.sh`](checks/06_ckpt_storm.sh)                                               | 1024 GPUs simultaneously writing a DeepSeek-V3-sized shard; aggregate GB/s + 60 s deadline. |
| 4.7 | [`checks/07_noisy_neighbor.sh`](checks/07_noisy_neighbor.sh)                                       | Read tail latency P99 under concurrent checkpoint storm vs idle baseline.       |
| 4.8 | [`checks/08_gds_dataloader.sh`](checks/08_gds_dataloader.sh) + [`checks/dataloader.py`](checks/dataloader.py) | Real PyTorch + cuFile dataloader vs RAM (tmpfs) baseline; tokens/sec ratio.    |

## Outputs

```
${P4_RESULTS}/
├── 00_preflight_<jobid>.json
├── 01_ior_sequential_<jobid>.json
├── 02_mdtest_<jobid>.json
├── 03_fio_mixed_<jobid>.json
├── 04_elbencho_gds_<jobid>.json
├── 05_mlperf_storage_<jobid>.json
├── 06_ckpt_storm_<jobid>.json
├── 07_noisy_neighbor_<jobid>.json
├── 08_gds_dataloader_<jobid>.json
├── report.md                          # Markdown rollup
└── logs/phase4_<jobid>.log
```

## Cross-cutting analysis

The aggregator runs one cross-cutting audit (`tail_audit`) that
compares the steady-state P99 latency from check 4.3 (FIO baseline)
against the under-load P99 from check 4.7 (noisy neighbour). The
ratio is tagged:

- `pass` if under-load / baseline ≤ 1.5×
- `warn` if 1.5× < ratio ≤ 2.0×
- `fail` if ratio > `P4_NN_TAIL_AMPLIFICATION_MAX` (2.0× default)

This catches end-to-end tail amplification that the individual checks
might miss in isolation.

## Knobs

All knobs are env vars defined in [`slurm/env.sh`](slurm/env.sh). The
storage backend pointer **must be set** by the operator; the rest have
conservative defaults you should tune after the first real run.

| Var                                  | Default        | Purpose                                                                  |
| ------------------------------------ | -------------- | ------------------------------------------------------------------------ |
| `P4_STORAGE_ROOT`                    | `/mnt/scratch` | Shared parallel filesystem mount point. **Operator must set.**           |
| `P4_FULL_NODES`                      | 128            | Number of nodes in the allocation.                                       |
| `P4_GPUS_PER_NODE`                   | 8              | Ranks per node (= NICs per node for GDS tests).                          |
| `P4_FULL_RANKS`                      | 1024           | Total ranks (= nodes × gpus_per_node).                                   |
| `P4_IOR_READ_GBS_MIN`                | 200            | IOR aggregate read GB/s floor.                                           |
| `P4_IOR_WRITE_GBS_MIN`               | 100            | IOR aggregate write GB/s floor.                                          |
| `P4_MDTEST_CREATES_PER_SEC_MIN`      | 200000         | mdtest global-namespace creates/sec floor.                               |
| `P4_FIO_IOPS_MIN`                    | 50000          | Per-client random IOPS floor.                                            |
| `P4_FIO_P99_LAT_US_MAX`              | 1000           | Per-client read P99 latency ceiling (µs).                                |
| `P4_ELBENCHO_LINE_RATE_FRAC_MIN`     | 0.90           | GDS path must reach this fraction of per-NIC line rate.                  |
| `P4_ELBENCHO_LINE_RATE_GBS`          | 46             | Per-NIC line rate (4× NDR ≈ 46 GB/s).                                    |
| `P4_MLPERF_MODEL`                    | `unet3d`       | MLPerf Storage workload: `unet3d` / `resnet50` / `cosmoflow`.            |
| `P4_MLPERF_REF_SAMPLES_PER_SEC`      | TODO_FILL      | Reference samples/sec. `TODO_FILL` → check 4.5 emits warn.               |
| `P4_MLPERF_DEVIATION_PCT`            | 10             | Allowed deviation from the reference (%).                                |
| `P4_CKPT_SHARD_SIZE_GB`              | 1.3            | Per-rank shard size (DeepSeek-V3 sized).                                 |
| `P4_CKPT_AGG_GBS_MIN`                | 22             | Aggregate checkpoint write GB/s floor.                                   |
| `P4_CKPT_DEADLINE_SEC`               | 60             | Storm must complete within this wall-clock deadline.                     |
| `P4_NN_TAIL_AMPLIFICATION_MAX`       | 2.0            | Tail-amplification ceiling for the noisy-neighbour test.                 |
| `P4_DALI_DISK_RAM_RATIO_MIN`         | 0.80           | Disk tokens/sec must reach this fraction of `/dev/shm` tokens/sec.       |
| `IOR_BIN`                            | `${INSTALL_PREFIX}/ior/bin/ior`     | IOR binary.                                         |
| `MDTEST_BIN`                         | `${INSTALL_PREFIX}/ior/bin/mdtest`  | mdtest binary.                                      |
| `FIO_BIN`                            | `fio` (PATH)                        | fio binary.                                         |
| `ELBENCHO_BIN`                       | `${INSTALL_PREFIX}/bin/elbencho`    | elbencho binary.                                    |
| `MLPERF_STORAGE_BIN`                 | `mlperf_storage` (PATH)             | MLPerf Storage launcher (pip).                      |

## Exit codes (aggregator)

| Code | Meaning                                                          |
| ---- | ---------------------------------------------------------------- |
| 0    | All checks passed (or cleanly skipped).                          |
| 1    | At least one check warned, or `tail_audit` warned.               |
| 2    | At least one check, or `tail_audit`, failed.                     |

## Smoke test

A synthetic-input smoke test lives at
[`aggregate/smoke_test.py`](aggregate/smoke_test.py). It builds two
fake `${P4_RESULTS}` directories (happy path + failure path that
triggers `tail_audit`), runs `report.py` against each, and asserts the
expected return code, headline verdict line, and per-check section.
Run with:

```bash
python3 aggregate/smoke_test.py
```

Useful when refactoring the aggregator without a real cluster.

## Re-running

`sbatch slurm/phase4.sbatch` is safe to run repeatedly. Each invocation
gets a new `SLURM_JOB_ID` and writes a new set of JSON fragments + a
new report. Each check cleans up its own scratch subdir on PASS and
leaves it in place on FAIL for forensics.

## Cleanly skipped checks

Three checks skip cleanly if their prerequisites are missing:

- **4.4** (elbencho GDS) skips if `libcufile` is not found in
  `ldconfig` (i.e. cuFile / GDS userspace not installed).
- **4.5** (MLPerf Storage) skips if `mlperf_storage` is not on PATH.
  Emits `warn` (not fail) when `P4_MLPERF_REF_SAMPLES_PER_SEC` is
  still `TODO_FILL`.
- **4.8** (PyTorch + cuFile dataloader) skips if `python3 -c 'import
  torch'` fails or `libcufile` is not found.

A skipped check appears in the report as `SKIP` with the reason, and
does not fail the Phase.

## First-run note: P4_STORAGE_ROOT

Phase 4 has no safe default for `P4_STORAGE_ROOT`. The sbatch wrapper
pre-flights this knob before any check runs: if the path doesn't exist
or isn't writable from the launch node, the job aborts immediately
with a clear error in `${P4_RESULTS}/00_preflight_<jobid>.json`. This
is intentional — wasting an 8 h full-cluster allocation on a
misconfigured mount is the most common operator footgun.

## First-run note: MLPerf reference

`P4_MLPERF_REF_SAMPLES_PER_SEC` defaults to `TODO_FILL`. While it's
that value, check 4.5 emits `warn` (not fail) so we can capture the
measured number on first run. Once we pick the MLPerf Storage workload
and the corresponding MLCommons reference, populate the env var and
4.5 will start enforcing the ±`P4_MLPERF_DEVIATION_PCT` band.
