# phase3-fullscale/

Phase 3 — Cross-Spine Scale. Eleven checks that run as a single Slurm
job across the full cluster (128 nodes × 8 GPUs = 1024 GPUs) to catch
spine/leaf imbalances, adaptive-routing misconfiguration, SHARP issues,
fabric BER drift, HPC headline numbers, and the long tail of fabric
pathologies. Bookended with FEC + UFM snapshots so we can diff
mid-phase degradation against the starting state.

## TL;DR

```bash
# One-time, on every compute node:
cd ../bootstrap && sudo ./install.sh phase3

# From a login node:
sbatch slurm/phase3.sbatch
```

The sbatch wrapper grabs a single `--nodes=128 --exclusive` allocation,
captures a baseline FEC + UFM snapshot, runs checks 01–06 and 08–10
sequentially, captures the final FEC + UFM snapshot, and finally runs
[`aggregate/report.py`](aggregate/report.py) which renders Markdown and
exits with rc=0/1/2 (PASS/WARN/FAIL).

## What runs

| #    | Check                                                                                | What it catches                                                                |
| ---- | ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| 3.1  | [`checks/01_nccl_all5.sh`](checks/01_nccl_all5.sh)                                   | All 5 NCCL collectives at 256/512/1024 GPUs; flags >5% cliff from 64→1024.    |
| 3.2  | [`checks/02_nccl_variance.sh`](checks/02_nccl_variance.sh)                           | 100 back-to-back full-cluster all-reduces; σ/μ ≤ 2%, p99/p50 ≤ 1.05.          |
| 3.3  | [`checks/03_sharp_compare.sh`](checks/03_sharp_compare.sh)                           | Falsification of `NCCL_COLLNET_ENABLE=1` — confirms speed-up, not just log.   |
| 3.4  | [`checks/04_clusterkit_fullscale.sh`](checks/04_clusterkit_fullscale.sh)             | All-pairs IB BW heatmap at 1024 GPUs; flags any pair > 5% below pair median.  |
| 3.5  | [`checks/05_ar_congestion.sh`](checks/05_ar_congestion.sh)                           | Spine-collision pattern; AR-on must recover ≥ 80% of uncongested busbw.       |
| 3.6  | [`checks/06_ib_latency.sh`](checks/06_ib_latency.sh)                                 | `ib_write_lat` intra-leaf and cross-spine; ceilings 1.2 µs / 1.8 µs.          |
| 3.7  | [`checks/07_fec_sweep.sh`](checks/07_fec_sweep.sh)                                   | `mlxlink` pre-FEC BER + symbol-error counters at start and end of phase.      |
| 3.8  | [`checks/08_hpl_fp64.sh`](checks/08_hpl_fp64.sh)                                     | HPL FP64; ≥ 60% of theoretical FP64 peak.                                     |
| 3.9  | [`checks/09_hpl_mxp.sh`](checks/09_hpl_mxp.sh)                                       | HPL-MxP; within 5% of NVIDIA reference.                                       |
| 3.10 | [`checks/10_hpcg.sh`](checks/10_hpcg.sh)                                             | HPCG; ≥ 3% of HPL TFlops.                                                     |
| 3.11 | [`checks/11_ufm_snapshot.sh`](checks/11_ufm_snapshot.sh)                             | UFM REST ports/links/events JSON at start and end; no port renegotiated.      |

## Outputs

```
${P3_RESULTS}/
├── 00_fec_baseline_<jobid>.json
├── 00_ufm_baseline_<jobid>.json
├── 01_nccl_all5_<jobid>.json
├── 02_nccl_variance_<jobid>.json
├── 03_sharp_compare_<jobid>.json
├── 04_clusterkit_fullscale_<jobid>.json
├── 05_ar_congestion_<jobid>.json
├── 06_ib_latency_<jobid>.json
├── 07_fec_final_<jobid>.json
├── 08_hpl_fp64_<jobid>.json
├── 09_hpl_mxp_<jobid>.json
├── 10_hpcg_<jobid>.json
├── 11_ufm_final_<jobid>.json
├── report.md                           # Markdown rollup
└── logs/phase3_<jobid>.log
```

## Cross-cutting analyses

The aggregator runs three audits across all check fragments:

1. **Cliff audit** — diffs 64-GPU busbw against 1024-GPU busbw for each
   NCCL collective; warns at 5% cliff, fails at the threshold from
   `P3_64_TO_1024_CLIFF_PCT`.
2. **FEC audit** — compares per-port symbol-error and post-FEC-error
   counters at phase start vs end. Any non-zero delta fails.
3. **UFM audit** — compares port `active_speed` / `active_width` /
   `physical_state` at phase start vs end. Any renegotiation fails.

These run only if both endpoints exist; otherwise the audit emits
`skip`.

## Knobs

