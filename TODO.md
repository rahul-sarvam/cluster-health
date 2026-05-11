# Implementation TODO

Tracked list of test packs that are specified in [CLUSTER_HEALTH_REFERENCE.md](CLUSTER_HEALTH_REFERENCE.md)
but not yet written as runnable code. Section numbers below mirror the phase
numbers in the reference doc.

When picking up a TODO: follow the convention established by
`day1-qualification/` — numbered shell or Python entry points under
`checks/`, structured JSON output, and an `aggregate/` directory that
rolls into a Markdown report. Wire each new script back into the
reference doc table for that phase by replacing `[NOT-YET-IMPLEMENTED — …]`
with a working link.

Priority key:
- **P0** — blocks acceptance. Must exist before the cluster arrives.
- **P1** — needed during acceptance but not on day one.
- **P2** — nice to have for ongoing health.

Source key (Source column on each row):
- **NEW** — write from scratch, following the `day1-qualification/` convention.
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

| ID    | What                              | Priority | Target path                                    |
|-------|-----------------------------------|----------|------------------------------------------------|
| 2.1   | NCCL sweep at 8/16/32/64 GPUs     | P0       | `phase2-intra-rack/nccl_sweep.sh`              |
| 2.2   | NCCL small-message sweep          | P0       | `phase2-intra-rack/nccl_small_msg.sh`          |
| 2.3   | Rail-isolated all-reduce          | P0       | `phase2-intra-rack/rail_isolated.sh`           |
| 2.4   | ClusterKit intra-rack matrix      | P0       | `phase2-intra-rack/clusterkit_intra.sh`        |
| 2.5   | OSU intra-rack collectives        | P1       | `phase2-intra-rack/osu_intra.sh`               |
| 2.6   | Topology dump diff                | P0       | `phase2-intra-rack/topo_check.sh`              |

## §3 — Phase 3 Cross-Spine Scale

| ID    | What                              | Priority | Source | Target path                                    |
|-------|-----------------------------------|----------|--------|------------------------------------------------|
| 3.1   | NCCL all-5 at 256/512/1024        | P0       | DGXC   | `phase3-fullscale/nccl_sweep.sh`               |
| 3.2   | NCCL variance test (100 runs)     | P0       | DGXC   | `phase3-fullscale/nccl_variance.sh`            |
| 3.3   | SHARP on/off comparison           | P0       | DGXC   | `phase3-fullscale/sharp_compare.sh`            |
| 3.4   | All-pairs IB fullscale sweep      | P0       | NEW    | `phase3-fullscale/clusterkit_fullscale.sh`     |
| 3.5   | Adaptive-routing congestion test  | P0       | NEW    | `phase3-fullscale/ar_congestion.sh`            |
| 3.6   | IB latency sweep                  | P1       | NEW    | `phase3-fullscale/ib_latency.sh`               |
| 3.7   | FEC / BER cluster-wide capture    | P0       | NEW    | `phase3-fullscale/fec_sweep.sh`                |
| 3.8   | HPL FP64 at full scale            | P1       | NEW    | `phase3-fullscale/hpl_fp64.sh`                 |
| 3.9   | HPL-MxP at full scale             | P0       | NEW    | `phase3-fullscale/hpl_mxp.sh`                  |
| 3.10  | HPCG at full scale                | P1       | NEW    | `phase3-fullscale/hpcg.sh`                     |
| 3.11  | UFM telemetry snapshot            | P0       | NEW    | `phase3-fullscale/ufm_snapshot.sh`             |

## §4 — Phase 4 Storage Scale

| ID    | What                              | Priority | Target path                                    |
|-------|-----------------------------------|----------|------------------------------------------------|
| 4.1   | IOR sequential at 1024 clients    | P0       | `phase4-storage/ior_sequential.sh`             |
| 4.2   | mdtest at 1024 ranks              | P0       | `phase4-storage/mdtest.sh`                     |
| 4.3   | FIO mixed                         | P1       | `phase4-storage/fio_mixed.sh`                  |
| 4.4   | Elbencho with GDS                 | P0       | `phase4-storage/elbencho_gds.sh`               |
| 4.5   | MLPerf Storage benchmark          | P0       | `phase4-storage/mlperf_storage.sh`             |
| 4.6   | Checkpoint write storm            | P0       | `phase4-storage/ckpt_storm.sh`                 |
| 4.7   | Noisy-neighbour storage test      | P0       | `phase4-storage/noisy_neighbor.sh`             |
| 4.8   | GDS PyTorch dataloader path test  | P0       | `phase4-storage/gds_dataloader.py`             |

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

A few items that should be tightened on the existing `day1-qualification/`
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
