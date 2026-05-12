# Implementation TODO

Tracked list of test packs that are specified in [CLUSTER_HEALTH_REFERENCE.md](CLUSTER_HEALTH_REFERENCE.md)
but not yet written as runnable code. Section numbers below mirror the phase
numbers in the reference doc.

When picking up a TODO: follow the convention established by
`phase1-qualification/` — numbered shell or Python entry points under
`checks/`, structured JSON output, and an `aggregate/` directory that
rolls into a Markdown report. Wire each new script back into the
reference doc table for that phase by replacing `[NOT-YET-IMPLEMENTED — …]`
with a working link.

Priority key:
- **P0** — blocks acceptance. Must exist before the cluster arrives.
- **P1** — needed during acceptance but not on day one.
- **P2** — nice to have for ongoing health.

Source key (Source column on each row):
- **NEW** — write from scratch, following the `phase1-qualification/` convention.
- **DGXC** — wrap an upstream recipe from
  [NVIDIA/dgxc-benchmarking](https://github.com/NVIDIA/dgxc-benchmarking) via
  `llmb-run submit`. The script we write is the thin integration layer
  (parse outputs, emit our JSON, apply our pass criteria, plug into our
  aggregator). The underlying workload is upstream.

---

## §0 — Phase 0 Pre-Commission

Three of five items are now IMPLEMENTED in `phase0-precommission/`
(firmware, cables, BMC). Remaining items below.

| ID    | What                                                | Priority | Source | Target path                                    |
|-------|-----------------------------------------------------|----------|--------|------------------------------------------------|
| 0.1   | BOM reconciliation against PO (manual checklist + script that diffs FRU serials vs the vendor's PO CSV) | P1 | NEW | `phase0-precommission/bom_reconcile.py` |
| 0.5   | PTP/NTP topology validator (peer list, stratum, GMC failover drill) | P1 | NEW | `phase0-precommission/ptp_topology.py` |

Implemented (kept here for the index — links live in the reference doc):
- 0.2 firmware-pin baseline   → `phase0-precommission/firmware_baseline.sh` + `aggregate/firmware_diff.py`
- 0.3 cable inventory         → `phase0-precommission/cable_inventory.sh`   + `aggregate/cable_validate.py`
- 0.4 BMC reachability sweep  → `phase0-precommission/bmc_sweep.sh`         + `aggregate/bmc_summary.py`

Cross-cutting Phase 0 follow-ups (lightweight; do once vendor data lands):
- Populate `reference/expected_firmware.yaml` with the real vendor firmware manifest once we have it (currently all `TODO_FILL_AT_BURNIN`).
- Translate the vendor cable map into `reference/expected_topology.yaml` so `cable_validate.py` can do the rack→leaf cross-check (today it only validates speed/width/state/BER).
- Replace `P0_IPMI_USER` / `P0_IPMI_PASS` in `env.sh` with a Vault / `pass` lookup; right now they're plain env vars.

## §2 — Phase 2 Intra-Rack Scale

All six tests are now IMPLEMENTED in `phase2-intra-rack/`.

Implemented (links live in the reference doc):
- 2.1 NCCL sweep at 8/16/32/64 GPUs → `phase2-intra-rack/checks/01_nccl_sweep.sh`
- 2.2 NCCL small-message sweep      → `phase2-intra-rack/checks/02_nccl_small_msg.sh`
- 2.3 Rail-isolated all-reduce      → `phase2-intra-rack/checks/03_rail_isolated.sh`
- 2.4 ClusterKit intra-rack matrix  → `phase2-intra-rack/checks/04_clusterkit_intra.sh`
- 2.5 OSU intra-rack collectives    → `phase2-intra-rack/checks/05_osu_intra.sh`
- 2.6 Topology dump diff            → `phase2-intra-rack/checks/06_topo_check.sh`
- Slurm wrapper                     → `phase2-intra-rack/slurm/phase2.sbatch`
- Aggregator                        → `phase2-intra-rack/aggregate/report.py`

Cross-cutting Phase 2 follow-ups (lightweight; do once Phase 2 runs on real hardware):
- Capture a known-good NCCL topology XML and write it to `${P2_REF_TOPO}` (default `/opt/qualification/phase2/reference/nccl_topo_ref.xml`). Until that's in place, check 2.6 emits a warn and saves the captured dump as a candidate reference.
- Tune `NCCL_AR_BUSBW_MIN_{8,16,32,64}GPU_GBS` once we've seen real B200/NDR busbw numbers — current defaults are conservative guesses.
- Consider `P2_OSU_NCCL_AGREEMENT_PCT`: 3% may be too tight against MPI vs NCCL collective implementations; revisit after first run.

## §3 — Phase 3 Cross-Spine Scale

All eleven tests are now IMPLEMENTED in `phase3-fullscale/`.

Implemented (links live in the reference doc):
- 3.1  NCCL all-5 at 256/512/1024 GPUs → `phase3-fullscale/checks/01_nccl_all5.sh`
- 3.2  NCCL variance (100× all-reduce) → `phase3-fullscale/checks/02_nccl_variance.sh`
- 3.3  SHARP on/off comparison        → `phase3-fullscale/checks/03_sharp_compare.sh`
- 3.4  ClusterKit pair-matrix (1024)  → `phase3-fullscale/checks/04_clusterkit_fullscale.sh`
- 3.5  AR-congestion recovery test    → `phase3-fullscale/checks/05_ar_congestion.sh`
- 3.6  IB latency (intra-leaf+spine)  → `phase3-fullscale/checks/06_ib_latency.sh`
- 3.7  FEC / pre-FEC BER bookend      → `phase3-fullscale/checks/07_fec_sweep.sh`
- 3.8  HPL FP64                       → `phase3-fullscale/checks/08_hpl_fp64.sh`
- 3.9  HPL-MxP                        → `phase3-fullscale/checks/09_hpl_mxp.sh`
- 3.10 HPCG                           → `phase3-fullscale/checks/10_hpcg.sh`
- 3.11 UFM REST snapshot bookend      → `phase3-fullscale/checks/11_ufm_snapshot.sh`
- Slurm wrapper                       → `phase3-fullscale/slurm/phase3.sbatch`
- Aggregator                          → `phase3-fullscale/aggregate/report.py`
- Smoke test (synthetic inputs)       → `phase3-fullscale/aggregate/smoke_test.py`

Cross-cutting Phase 3 follow-ups (lightweight; do once Phase 3 runs on real hardware):
- Fill `P3_HPL_MXP_REF_TFLOPS` in `slurm/env.sh` with NVIDIA's published B200
  HPL-MxP reference number once we know which DGX OS / NVIDIA HPC Benchmarks
  release we're targeting. Until then, check 3.9 emits `warn` instead of
  failing so we can capture the measured number on first run.
- Stage `HPL.dat` (FP64) and `HPL_MxP.dat` next to their respective binaries
  under `${INSTALL_PREFIX}/{hpl,hpl-mxp}/`. They typically come out of the
  NVIDIA HPC Benchmarks container.
- Tune the 1024-GPU NCCL busbw minimums (`NCCL_AR_BUSBW_MIN_1024GPU_GBS` and
  friends) and the IB latency ceilings (`P3_IB_*_LAT_MAX_US`) after first
  real-hardware run. Current defaults are conservative guesses.
- Wire `UFM_HOST` / `UFM_USER` / `UFM_PASS_FILE` into the bootstrap secrets
  flow. Right now the password file path is a static `/etc/ufm.pass`.
- Decide whether to keep the cliff threshold at 5% (`P3_64_TO_1024_CLIFF_PCT`)
  or relax to 8% once we know the real spine topology utilisation.

## §4 — Phase 4 Storage Scale

All eight tests are now IMPLEMENTED in `phase4-storage/`.

Implemented (links live in the reference doc):
- 4.1 IOR sequential at 1024 clients   → `phase4-storage/checks/01_ior_sequential.sh`
- 4.2 mdtest at 1024 ranks             → `phase4-storage/checks/02_mdtest.sh`
- 4.3 FIO mixed (per-client IOPS, P99) → `phase4-storage/checks/03_fio_mixed.sh`
- 4.4 Elbencho with GDS                → `phase4-storage/checks/04_elbencho_gds.sh`
- 4.5 MLPerf Storage benchmark         → `phase4-storage/checks/05_mlperf_storage.sh`
- 4.6 Checkpoint write storm           → `phase4-storage/checks/06_ckpt_storm.sh`
- 4.7 Noisy-neighbour storage test     → `phase4-storage/checks/07_noisy_neighbor.sh`
- 4.8 GDS PyTorch dataloader path test → `phase4-storage/checks/08_gds_dataloader.sh` + `checks/dataloader.py`
- Slurm wrapper                        → `phase4-storage/slurm/phase4.sbatch`
- Aggregator                           → `phase4-storage/aggregate/report.py` (with `tail_audit` cross-cutting)
- Smoke test (synthetic inputs)        → `phase4-storage/aggregate/smoke_test.py`

Cross-cutting Phase 4 follow-ups (lightweight; do once Phase 4 runs on real hardware):
- Decide the parallel filesystem mount point and pin `P4_STORAGE_ROOT` in
  `slurm/env.sh` (no safe default; pre-flight aborts fast if unset/unwritable).
- Fill `P4_MLPERF_REF_SAMPLES_PER_SEC` in `slurm/env.sh` with the vendor's
  published per-workload reference once we pick the MLPerf Storage workload
  (Unet3D / ResNet50 / CosmoFlow). Until then, check 4.5 emits `warn`
  instead of failing so we can capture the measured number on first run.
- Tune `P4_IOR_READ_GBS_MIN` / `P4_IOR_WRITE_GBS_MIN` /
  `P4_CKPT_AGG_GBS_MIN` / `P4_ELBENCHO_LINE_RATE_GBS` to the vendor-spec'd
  numbers for the delivered parallel filesystem (current defaults are
  conservative; real PFS should comfortably exceed them).
- Decide whether the 50/50 reader/writer split in `07_noisy_neighbor.sh`
  is the right policy for the cluster, or whether a 7/1 (training-heavy)
  or 3/1 mix better represents production. Current default is 50/50.
- Install a CUDA-12.x-matched `torch` wheel during `install_phase4` (the
  bootstrap currently hint-only checks for `python3 -c 'import torch'`
  and skips check 4.8 if absent). Pick the wheel index that matches the
  `nvidia-smi` CUDA version on the cluster.
- Confirm `libcufile` (cuFile / GDS userspace) is in `ldconfig` on every
  compute node — checks 4.4 and 4.8 both skip cleanly if it isn't. The
  bootstrap uses `vendor_check` only; cuFile install is operator-owned.

## §5 — Phase 5 Long Soak (DeepSeek-V3)

| ID    | What                              | Priority | Source | Target path                                    |
|-------|-----------------------------------|----------|--------|------------------------------------------------|
| 5.1   | DeepSeek-V3 launcher (Megatron)   | P0       | DGXC   | `phase5-soak/launch_deepseek.sh`               |
| 5.2   | Step-time variance tracker        | P0       | NEW    | `phase5-soak/step_variance.py`                 |
| 5.3   | Straggler detection               | P0       | NEW    | `phase5-soak/straggler_detect.py`              |
| 5.4   | Checkpoint write + verify         | P0       | NEW    | `phase5-soak/ckpt_verify.py`                   |
| 5.5   | Restart-from-checkpoint drill     | P0       | NEW    | `phase5-soak/restart_drill.sh`                 |
| 5.6   | Inject node failure               | P0       | NEW    | `phase5-soak/inject_node_failure.sh`           |
| 5.7   | Inject NIC port-flap              | P0       | NEW    | `phase5-soak/inject_nic_flap.sh`               |
| 5.8   | Inject GPU ECC throttle           | P1       | NEW    | `phase5-soak/inject_ecc_throttle.sh`           |
| 5.9   | XID / ECC collector               | P0       | NEW    | `phase5-soak/xid_collector.py`                 |
| 5.10  | Power & thermal monitor           | P0       | NEW    | `phase5-soak/power_temp_monitor.py`            |
| 5.11  | Memory-leak detector              | P1       | NEW    | `phase5-soak/memleak_monitor.py`               |
| 5.12  | NVSwitch counter tracker          | P0       | NEW    | `phase5-soak/nvswitch_telemetry.py`            |
| 5.13  | IB symbol-error tracker           | P0       | NEW    | `phase5-soak/ib_symerr_track.py`               |
| 5.14  | PTP drift tracker                 | P1       | NEW    | `phase5-soak/ptp_drift.py`                     |
| 5.15  | Soak summary report               | P0       | NEW    | `phase5-soak/soak_report.py`                   |

## §6 — Phase 6 Multi-Job Interference

| ID    | What                              | Priority | Source | Target path                                    |
|-------|-----------------------------------|----------|--------|------------------------------------------------|
| 6.1   | 512 train + 512 infer             | P0       | DGXC   | `phase6-multijob/mixed_load.sh`                |
| 6.2   | 512 + 512 dual training           | P0       | DGXC   | `phase6-multijob/dual_train.sh`                |
| 6.3   | 64 + 960 small + large            | P1       | DGXC   | `phase6-multijob/small_large.sh`               |
| 6.4   | DP-heavy + MoE-heavy collision    | P0       | DGXC   | `phase6-multijob/dp_moe_collide.sh`            |
| 6.5   | Training + storage storm          | P0       | NEW    | `phase6-multijob/train_plus_storm.sh`          |

## §7 — Phase 7 Aged-FS Regression

| ID    | What                              | Priority | Target path                                    |
|-------|-----------------------------------|----------|------------------------------------------------|
| 7.1   | Fill FS to 70%                    | P0       | `phase7-aging/fill_to_70.sh`                   |
| 7.2   | 5-day mixed ageing loop           | P0       | `phase7-aging/age_loop.sh`                     |
| 7.3   | Phase-4 re-run after ageing       | P0       | `phase7-aging/rerun_phase4.sh`                 |

## §8 — Phase 8 Sign-off

| ID    | What                              | Priority | Target path                                    |
|-------|-----------------------------------|----------|------------------------------------------------|
| 8.1   | Diagnostic bundle tarball         | P0       | `sign-off/bundle.sh`                           |
| 8.2   | Cross-phase summary report        | P0       | `sign-off/final_report.py`                     |

---

## Cross-cutting follow-ups for Phase 1 (already implemented)

A few items that should be tightened on the existing `phase1-qualification/`
scaffold:

- Fill in `EXPECTED_DRIVER_VERSION` and `EXPECTED_FM_VERSION` in `slurm/env.sh`
  once we have the vendor's pin.
- Decide NIC pairing strategy for `09_ib_loopback_bw.sh`: intra-node pair vs
  pair-with-leaf-neighbor. Currently uses intra-node pairing; revisit for
  Phase 1 production use.
- Add per-GPU `cuBLAS` FP64/BF16/FP8 GEMM bench as `checks/11_gemm.sh` —
  catches partial-die compute issues the HBM and DCGM tests miss.
- Add a `dcgm-exporter` warm-start during Phase 1 so we have continuous
  telemetry from acceptance Day 1 onward.