All knobs are env vars defined in [`slurm/env.sh`](slurm/env.sh).

| Var                                 | Default   | Purpose                                                                  |
| ----------------------------------- | --------- | ------------------------------------------------------------------------ |
| `NCCL_AR_BUSBW_MIN_1024GPU_GBS`     | 400       | All-reduce busbw target at 1024 GPUs.                                    |
| `NCCL_AG_BUSBW_MIN_1024GPU_GBS`     | 360       | All-gather target.                                                       |
| `NCCL_RS_BUSBW_MIN_1024GPU_GBS`     | 360       | Reduce-scatter target.                                                   |
| `NCCL_AA_BUSBW_MIN_1024GPU_GBS`     | 300       | Alltoall target.                                                         |
| `NCCL_SR_BUSBW_MIN_1024GPU_GBS`     | 200       | Sendrecv target.                                                         |
| `P3_64_TO_1024_CLIFF_PCT`           | 5         | Cliff threshold for the 64→1024 audit (%).                              |
| `P3_VARIANCE_STD_PCT_MAX`           | 2.0       | σ/μ ceiling for check 3.2.                                               |
| `P3_VARIANCE_P99_P50_MAX`           | 1.05      | p99/p50 ceiling for check 3.2.                                           |
| `P3_SHARP_MIN_GAIN_PCT`             | 15        | SHARP-on must beat SHARP-off by this %.                                  |
| `P3_PAIR_OUTLIER_PCT`               | 5         | ClusterKit pair outlier definition (%).                                  |
| `P3_AR_RECOVERY_MIN_PCT`            | 80        | AR-on must recover this % of uncongested BW.                             |
| `P3_IB_INTRA_LEAF_LAT_MAX_US`       | 1.2       | `ib_write_lat` ceiling within leaf (µs).                                 |
| `P3_IB_CROSS_SPINE_LAT_MAX_US`      | 1.8       | `ib_write_lat` ceiling across spine (µs).                                |
| `P3_PRE_FEC_BER_MAX`                | 1e-7      | Pre-FEC BER ceiling per port.                                            |
| `P3_HPL_FP64_PEAK_FRAC_MIN`         | 0.60      | HPL FP64 must reach this fraction of theoretical peak.                   |
| `P3_HPL_MXP_REF_TFLOPS`             | TODO_FILL | Vendor reference for HPL-MxP. `TODO_FILL` → check 3.9 emits warn.        |
| `P3_HPL_MXP_REF_DEVIATION_PCT`      | 5         | HPL-MxP deviation ceiling around the vendor reference (%).               |
| `P3_HPCG_HPL_FRAC_MIN`              | 0.03      | HPCG must reach this fraction of HPL TFlops.                             |
| `UFM_HOST`                          | (empty)   | UFM REST endpoint. Unset → check 3.11 skips cleanly.                     |
| `UFM_USER`                          | `admin`   | UFM REST user.                                                           |
| `UFM_PASS_FILE`                     | `/etc/ufm.pass` | File holding UFM REST password.                                    |

## Exit codes (aggregator)

| Code | Meaning                                                          |
| ---- | ---------------------------------------------------------------- |
| 0    | All checks passed (or cleanly skipped).                          |
| 1    | At least one cross-cutting analysis warned (cliff/FEC/UFM).      |
| 2    | At least one check, or cross-cutting audit, failed.              |

## Smoke test

A synthetic-input smoke test lives at
[`aggregate/smoke_test.py`](aggregate/smoke_test.py). It builds two
fake `${P3_RESULTS}` directories (happy path + failure path that
triggers the cliff/FEC/UFM audits), runs `report.py` against each, and
asserts the expected return code, headline verdict line, and audit
status. Run with:

```bash
python3 aggregate/smoke_test.py
```

Useful when refactoring the aggregator without a real cluster.

## Re-running

`sbatch slurm/phase3.sbatch` is safe to run repeatedly. Each invocation
gets a new `SLURM_JOB_ID` and writes a new set of JSON fragments + a
new report. The FEC and UFM bookends always re-capture, so back-to-back
runs will surface mid-phase degradation as a non-zero delta.

## First-run note: UFM credentials

Check 3.11 needs `UFM_HOST` set and `UFM_PASS_FILE` readable. Until the
ops team wires both into the bootstrap secrets flow, check 3.11 emits
`skip` cleanly and the rest of Phase 3 carries on.

## First-run note: HPL-MxP reference

`P3_HPL_MXP_REF_TFLOPS` defaults to `TODO_FILL`. While it's that value,
check 3.9 emits `warn` (not fail) so we can capture the measured number
on first run. Once we know the targeted NVIDIA HPC Benchmarks release,
populate the env var with the published reference and 3.9 will start
enforcing the ±`P3_HPL_MXP_REF_DEVIATION_PCT` band.
