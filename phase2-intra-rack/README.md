# phase2-intra-rack/

Phase 2 — Intra-Rack Scale. Six checks that run as a single Slurm job
across one rack (8 nodes × 8 GPUs = 64 GPUs) to catch leaf-switch,
rail, and cable issues before they get amplified at full-cluster scale.

## TL;DR

```bash
# One-time, on every compute node in the rack:
cd ../bootstrap && sudo ./install.sh phase2

# From a login node, per rack:
sbatch slurm/phase2.sbatch
```

The sbatch script grabs an 8-node × 64-GPU exclusive allocation and
runs the six checks back-to-back inside it. Each check emits a JSON
fragment to `${P2_RESULTS}`. The aggregator
([`aggregate/report.py`](aggregate/report.py)) rolls them up into a
Markdown report and exits non-zero on FAIL.

## What runs

| #   | Check                                                            | What it catches                                                               |
| --- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| 2.1 | [`checks/01_nccl_sweep.sh`](checks/01_nccl_sweep.sh)             | NCCL all-reduce busbw at 1/2/4/8 nodes; flags any scale point below target.   |
| 2.2 | [`checks/02_nccl_small_msg.sh`](checks/02_nccl_small_msg.sh)     | 8 B latency at full-rack scale; flags > 15 µs.                                |
| 2.3 | [`checks/03_rail_isolated.sh`](checks/03_rail_isolated.sh)       | Pins NCCL to one HCA at a time and checks for any rail outlier > 1% below.   |
| 2.4 | [`checks/04_clusterkit_intra.sh`](checks/04_clusterkit_intra.sh) | ClusterKit pair-matrix; flags any (src, dst) > 5% below pair-median.         |
| 2.5 | [`checks/05_osu_intra.sh`](checks/05_osu_intra.sh)               | Independent MPI all-reduce + alltoall; cross-checked against NCCL.           |
| 2.6 | [`checks/06_topo_check.sh`](checks/06_topo_check.sh)             | NCCL's discovered topology XML diffed against captured reference.            |

## Outputs

```
${P2_RESULTS}/
├── 01_nccl_sweep_<jobid>.json
├── 02_nccl_small_msg_<jobid>.json
├── 03_rail_isolated_<jobid>.json
├── 04_clusterkit_intra_<jobid>.json
├── 05_osu_intra_<jobid>.json
├── 06_topo_check_<jobid>.json
├── phase2_report_<jobid>.md                # Markdown rollup
├── 01_nccl_sweep_<jobid>/scale_{1,2,4,8}n.log
├── 03_rail_isolated_<jobid>/rail_{0..7}.log
├── 04_clusterkit_intra_<jobid>/matrix.csv
├── 06_topo_check_<jobid>/nccl_topo.xml
└── ...
```

## Knobs

All knobs are env vars defined in [`slurm/env.sh`](slurm/env.sh). The
defaults are conservative; tune after the first run on real hardware.

| Var                              | Default | Purpose                                                                 |
| -------------------------------- | ------- | ----------------------------------------------------------------------- |
| `NCCL_AR_BUSBW_MIN_8GPU_GBS`     | 380     | All-reduce busbw target at 1-node scale.                                |
| `NCCL_AR_BUSBW_MIN_16GPU_GBS`    | 350     | Target at 2 nodes.                                                      |
| `NCCL_AR_BUSBW_MIN_32GPU_GBS`    | 330     | Target at 4 nodes.                                                      |
| `NCCL_AR_BUSBW_MIN_64GPU_GBS`    | 320     | Target at 8 nodes (full rack).                                          |
| `NCCL_AR_LATENCY_MAX_8B_US`      | 15      | 8 B all-reduce latency ceiling at full-rack scale (µs).                 |
| `P2_RAIL_OUTLIER_PCT`            | 1.0     | Any rail > this % below the median of rails fails 2.3.                  |
| `P2_PAIR_OUTLIER_PCT`            | 5.0     | Any (src, dst) > this % below median pair fails 2.4.                    |
| `P2_OSU_NCCL_AGREEMENT_PCT`      | 3.0     | OSU vs NCCL effective-BW agreement at full-rack scale.                  |
| `P2_MONOTONICITY_DROP_PCT`       | 5.0     | Adjacent scale-curve points may not drop by more than this %.           |
| `P2_REF_TOPO`                    | `${P2_ROOT}/reference/nccl_topo_ref.xml` | Reference topology for 2.6.                |

## Exit codes (aggregator)

| Code | Meaning                                                    |
| ---- | ---------------------------------------------------------- |
| 0    | All checks passed (or cleanly skipped).                    |
| 1    | At least one cross-cutting analysis warned.                |
| 2    | At least one check (or cross-cutting audit) failed.        |

## Re-running

`sbatch slurm/phase2.sbatch` is safe to run repeatedly. Each invocation
gets a new `SLURM_JOB_ID` and writes a new set of JSON fragments + a
new report. Old runs are not deleted; if you want to compare two runs,
keep both report files.

## First-run note: topology reference

Check 2.6 needs a known-good NCCL topology XML at `${P2_REF_TOPO}`. On
first run that file won't exist and 2.6 will WARN, capturing the
discovered XML as a candidate. Once you've verified the captured XML
matches your intended rail-optimised layout, copy it into place:

```bash
cp ${P2_RESULTS}/06_topo_check_<jobid>/nccl_topo.norm.xml \
   ${P2_ROOT}/reference/nccl_topo_ref.xml
```

Subsequent runs will diff against it and fail on drift.
