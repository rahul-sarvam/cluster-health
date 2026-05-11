# Cluster Health Reference

A self-contained reference for validating, accepting, and continuously
monitoring large GPU clusters at Sarvam. Written initially for the 1024×
B200 acceptance, but the structure and tests apply to any future cluster
of any GPU family with minor parameter changes.

This is **the** document. If you are new to the team, read this end-to-end
once. If you are running a check, jump to the relevant phase section —
every test lists what it does, why it matters, how it passes, and which
script to run.

A glossary at the very end defines every acronym and term of art used.

---

## Table of Contents

1. [Purpose & Scope](#1-purpose--scope)
2. [Philosophy: How We Validate a Cluster](#2-philosophy-how-we-validate-a-cluster)
3. [The Eight Phases](#3-the-eight-phases-of-cluster-health-validation)
4. [Phase 0 — Pre-Commission](#4-phase-0--pre-commission)
5. [Phase 1 — Per-Node Qualification Gate (Day 1–3)](#5-phase-1--per-node-qualification-gate-day-13)
6. [Phase 2 — Intra-Rack Scale (Day 3–5)](#6-phase-2--intra-rack-scale-day-35)
7. [Phase 3 — Cross-Spine Scale: NCCL, HPL, Fabric (Day 5–7)](#7-phase-3--cross-spine-scale-nccl-hpl-fabric-day-57)
8. [Phase 4 — Storage Scale (Day 7–9)](#8-phase-4--storage-scale-day-79)
9. [Phase 5 — Long Soak: DeepSeek-V3 Pretraining (Day 9–16)](#9-phase-5--long-soak-deepseek-v3-pretraining-day-916)
10. [Phase 6 — Multi-Job Interference (Day 16–18)](#10-phase-6--multi-job-interference-day-1618)
11. [Phase 7 — Aged-FS Regression (Day 18–20)](#11-phase-7--aged-fs-regression-day-1820)
12. [Phase 8 — Diagnostic Bundle Delivery & Sign-off (Day 20)](#12-phase-8--diagnostic-bundle-delivery--sign-off-day-20)
13. [Contractual Thresholds — Single-Page Summary](#13-contractual-thresholds--single-page-summary)
14. [Open-Source Tooling Reference](#14-open-source-tooling-reference)
15. [Operational Runbook During Soak](#15-operational-runbook-during-soak)
16. [Failure Mode Catalog](#16-failure-mode-catalog)
17. [Code Map: What Lives Where](#17-code-map-what-lives-where)
18. [Glossary](#18-glossary)

---

## 1. Purpose & Scope

A modern GPU cluster has roughly seven independent things that can be
broken at delivery, any one of which kills training:

1. The GPUs themselves (HBM, NVLink, compute).
2. The intra-node interconnect (NVSwitch, NVLink topology).
3. The inter-node interconnect (NICs, IB switches, cables, FEC margin).
4. The storage subsystem (bandwidth, metadata ops/sec, GDS path).
5. The software stack (driver, CUDA, NCCL, FM, OFED — version skew).
6. The host (CPU, NUMA, RAM, NVMe, BMC, PTP).
7. The power and thermal envelope (PSUs, cooling, PDU phase balance).

This document specifies what we test, in what order, to what threshold,
on every cluster we accept — and how we keep validating that cluster
month after month. Every test maps to one of these seven failure
surfaces.

The document is also written so that a new engineer can read it cold and
understand exactly what a "pre-FEC BER" or "MFU" or "SHARP" is, by
referring to the glossary.

## 2. Philosophy: How We Validate a Cluster

We hold to five principles. They are why our test plan looks the way it
does, and why the order matters.

**Find failures in the smallest test that can find them.** A bad HBM
stack shows up at single-GPU scale; you don't need 1024 GPUs to find it.
We run per-GPU tests before per-node, per-node before per-rack, per-rack
before full-scale. This minimises the time wasted re-running expensive
scale tests when a single node was the culprit.

**Compare against the cohort, not against a number.** Acceptance
thresholds in vendor spec sheets are theoretical maxima; what matters is
whether *this* GPU performs like the other 1023 GPUs you bought. Most
of our tests flag outliers based on cohort statistics (median, std,
z-score) in addition to absolute thresholds. A GPU that is 1% slower
than its siblings is a problem even if it passes the spec sheet.

**Gate phases. No early peeking.** A node that fails Phase 1 (per-node
qualification) must be replaced or quarantined before Phase 2 begins.
Letting a known-bad node into a scale test wastes time and corrupts
results.

**Make every test produce structured data.** No test is allowed to
output only PASS/FAIL. Every script emits JSON with the raw metrics.
This is how we (a) detect cohort outliers, (b) build the contractual
acceptance bundle, (c) compare today's run against last quarter's run.

**The soak is the boss test.** All the synthetic benchmarks in the
world don't prove the cluster can run training. The 7-day DeepSeek-V3
soak under realistic load — with fault injection, checkpointing, and
multi-job interference — is the only test whose result we trust as
predictive of production behaviour. Everything before the soak exists
to make the soak more likely to succeed; nothing replaces it.

## 3. The Eight Phases of Cluster Health Validation

| # | Phase                                | Duration | Goal                                                        | State            |
|---|--------------------------------------|----------|-------------------------------------------------------------|------------------|
| 0 | Pre-Commission                       | Day 0    | Cable inventory, firmware pinning, BMC reachability         | `[IMPLEMENTED]`  |
| 1 | Per-Node Qualification Gate          | Day 1–3  | Every node within 1% of cohort on intra-node tests          | `[IMPLEMENTED]`  |
| 2 | Intra-Rack Scale                     | Day 3–5  | NCCL & fabric tests at 8, 16, 32, 64 GPUs                   | `[NOT-YET-IMPLEMENTED]` |
| 3 | Cross-Spine Scale: NCCL + HPL        | Day 5–7  | Full-cluster NCCL/HPL/HPL-MxP/HPCG, all-pairs IB matrix     | `[PARTIAL via dgxc]` |
| 4 | Storage Scale                        | Day 7–9  | IOR/mdtest/MLPerf-Storage at 1024 clients, GDS dataloader   | `[NOT-YET-IMPLEMENTED]` |
| 5 | Long Soak: DeepSeek-V3 Pretrain      | Day 9–16 | 7-day continuous training with fault injection              | `[PARTIAL via dgxc]` |
| 6 | Multi-Job Interference               | Day 16–18| Mixed-load fairness, MoE+DP collision, storage contention   | `[PARTIAL via dgxc]` |
| 7 | Aged-FS Regression                   | Day 18–20| Fill FS to 70%, age, re-run storage baseline                | `[NOT-YET-IMPLEMENTED]` |
| 8 | Diagnostic Bundle Delivery & Sign-off| Day 20   | Hand over all raw data and pass/fail report                 | `[PARTIAL]`      |

The "State" column indicates what code exists today in this repository.
`[IMPLEMENTED]` means runnable, `[PARTIAL]` means scaffolding exists,
`[PARTIAL via dgxc]` means part of the test pack is covered by upstream
recipes in [NVIDIA/dgxc-benchmarking](https://github.com/NVIDIA/dgxc-benchmarking)
and we wrap them with a thin integration layer (still tracked in
[TODO.md](TODO.md) under the `WRAPS-DGXC` marker),
`[NOT-YET-IMPLEMENTED]` means we have the spec but the code is in
[TODO.md](TODO.md) waiting to be written.

### Before running any phase: bootstrap

Every phase has dependencies — apt packages, pip libraries, source-built
workloads, and vendor-supplied components (driver, OFED, DCGM, fabric
manager). All of these are installed by a single idempotent script:

```bash
cd bootstrap
sudo ./install.sh           # installs everything for every implemented phase
./install.sh verify         # check-only: lists what's missing without installing
```

Run it on the management host (gives you `ibnetdiscover`, `ipmitool`,
and the aggregator Python deps) and on every compute node (also builds
`nvbandwidth`, `gpu-burn`, `nccl-tests`, `BabelStream` into
`/opt/qualification/bin/`). Re-running is safe; each step skips if its
output is already in place. See
[`bootstrap/README.md`](bootstrap/README.md) for the full list of what
gets installed and how to add a block when new phases land.

---

## 4. Phase 0 — Pre-Commission

State: **`[IMPLEMENTED]`** in [`phase0-precommission/`](phase0-precommission/).

Things to lock down **before** the cluster is powered on for the first
production workload. Three of the six items have automated sweeps; the
remaining three are vendor-coordination items by design.

Launch with:

```bash
# Pre-flight (one-time, idempotent):
cd ../bootstrap && sudo ./install.sh phase0   # or ./install.sh verify

cd phase0-precommission
# Populate nodes.txt, bmc_hosts.txt, and edit env.sh first.
./run_all.sh                 # firmware → cables → BMC → report
```

The orchestrator writes timestamped raw outputs under `${P0_RESULTS}` and
produces a final `PHASE0_REPORT.md` with an overall PASS / WARN / FAIL
verdict. See [`phase0-precommission/README.md`](phase0-precommission/README.md)
for the full runbook.

| Test                          | What it checks                                                                          | Pass criterion                                                                 | Code |
|-------------------------------|-----------------------------------------------------------------------------------------|--------------------------------------------------------------------------------|------|
| 0.1 Bill of materials reconciliation | Every node, GPU, NIC, switch, cable matches the purchase order                  | Zero mismatches against PO                                                     | `[NOT-YET-IMPLEMENTED — manual checklist; see TODO.md §0.1]` |
| 0.2 Firmware pinning          | All BIOS / BMC / NIC / VBIOS / driver / FM / OFED / kernel-module versions identical across nodes; matched against vendor manifest | Zero drift vs `expected_firmware.yaml` (or vs cohort majority on first run) | [`phase0-precommission/firmware_baseline.sh`](phase0-precommission/firmware_baseline.sh) + [`aggregate/firmware_diff.py`](phase0-precommission/aggregate/firmware_diff.py) |
| 0.3 Cable inventory           | Per-port link state, width (4x), speed (NDR), pre-FEC BER; cross-checked against expected rack→leaf map | All ports Active/NDR/4x; pre-FEC BER ≤ 1e-7; topology matches vendor cable map | [`phase0-precommission/cable_inventory.sh`](phase0-precommission/cable_inventory.sh) + [`aggregate/cable_validate.py`](phase0-precommission/aggregate/cable_validate.py) |
| 0.4 BMC / IPMI sweep          | Reachability of every BMC; power state, sensor health, recent SEL, FRU serial, BMC firmware version | 100% of BMCs reachable; 0 bad sensors; 0 critical SEL in last 24h           | [`phase0-precommission/bmc_sweep.sh`](phase0-precommission/bmc_sweep.sh) + [`aggregate/bmc_summary.py`](phase0-precommission/aggregate/bmc_summary.py) |
| 0.5 PTP / NTP topology        | Time-sync hierarchy designed, GMC redundant, all nodes peer to two stratum-1 sources    | Documented architecture diagram                                                | `[NOT-YET-IMPLEMENTED — manual design; see TODO.md §0.5]` |
| 0.6 Power & cooling commissioning | PDU phase balance, CRAH/CRAC capacity vs. expected load (~10 kW/node)              | Vendor sign-off on facilities                                                  | Out of scope for this repo |

The three automated tests share a common JSON-fragment-per-host format
emitted by `p0_emit` in [`phase0-precommission/env.sh`](phase0-precommission/env.sh),
mirroring the Day-1 `qual_emit` style so the aggregator pipelines look
familiar. Each sweep writes into a timestamped subdirectory and updates
a `.firmware_latest` / `.cables_latest` / `.bmc_latest` pointer so
re-running individual sweeps is safe.

## 5. Phase 1 — Per-Node Qualification Gate (Day 1–3)

State: **`[IMPLEMENTED]`** in [`day1-qualification/`](day1-qualification/).

The first 72 hours. Every node runs the same battery of single-node
tests in parallel. The goal is to identify and quarantine any node that
is not within ~1% of the cohort median on key metrics, or that fails
any hard check outright. Failing nodes go back to the vendor before
Phase 2 begins.

Launch with:

```bash
# Pre-flight on each node (one-time, idempotent — builds the four workloads):
cd ../bootstrap && sudo ./install.sh phase1   # or ./install.sh verify

cd day1-qualification
sbatch slurm/qualify_all_nodes.sbatch
```

The orchestrator runs all ten checks per node, emits structured JSON,
and feeds [`aggregate/cohort_analysis.py`](day1-qualification/aggregate/cohort_analysis.py)
which flags outliers. The final Markdown report is produced by
[`aggregate/report.py`](day1-qualification/aggregate/report.py).

### Phase 1 test catalogue

| # | Test                       | What it catches                                                                   | Pass criterion                                                              | Script |
|---|----------------------------|-----------------------------------------------------------------------------------|-----------------------------------------------------------------------------|--------|
| 1.1 | Node sanity              | GPU count, model, mem size, persistence mode, ECC, MIG off, dmesg XIDs            | 8× B200, 192 GB, persistence/ECC on, MIG off, 0 critical XIDs               | [`checks/01_node_sanity.sh`](day1-qualification/checks/01_node_sanity.sh) |
| 1.2 | Firmware inventory       | Driver / CUDA / NCCL / FM / OFED / BIOS / BMC / NIC FW versions                   | All nodes identical to pinned versions in `env.sh`                          | [`checks/02_firmware_inventory.sh`](day1-qualification/checks/02_firmware_inventory.sh) |
| 1.3 | DCGM diagnostic          | NVIDIA's official validation suite (NVVS); HBM stress, GEMM, NVLink, ECC          | `dcgmi diag -r 4` and EUD plugin both PASS on every node                    | [`checks/03_dcgm_diag.sh`](day1-qualification/checks/03_dcgm_diag.sh) |
| 1.4 | nvbandwidth              | Intra-node P2P (NVLink), H2D, D2H bandwidth                                       | P2P bidir min ≥ 1700 GB/s; H2D/D2H within 2% of cohort median               | [`checks/04_nvbandwidth.sh`](day1-qualification/checks/04_nvbandwidth.sh) |
| 1.5 | HBM bandwidth            | Per-GPU HBM3e bandwidth (BabelStream triad)                                       | ≥ 7000 GB/s per GPU; no intra-node outlier > 2% below median                | [`checks/05_hbm_bandwidth.sh`](day1-qualification/checks/05_hbm_bandwidth.sh) |
| 1.6 | GPU burn                 | 30-min thermal/power stress (FP16 GEMM loop)                                      | 0 errors; max temp ≤ 85°C; 0 thermal throttle events; 0 new SBE             | [`checks/06_gpu_burn.sh`](day1-qualification/checks/06_gpu_burn.sh) |
| 1.7 | Intra-node NCCL          | 8-GPU all_reduce + alltoall, topology detection, SHARP path                       | AR busbw at 8 GiB ≥ 380 GB/s; topology shows expected NVL rails             | [`checks/07_intra_node_nccl.sh`](day1-qualification/checks/07_intra_node_nccl.sh) |
| 1.8 | IB / fabric health       | Per-NIC link width, speed, pre-FEC BER, symbol errors                             | Link 4x NDR; pre-FEC BER ≤ 1e-7; 0 symbol errors                            | [`checks/08_ib_health.sh`](day1-qualification/checks/08_ib_health.sh) |
| 1.9 | IB loopback bandwidth    | `ib_write_bw` host-mem and GPU-mem (GDR) per NIC pair                              | ≥ 380 Gb/s; GDR ratio ≥ 0.97 vs host-mem                                    | [`checks/09_ib_loopback_bw.sh`](day1-qualification/checks/09_ib_loopback_bw.sh) |
| 1.10 | Host health             | NUMA topology, NVMe SMART, PTP offset, hugepages, host RAM                        | Expected NUMA; SMART clean; PTP offset within ±100 µs                       | [`checks/10_host_health.sh`](day1-qualification/checks/10_host_health.sh) |

Gate decision is computed by
[`aggregate/report.py`](day1-qualification/aggregate/report.py): a node
**FAILs** if it has any hard-failed check OR ≥ 2 cohort-outlier metrics.
One outlier is **WARN** (do not deploy until investigated). All other
nodes **PASS**.

## 6. Phase 2 — Intra-Rack Scale (Day 3–5)

State: **`[NOT-YET-IMPLEMENTED]`** — spec below; tracked in [TODO.md §2](TODO.md).

Once every node has passed Phase 1, we scale up to 8, 16, 32, and 64
GPUs — i.e. within a single leaf / rail group. This catches problems
that appear only once you cross the NVSwitch boundary onto the IB
fabric but stays within a single failure domain. If something breaks at
this scale, it is almost always one cable, one NIC, or one switch port.

### Phase 2 test catalogue

| # | Test                       | What it catches                                                                   | Pass criterion                                                              | Script |
|---|----------------------------|-----------------------------------------------------------------------------------|-----------------------------------------------------------------------------|--------|
| 2.1 | NCCL sweep at 8/16/32/64 | Bandwidth degradation curve as we cross 1, 2, 4, 8-node boundaries                | Busbw at each scale within published targets; smooth, monotonic curve       | `[NOT-YET-IMPLEMENTED — phase2-intra-rack/nccl_sweep.sh]` |
| 2.2 | Small-message sweep      | Latency-dominated regime exposes bad routes that BW tests miss                    | Smooth, monotonic curve from 8 B to 1 GB                                    | `[NOT-YET-IMPLEMENTED — phase2-intra-rack/nccl_small_msg.sh]` |
| 2.3 | Rail-isolated all-reduce | Run on `8 ranks × N nodes` where each rank uses only one rail                     | Each rail within 1% of cohort                                               | `[NOT-YET-IMPLEMENTED — phase2-intra-rack/rail_isolated.sh]` |
| 2.4 | ClusterKit pair matrix   | All-pairs IB bandwidth + latency within rack                                      | Every (src, dst) within 5% of theoretical line rate; heatmap clean          | `[NOT-YET-IMPLEMENTED — phase2-intra-rack/clusterkit_intra.sh]` |
| 2.5 | OSU intra-rack           | MPI orthogonal sanity (osu_allreduce, osu_alltoall, osu_bibw)                     | Within 3% of NCCL numbers                                                   | `[NOT-YET-IMPLEMENTED — phase2-intra-rack/osu_intra.sh]` |
| 2.6 | Topology dump diff       | `NCCL_TOPO_DUMP_FILE` matches the intended rail-optimised topology                | Exact match against the vendor-supplied reference XML                       | `[NOT-YET-IMPLEMENTED — phase2-intra-rack/topo_check.sh]` |

## 7. Phase 3 — Cross-Spine Scale: NCCL, HPL, Fabric (Day 5–7)

State: **`[NOT-YET-IMPLEMENTED]`** — spec below; tracked in [TODO.md §3](TODO.md).

Full-cluster scale (256, 512, 1024 GPUs). Everything in your original
contract plan plus the corrections from the review. This is where we
catch spine/leaf imbalances, adaptive-routing misconfiguration, SHARP
issues, and the long tail of fabric pathologies.

### Phase 3 test catalogue

| # | Test                       | What it catches                                                                   | Pass criterion                                                              | Script |
|---|----------------------------|-----------------------------------------------------------------------------------|-----------------------------------------------------------------------------|--------|
| 3.1 | NCCL all-5 at 256/512/1024 | all_reduce, reduce_scatter, all_gather, alltoall, sendrecv                       | At 1024 GPUs: all_reduce busbw ≥ 400 GB/s; no >5% cliff between 64 and 1024 | `[WRAPS-DGXC — phase3-fullscale/nccl_sweep.sh wraps llmb-run submit -w nccl --scale 1024]` |
| 3.2 | NCCL variance test       | 100 back-to-back full-cluster all_reduces                                         | std-dev < 2% of mean; p99/p50 ≤ 1.05                                        | `[WRAPS-DGXC — phase3-fullscale/nccl_variance.sh loops the dgxc nccl recipe 100×]` |
| 3.3 | SHARP on/off              | In-network reduction working as advertised                                        | `NCCL_COLLNET_ENABLE=1` faster than 0 by expected margin; SHARP log present  | `[WRAPS-DGXC — phase3-fullscale/sharp_compare.sh runs dgxc nccl recipe with NCCL_COLLNET_ENABLE=0 and =1]` |
| 3.4 | All-pairs IB sweep       | (src NIC, dst NIC) bandwidth heatmap at 1024 GPUs                                 | Every pair within 5% of line rate; no cold spots                            | `[NOT-YET-IMPLEMENTED — phase3-fullscale/clusterkit_fullscale.sh]` |
| 3.5 | Adaptive routing test    | Bandwidth under intentional spine-collision pattern, AR on vs off                 | AR recovers ≥ 80% of uncongested BW                                         | `[NOT-YET-IMPLEMENTED — phase3-fullscale/ar_congestion.sh]` |
| 3.6 | IB latency sweep         | `ib_write_lat` / `ib_read_lat` within leaf and across spine                       | ≤ 1.2 µs intra-leaf, ≤ 1.8 µs cross-spine                                   | `[NOT-YET-IMPLEMENTED — phase3-fullscale/ib_latency.sh]` |
| 3.7 | FEC / BER capture        | `mlxlink` pre-FEC and post-FEC BER captured at start and end of phase             | Pre-FEC BER ≤ 1e-7 on every port; 0 post-FEC errors                         | `[NOT-YET-IMPLEMENTED — phase3-fullscale/fec_sweep.sh]` |
| 3.8 | HPL FP64                 | High-Performance Linpack at full scale                                            | ≥ 60% of theoretical FP64 peak                                              | `[NOT-YET-IMPLEMENTED — phase3-fullscale/hpl_fp64.sh]` |
| 3.9 | HPL-MxP                  | Mixed-precision HPL (AI-friendly Linpack)                                         | Within 5% of NVIDIA's published B200 reference for the same node count     | `[NOT-YET-IMPLEMENTED — phase3-fullscale/hpl_mxp.sh]` |
| 3.10 | HPCG                    | Memory-bound HPCG                                                                 | ≥ 3% of HPL peak                                                            | `[NOT-YET-IMPLEMENTED — phase3-fullscale/hpcg.sh]` |
| 3.11 | UFM telemetry snapshot  | Full UFM export at start and end of phase                                         | No port renegotiated to lower speed during phase                            | `[NOT-YET-IMPLEMENTED — phase3-fullscale/ufm_snapshot.sh]` |

## 8. Phase 4 — Storage Scale (Day 7–9)

State: **`[NOT-YET-IMPLEMENTED]`** — spec below; tracked in [TODO.md §4](TODO.md).

Storage acceptance is where teams most often skip the hard parts and
then suffer for years afterward. The two things we *must* verify are
(a) sustained checkpoint bandwidth at full cluster scale, and (b)
metadata operation rate when 1024 ranks open dataset shards
simultaneously. Without these the soak will appear to fail for "no
reason".

### Phase 4 test catalogue

| # | Test                       | What it catches                                                                   | Pass criterion                                                              | Script |
|---|----------------------------|-----------------------------------------------------------------------------------|-----------------------------------------------------------------------------|--------|
| 4.1 | IOR sequential at 1024  | Aggregate read + write bandwidth                                                  | Read ≥ vendor-spec'd TB/s; sustained, not peak                              | `[NOT-YET-IMPLEMENTED — phase4-storage/ior_sequential.sh]` |
| 4.2 | mdtest at 1024 ranks    | Metadata create/stat/open throughput                                              | ≥ 200k creates/sec for a global namespace                                   | `[NOT-YET-IMPLEMENTED — phase4-storage/mdtest.sh]` |
| 4.3 | FIO mixed                | Per-client random IOPS, low-queue-depth latency                                   | Per-client ≥ 50k IOPS; tail latency P99 < 1 ms                              | `[NOT-YET-IMPLEMENTED — phase4-storage/fio_mixed.sh]` |
| 4.4 | Elbencho with GDS        | GPUDirect Storage path bandwidth                                                  | Within 90% of network-layer line rate per NIC                               | `[NOT-YET-IMPLEMENTED — phase4-storage/elbencho_gds.sh]` |
| 4.5 | MLPerf Storage           | Realistic dataloader I/O patterns (Unet3D / ResNet50 / CosmoFlow)                 | Vendor reference numbers for the model                                      | `[NOT-YET-IMPLEMENTED — phase4-storage/mlperf_storage.sh]` |
| 4.6 | Checkpoint write storm   | 1024 GPUs simultaneously writing a DeepSeek-V3-sized shard                        | ≥ 22 GB/s sustained aggregate; 60s end-to-end                               | `[NOT-YET-IMPLEMENTED — phase4-storage/ckpt_storm.sh]` |
| 4.7 | Noisy-neighbour          | Checkpoint storm during dataloader reads                                          | Read tail latency P99 ≤ 2× baseline                                         | `[NOT-YET-IMPLEMENTED — phase4-storage/noisy_neighbor.sh]` |
| 4.8 | GDS dataloader path      | Real PyTorch `cufile` dataloader from real shard set                              | ≥ 80% of cached (RAM) tokens/sec                                            | `[NOT-YET-IMPLEMENTED — phase4-storage/gds_dataloader.py]` |

## 9. Phase 5 — Long Soak: DeepSeek-V3 Pretraining (Day 9–16)

State: **`[NOT-YET-IMPLEMENTED]`** — spec below; tracked in [TODO.md §5](TODO.md).

The single most important test in the entire acceptance. Seven days of
continuous DeepSeek-V3 pretraining on all 1024 GPUs, with checkpointing,
fault injection, and full telemetry capture. If this passes, you have a
cluster that will run training. If it fails, no amount of synthetic
benchmark success matters.

### Phase 5 test catalogue

| # | Test                       | What it catches                                                                   | Pass criterion                                                              | Script |
|---|----------------------------|-----------------------------------------------------------------------------------|-----------------------------------------------------------------------------|--------|
| 5.1 | Throughput baseline      | Tokens/sec/GPU and MFU at start of soak                                           | ≥ 2500 tok/s/GPU AND MFU ≥ 40% (BF16) — both, not either                    | `[WRAPS-DGXC — phase5-soak/launch_deepseek.sh wraps llmb-run submit -w deepseek_v3 --scale 1024]` |
| 5.2 | Step-time variance       | P99 / P50 step time across the full soak                                          | ≤ 1.05 throughout                                                            | `[NOT-YET-IMPLEMENTED — phase5-soak/step_variance.py]` |
| 5.3 | Straggler detection      | Per-GPU step contribution variance                                                | No GPU > 2σ from cohort for > 5 consecutive steps                           | `[NOT-YET-IMPLEMENTED — phase5-soak/straggler_detect.py]` |
| 5.4 | Checkpoint write         | Hourly checkpoint dump                                                            | Complete in 60s; bit-exact verification on read-back                        | `[NOT-YET-IMPLEMENTED — phase5-soak/ckpt_verify.py]` |
| 5.5 | Restart-from-checkpoint  | Resume training from a checkpoint                                                 | Resume within 5 min; converge to same loss curve within 100 steps           | `[NOT-YET-IMPLEMENTED — phase5-soak/restart_drill.sh]` |
| 5.6 | Fault injection: node    | Kill one full node mid-training                                                   | Detection ≤ 60s; restart ≤ 5 min; tokens-lost ≤ 1 step                      | `[NOT-YET-IMPLEMENTED — phase5-soak/inject_node_failure.sh]` |
| 5.7 | Fault injection: NIC     | Force one NIC port-flap                                                           | NCCL recovers; job survives                                                 | `[NOT-YET-IMPLEMENTED — phase5-soak/inject_nic_flap.sh]` |
| 5.8 | Fault injection: GPU ECC | Force ECC throttle on one GPU                                                     | Surfaced in DCGM; scheduler drains the node                                 | `[NOT-YET-IMPLEMENTED — phase5-soak/inject_ecc_throttle.sh]` |
| 5.9 | XID / ECC accounting     | All XID events; SBE growth rate; DBE count                                        | 0 DBE; SBE flat per GPU; ≤ 1 critical XID per GPU over 7d                   | `[NOT-YET-IMPLEMENTED — phase5-soak/xid_collector.py]` |
| 5.10 | Power & thermal         | Sustained per-node power, GPU edge & HBM temp                                     | No throttling; no >5°C creep over 7d                                        | `[NOT-YET-IMPLEMENTED — phase5-soak/power_temp_monitor.py]` |
| 5.11 | Memory-leak detection   | RSS of `nvidia-persistenced`, `nv-fabricmanager`, kernel processes                | < 10 MB/day growth after 24h warm-up                                        | `[NOT-YET-IMPLEMENTED — phase5-soak/memleak_monitor.py]` |
| 5.12 | NVSwitch counters       | Link CRC errors, replay counters, route-table health                              | 0 CRC growth; 0 replay growth                                               | `[NOT-YET-IMPLEMENTED — phase5-soak/nvswitch_telemetry.py]` |
| 5.13 | IB symbol-error growth  | Per-port symbol-error counter delta                                               | 0 symbol errors on > 99% of ports                                           | `[NOT-YET-IMPLEMENTED — phase5-soak/ib_symerr_track.py]` |
| 5.14 | PTP drift               | PTP offset histogram over 7d                                                      | Always within ±100 µs                                                       | `[NOT-YET-IMPLEMENTED — phase5-soak/ptp_drift.py]` |
| 5.15 | Soak summary             | Composite dashboard + final report                                                | All targets met for ≥ 95% of soak duration                                  | `[NOT-YET-IMPLEMENTED — phase5-soak/soak_report.py]` |

## 10. Phase 6 — Multi-Job Interference (Day 16–18)

State: **`[NOT-YET-IMPLEMENTED]`** — spec below; tracked in [TODO.md §6](TODO.md).

Production rarely runs one job at a time. We validate that the
scheduler, the fabric, and the storage system handle realistic workload
mixes without one job starving another.

### Phase 6 test catalogue

| # | Test                       | What it catches                                                                   | Pass criterion                                                              | Script |
|---|----------------------------|-----------------------------------------------------------------------------------|-----------------------------------------------------------------------------|--------|
| 6.1 | 512 train + 512 infer    | Mixed training/inference contention                                               | Training step-time degradation ≤ 5%; inference P99 latency degradation ≤ 10%| `[WRAPS-DGXC — phase6-multijob/mixed_load.sh launches dgxc deepseek_v3 training + deepseek_r1 inference concurrently]` |
| 6.2 | 512 + 512 dual training  | Two independent training jobs                                                     | Both within 3% of solo throughput                                           | `[WRAPS-DGXC — phase6-multijob/dual_train.sh launches two dgxc deepseek_v3 jobs concurrently]` |
| 6.3 | 64 + 960 small + large   | Small interactive vs large training                                               | Small job latency unaffected; large within 3% of solo                       | `[NOT-YET-IMPLEMENTED — phase6-multijob/small_large.sh]` |
| 6.4 | DP-heavy + MoE-heavy     | All-reduce-heavy + all-to-all-heavy collective collision (MoE is DeepSeek's case) | Neither job > 5% slower than solo                                           | `[NOT-YET-IMPLEMENTED — phase6-multijob/dp_moe_collide.sh]` |
| 6.5 | Training + storage storm | Training + checkpoint storm + heavy logging                                       | Training step-time degradation ≤ 5%                                         | `[NOT-YET-IMPLEMENTED — phase6-multijob/train_plus_storm.sh]` |

## 11. Phase 7 — Aged-FS Regression (Day 18–20)

State: **`[NOT-YET-IMPLEMENTED]`** — spec below; tracked in [TODO.md §7](TODO.md).

A pristine filesystem performs differently from one that has seen
months of mixed workload. We accelerate ageing artificially and re-run
the Phase 4 baseline.

| # | Test                  | What it checks                                                          | Pass criterion                                                          | Script |
|---|-----------------------|--------------------------------------------------------------------------|-------------------------------------------------------------------------|--------|
| 7.1 | Fill to 70%         | Drive the FS to 70% utilisation with realistic dataset shard mix         | Reached, with realistic per-file size distribution                      | `[NOT-YET-IMPLEMENTED — phase7-aging/fill_to_70.sh]` |
| 7.2 | 5-day mixed ageing  | Create/delete/append loop, 5 days continuous                              | Completes without FS errors                                              | `[NOT-YET-IMPLEMENTED — phase7-aging/age_loop.sh]` |
| 7.3 | Phase-4 re-run      | Re-execute every Phase 4 test post-ageing                                 | < 5% regression on every metric                                         | `[NOT-YET-IMPLEMENTED — phase7-aging/rerun_phase4.sh]` |

## 12. Phase 8 — Diagnostic Bundle Delivery & Sign-off (Day 20)

State: **`[PARTIAL]`** — bundling logic exists for Phase 1; missing for 2–7.

Acceptance is not complete until the vendor has handed over and we have
archived a single tarball containing every raw artefact from every
phase. This is what backs up future warranty claims.

The bundle MUST contain (at minimum):

- All per-node JSON outputs from Phase 1 ([day1-qualification/results/](day1-qualification/results/))
- All NCCL test logs from Phases 2 and 3
- The complete IB counter snapshot pre/post each phase (`ibdiagnet`, `mlxlink`)
- DCGM telemetry export for the entire soak (Phase 5)
- The training run's loss curves, per-step throughput, MFU, and step-time histograms
- All XID events (raw dmesg + parsed JSON)
- UFM telemetry export
- Final Markdown report from each phase's `aggregate/report.py`

Sign-off script: `[NOT-YET-IMPLEMENTED — sign-off/bundle.sh]`.

## 13. Contractual Thresholds — Single-Page Summary

This table is the contract. Vendors deliver to numbers, not paragraphs.

| Dimension              | Metric                                       | Threshold                          |
|------------------------|----------------------------------------------|------------------------------------|
| Per-GPU HBM            | BabelStream triad                            | ≥ 7000 GB/s, within 2% of cohort   |
| Per-GPU FP64 GEMM      | cuBLAS peak                                  | ≥ 35 TFLOPS                        |
| Intra-node NVLink P2P  | nvbandwidth bidir min                        | ≥ 1700 GB/s                        |
| Intra-node 8-GPU AR    | NCCL all_reduce busbw at 8 GiB               | ≥ 380 GB/s                         |
| NIC line rate          | `ib_write_bw`                                | ≥ 380 Gb/s host-mem                |
| GDR ratio              | `--use_cuda` / host-mem                      | ≥ 0.97                             |
| IB pre-FEC BER         | per port                                     | ≤ 1e-7                             |
| IB symbol errors       | per port                                     | 0 on > 99% of ports                |
| IB latency intra-leaf  | `ib_write_lat`                               | ≤ 1.2 µs                           |
| IB latency cross-spine | `ib_write_lat`                               | ≤ 1.8 µs                           |
| 1024-GPU AR            | NCCL all_reduce busbw at 1 GB+               | ≥ 400 GB/s                         |
| 1024-GPU AR variance   | std-dev / mean across 100 runs               | < 2%                               |
| AR p99/p50             | ratio across 100 runs                        | ≤ 1.05                             |
| HPL FP64               | % of theoretical peak                        | ≥ 60%                              |
| HPL-MxP                | vs NVIDIA reference                          | within 5%                          |
| HPCG                   | % of HPL peak                                | ≥ 3%                               |
| Storage bandwidth      | IOR sequential at 1024 clients               | vendor TB/s spec sustained         |
| Metadata throughput    | mdtest creates/sec                           | ≥ 200k                             |
| Checkpoint bandwidth   | sustained write during DeepSeek dump         | ≥ 22 GB/s aggregate; ≤ 60s total   |
| Training throughput    | DeepSeek-V3 tok/s/GPU + MFU                  | ≥ 2500 tok/s/GPU AND MFU ≥ 40%     |
| Step-time variance     | P99/P50 over 7-day soak                      | ≤ 1.05                             |
| Power                  | sustained per-node                           | within PDU envelope, no throttling |
| GPU temp               | edge / HBM, sustained                        | ≤ 75°C / ≤ 90°C, no creep > 5°C    |
| ECC DBE                | over 7-day soak                              | 0                                  |
| Critical XIDs          | per GPU over 7-day soak                      | ≤ 1                                |
| PTP offset             | per node, any time                           | within ±100 µs                     |

## 14. Open-Source Tooling Reference

Every tool we depend on, where to get it, and what we use it for.

A note on **NVIDIA/dgxc-benchmarking**: NVIDIA recommends this repository
as their standard benchmarking suite for Blackwell clusters. It is the
right tool for running standardised LLM training and inference recipes,
and we adopt it for Phases 3.1–3.3, 5.1, and 6.1–6.2. However, it is a
**performance benchmarking** suite, not a **cluster health** suite. It
does not perform any hardware diagnostic, fabric BER capture, storage
test, fault injection, or cohort-outlier analysis. The two suites are
complementary: dgxc-benchmarking gives us standardised performance
numbers to compare against NVIDIA's published references; everything
else in this document gives us the hardware-health envelope inside
which those numbers are reliable.

### Core NVIDIA stack
- `github.com/NVIDIA/nccl-tests` — the five collective benchmarks (all_reduce, reduce_scatter, all_gather, alltoall, sendrecv). Used in Phase 1.7, 2.1–2.3, 3.1–3.3.
- `github.com/NVIDIA/nccl` — the library itself; build from source for SHARP / collnet debug.
- `github.com/NVIDIA/DCGM` — `dcgmi diag` and the NVVS validation suite. Used in Phase 1.3, 5.9.
- `github.com/NVIDIA/dcgm-exporter` — Prometheus exporter; used as the soak telemetry backbone (Phase 5).
- `github.com/NVIDIA/nvbandwidth` — intra-node bandwidth matrix. Phase 1.4.
- `github.com/NVIDIA/cuda-samples` — `bandwidthTest`, `p2pBandwidthLatencyTest`, `deviceQuery`.
- `github.com/NVIDIA/nvidia-hpc-benchmarks` (and NGC `nvcr.io/nvidia/hpc-benchmarks`) — NVIDIA-tuned HPL / HPL-MxP / HPCG. Phase 3.8–3.10.
- `github.com/NVIDIA/cutlass` — GEMM micro-benchmark.
- `github.com/NVIDIA/MagnumIO` — GDS docs, gdsio source mirror.
- `github.com/NVIDIA/Megatron-LM` — production pretraining stack. Phase 5.
- `github.com/NVIDIA/Megatron-Core` — composable lib version.
- `github.com/NVIDIA/TransformerEngine` — FP8 kernels for Blackwell.
- `github.com/NVIDIA/NeMo`, `github.com/NVIDIA/NeMo-Run` — higher-level recipes and multi-node launcher.
- `github.com/NVIDIA/nvidia-resiliency-ext` — straggler detection, in-job restart. Phase 5.3 & 5.6.
- `github.com/NVIDIA/DALI` — GDS-aware dataloader. Phase 4.8.
- `github.com/NVIDIA/gpu-operator` — K8s integration.
- `github.com/NVIDIA/pyxis`, `github.com/NVIDIA/enroot` — container launch at scale.

### Fabric / RDMA
- `github.com/linux-rdma/perftest` — `ib_write_bw`, `ib_*_lat`, `--use_cuda` for GDR. Phase 1.9, 3.6.
- `github.com/Mellanox/clusterkit` — all-pairs RDMA matrix. Phase 2.4, 3.4.
- `mlnxlink`, `mlxcables`, `mst`, `ibdiagnet` — ship with OFED; FEC/BER tools. Phase 1.8, 3.7, 5.13.
- OSU micro-benchmarks (`mvapich.cse.ohio-state.edu/benchmarks`) — MPI sanity. Phase 2.5.
- `github.com/openucx/ucx` (perftest under `src/tools/perf`) — UCX transport sanity.

### Storage
- `github.com/hpc/ior` — IOR + mdtest. Phase 4.1–4.2, 7.3.
- `github.com/breuner/elbencho` — GDS-aware modern storage benchmark. Phase 4.4.
- `github.com/axboe/fio` — per-client block-level IOPS. Phase 4.3.
- `github.com/mlcommons/storage` — MLPerf Storage. Phase 4.5.

### Stress / thermal
- `github.com/wilicc/gpu-burn` — 30-min thermal stress. Phase 1.6.
- `github.com/UoB-HPC/BabelStream` — HBM bandwidth triad. Phase 1.5.
- `github.com/ekondis/mixbench` — alternative HBM stress.

### Reference / external
- `github.com/NVIDIA/dgxc-benchmarking` — **NVIDIA's officially recommended benchmarking suite for Blackwell-class (GB200/GB300/B200/B300) clusters.** Ships production-grade training recipes (DeepSeek-V3, Llama-3.x, Qwen3, Nemotron, Grok, GPT-OSS) on Megatron-Bridge / NeMo / TorchTitan, inference recipes (TRT-LLM, Dynamo, SGLang), and an NCCL benchmark wrapper. Launches via `llmb-run submit` over Slurm + Pyxis/Enroot. We wrap it for Phase 3.1–3.3 (NCCL), Phase 5.1 (DeepSeek-V3 launcher), and Phase 6.1–6.2 (mixed train+infer). Does NOT cover health/acceptance checks — no DCGM diag, no nvbandwidth, no fabric BER, no HPL, no storage, no fault injection, no cohort outlier detection. Its `microbenchmarks/system_info` is a passive inventory collector, not a diagnostic.
- `github.com/mlcommons/training` and `github.com/mlcommons/training_results_v4.1` — MLPerf training references; `tree/main/NVIDIA` documents how NVIDIA themselves run SuperPOD scale tests.
- `github.com/mlcommons/inference` — MLPerf inference, useful for Phase 6.1.
- `github.com/mlcommons/hpc` — Cosmoflow / OpenCatalyst / DeepCAM.
- `github.com/SemiAnalysisHQ` — ClusterMax methodology writeups; useful as a credibility cross-check on our own plan.
- `github.com/pytorch/torchtitan` — PyTorch reference large-scale training repo; alternative MFU baseline.

## 15. Operational Runbook During Soak

The soak (Phase 5) needs a human on-call rotation. This is what they do.

**Every hour**: confirm `dcgm-exporter` is scraping; confirm training
loss has progressed; confirm checkpoint write succeeded; check the
Grafana "current step-time" panel against the 24h rolling baseline.

**Every 12 hours**: skim XID events; eyeball power and thermal trends;
check per-rail bandwidth dashboard for any one rail running cold.

**On alert**: if step-time variance crosses 5% over 100 steps, page the
on-call. Common root causes in order of probability — slow node
(check straggler detection), bad cable (check IB symbol errors growing
on one port), thermal throttle (check `clocks_event_reasons`),
filesystem stall (check storage tail latency).

**Fault drills** (planned, not unplanned): one per 24h, rotating
between node kill, NIC flap, and ECC injection. Document each drill in
the soak log with detection latency, restart latency, and
tokens-lost-per-failure.

## 16. Failure Mode Catalog

What we have seen go wrong on clusters like this, in order of frequency.

**One bad HBM stack on one GPU.** Presents as one GPU ~12.5% slower on
BabelStream (one of eight stacks down). Phase 1.5 catches it. Vendor
replaces the GPU.

**One bad short-haul cable.** `ib_write_bw` passes, but pre-FEC BER
creeps up. Phase 1.8 catches it. Replace the cable.

**Firmware skew across nodes.** Some nodes shipped with FM 535.x, the
rest with 535.x+1. Phase 1.2 catches it. Vendor reflashes the outliers.

**Wrong rail topology.** GPUs come up but NCCL doesn't see the expected
rail-optimised layout. Phase 2.6 catches it (`NCCL_TOPO_DUMP_FILE` diff
against the reference XML). Vendor fixes node-to-leaf cabling.

**Adaptive routing misconfigured.** All-pairs sweep looks great in
isolation but the moment two collectives collide on the same spine,
throughput collapses. Phase 3.5 catches it. Vendor reconfigures the
subnet manager.

**SHARP daemon misconfigured.** Log line says SHARP "enabled" but
aggregation trees are not actually forming. Phase 3.3 catches it
(falsification test — confirm performance delta, not just log line).

**Bad PDU phase balance.** Cluster runs fine under synthetic load,
trips a breaker under DeepSeek pretrain because three of the four PDU
phases peak together. Phase 5.10 catches it as anomalous power draw.

**Filesystem ageing degrades metadata.** Cluster passes Phase 4 day-1.
Two months later, metadata ops/sec is half of what it was. Phase 7 is
why we accelerate ageing in acceptance.

**Slow GPU emerges mid-soak.** GPU was within 1% on Phase 1 but drifts
to 3% slow over 5 days of training. Phase 5.3 (straggler detection)
catches it; Phase 5.6 (fault injection) verifies the scheduler can
quarantine.

**XID 79 (GPU fell off bus).** Almost always one of: faulty PCIe riser,
loose SXM seating, or a known driver bug at the running version. Phase
5.9 detects; recovery is driver-version-specific.

## 17. Code Map: What Lives Where

```
cluster-health/
├── CLUSTER_HEALTH_REFERENCE.md            # this doc — read first
├── TODO.md                                # tracked list of unimplemented test packs
├── bootstrap/                             # one-time per-host install
│   ├── README.md                          #    runbook + what gets installed
│   └── install.sh                         #    idempotent installer for every phase
├── phase0-precommission/                  # Phase 0 — IMPLEMENTED
│   ├── README.md                          #    how to run the pre-commission sweeps
│   ├── env.sh                             #    paths, creds, thresholds, p0_emit helper
│   ├── run_all.sh                         #    orchestrator: firmware → cables → BMC → report
│   ├── firmware_baseline.sh               #    test 0.2 — fan-out firmware sweep
│   ├── cable_inventory.sh                 #    test 0.3 — IB fabric + per-host cable dump
│   ├── bmc_sweep.sh                       #    test 0.4 — BMC reachability + health
│   ├── helpers/ssh_fanout.sh              #    bounded-parallelism SSH driver
│   ├── aggregate/firmware_diff.py         #    test 0.2 aggregator (vs manifest + cohort)
│   ├── aggregate/cable_validate.py        #    test 0.3 aggregator (link state/width/BER)
│   ├── aggregate/bmc_summary.py           #    test 0.4 aggregator (power/sensors/SEL/FRU)
│   ├── aggregate/report.py                #    overall PASS/WARN/FAIL report
│   ├── reference/expected_firmware.yaml   #    vendor firmware manifest (filled at burn-in)
│   └── reference/expected_topology.yaml   #    expected rack→leaf cable map
├── day1-qualification/                    # Phase 1 — IMPLEMENTED
│   ├── README.md                          #    how to run the per-node gate
│   ├── slurm/qualify_all_nodes.sbatch     #    Slurm array launcher
│   ├── slurm/env.sh                       #    paths, version pins, thresholds
│   ├── run_node.sh                        #    per-node orchestrator
│   ├── checks/01_node_sanity.sh           #    test 1.1
│   ├── checks/02_firmware_inventory.sh    #    test 1.2
│   ├── checks/03_dcgm_diag.sh             #    test 1.3
│   ├── checks/04_nvbandwidth.sh           #    test 1.4
│   ├── checks/05_hbm_bandwidth.sh         #    test 1.5
│   ├── checks/06_gpu_burn.sh              #    test 1.6
│   ├── checks/07_intra_node_nccl.sh       #    test 1.7
│   ├── checks/08_ib_health.sh             #    test 1.8
│   ├── checks/09_ib_loopback_bw.sh        #    test 1.9
│   ├── checks/10_host_health.sh           #    test 1.10
│   ├── aggregate/parse_results.py         #    per-host rollup + cohort gather
│   ├── aggregate/cohort_analysis.py       #    outlier detection
│   └── aggregate/report.py                #    final Markdown report
├── phase2-intra-rack/                     # [NOT-YET-IMPLEMENTED]
├── phase3-fullscale/                      # [NOT-YET-IMPLEMENTED]
├── phase4-storage/                        # [NOT-YET-IMPLEMENTED]
├── phase5-soak/                           # [NOT-YET-IMPLEMENTED]
├── phase6-multijob/                       # [NOT-YET-IMPLEMENTED]
├── phase7-aging/                          # [NOT-YET-IMPLEMENTED]
└── sign-off/                              # [NOT-YET-IMPLEMENTED]
```

The convention for every phase folder mirrors `day1-qualification/`:
each test gets a numbered shell or Python entry point under `checks/`,
results land as structured JSON, and an `aggregate/` directory rolls
results into a Markdown report. This makes the entire system uniform
and easy to extend.

---

## 18. Glossary

Defined in the order a new engineer is most likely to encounter the
term while reading this document or running the scripts.

**GPU acceptance**: the process of validating that a delivered cluster
meets contractual performance, reliability, and homogeneity targets
*before* the customer signs off and the warranty clock starts.

**Cohort**: the set of all units of the same kind in a cluster — e.g.
"the cohort of 1024 GPUs" or "the cohort of 128 nodes". Cohort
comparison means flagging any unit that performs unlike its siblings,
regardless of whether it meets spec.

**B200**: NVIDIA's Blackwell-architecture data centre GPU, SXM5
form-factor, ~1000 W TDP, 192 GB HBM3e per GPU, ~8 TB/s HBM bandwidth.

**SXM**: Server PCI Module — NVIDIA's high-density GPU form-factor
that connects directly to the NVSwitch fabric rather than via PCIe
slot.

**NVLink**: NVIDIA's high-bandwidth point-to-point interconnect between
GPUs. 5th-gen NVLink (on B200) carries ~1.8 TB/s bidirectional per GPU.

**NVSwitch**: the on-board chip that connects every GPU in a node to
every other GPU at full NVLink bandwidth. The 5th-gen NVSwitch on a
B200 node provides ~1.8 TB/s bidirectional any-to-any.

**P2P**: peer-to-peer memory copy between two GPUs. P2P bandwidth is
the headline NVLink number.

**H2D / D2H**: host-to-device / device-to-host memory copy across the
PCIe bus.

**HBM3e**: third-generation High-Bandwidth Memory, "enhanced" variant,
~1.2 TB/s per stack. A B200 has eight stacks for a total of ~8 TB/s.

**NIC**: Network Interface Card. In our context, a Mellanox/NVIDIA
ConnectX-7 or ConnectX-8 InfiniBand HCA, one per GPU on B200 SuperPOD
nodes (8 per node).

**HCA**: Host Channel Adapter — IB-speak for what most people call a
NIC.

**IB**: InfiniBand. The dominant low-latency fabric for AI clusters.
Alternatives are NVIDIA's own custom NVL/NV5 fabric and (rarely for
training) RoCE over Ethernet.

**NDR**: Next Data Rate — the 400 Gb/s generation of InfiniBand
(`4x` lanes at 100 Gb/s each, with PAM4 modulation). The previous gen
is HDR (200 Gb/s) and the next is XDR (800 Gb/s).

**RDMA**: Remote Direct Memory Access — the ability for one machine to
read or write another machine's memory without involving the remote
CPU. The foundational primitive of IB and the reason it's fast.

**GDR / GPUDirect RDMA**: a path where the NIC reads / writes GPU
memory directly, bypassing the CPU and host RAM. Essential for AI
training performance.

**GDS / GPUDirect Storage**: the same idea but for the storage path —
NVMe or networked storage reads land directly in GPU memory.

**RoCE**: RDMA over Converged Ethernet. Cheaper but more finicky than
InfiniBand for the same job.

**OFED**: OpenFabrics Enterprise Distribution. NVIDIA's curated bundle
of IB drivers, libraries, and userland tools. Ships as a `.deb` /
`.rpm`. The `ibstat`, `ib_write_bw`, `mlxlink` tools all come from
here.

**UFM**: Unified Fabric Manager. NVIDIA's web-and-API tool for
managing an InfiniBand fabric — health, routing, performance counters,
firmware updates.

**NMX**: NVIDIA Mission Control / Networking Mission Control — the
newer fabric-management product line. Replaces or augments UFM
depending on cluster generation.

**Fabric Manager (FM)**: the NVIDIA daemon that configures and
monitors NVSwitch chips on each node. Not to be confused with UFM
(which manages IB switches). The binary is `nv-fabricmanager`.

**FEC**: Forward Error Correction. The mechanism that recovers from
single-symbol errors on a serial link without retransmission. NDR
uses RS-FEC.

**BER**: Bit Error Rate. The fraction of bits transmitted that arrive
in error. We care about *pre-FEC BER* (errors before correction —
indicates physical link health) and *post-FEC BER* (errors that
survived correction — should be zero).

**Symbol error**: an uncorrectable error reported by the link layer.
Indicates a cable or transceiver that has run out of FEC margin.

**Pre-FEC BER ≤ 1e-7**: our acceptance threshold. A higher pre-FEC BER
means the cable is operating with little headroom and will fail under
sustained load.

**SHARP**: Scalable Hierarchical Aggregation and Reduction Protocol.
An NVIDIA capability where InfiniBand switches perform collective
reductions (sum-across-all-GPUs) inside the switch fabric instead of
on the GPUs themselves. Can roughly halve all-reduce latency at scale.

**NVLink SHARP**: the analogous capability inside NVSwitch — in-network
reduction on the intra-node fabric. Distinct from SHARP on IB.

**NCCL**: NVIDIA Collective Communications Library. The library every
training framework uses to do all-reduce / all-gather / etc. across
GPUs.

**Collective**: a communication primitive involving more than two
peers. The standard collectives are:
- `all_reduce` — every peer ends up with the sum (or other op) of all peers' inputs.
- `reduce_scatter` — like all_reduce but each peer gets only its slice of the sum.
- `all_gather` — every peer ends up with the concatenation of all peers' inputs.
- `alltoall` — every peer sends a different message to every other peer.
- `sendrecv` — a paired send and receive between two specific peers.

**busbw**: bus bandwidth, the metric NCCL reports. It is computed as
the "logical" bandwidth across the fabric, normalised so different
collectives can be compared. For an all-reduce, `busbw = algbw * 2*(N-1)/N`.

**algbw**: algorithmic bandwidth, the raw user-facing data rate.

**SuperPOD / DGX SuperPOD**: NVIDIA's reference architecture for
multi-rack GPU clusters. Defines the cable layout, switch tiers, rail
optimisation, and software stack.

**Rail / rail-optimised topology**: in a SuperPOD, each GPU in a node
connects to the IB fabric through its own NIC, and each NIC connects
to a different "rail" of leaf switches. Rail i on every node connects
to the same group of leaf switches. The point is to enable collectives
to keep each rail's traffic independent.

**Spine / leaf**: the two tiers of an IB fat-tree fabric. Leaf
switches connect directly to nodes; spine switches connect leaf
switches to each other.

**Adaptive routing (AR)**: the IB subnet manager dynamically picks
which spine path a given packet takes, based on congestion. Without
AR, a single hot spine path can bottleneck the whole fabric.

**ECC**: Error Correcting Code. HBM and GDDR memory ships with extra
bits that let the controller detect and correct single-bit errors
(SBE) and detect double-bit errors (DBE).

**SBE**: Single-Bit ECC Error. Corrected by hardware, but a rising
rate is a leading indicator of a failing HBM stack.

**DBE**: Double-Bit ECC Error. Uncorrectable. A single DBE is a
serious event and almost always means the GPU must be replaced.

**XID**: an NVIDIA hardware/firmware error code emitted to dmesg as
`NVRM: Xid (PCI:xx:yy.z): NN`. The critical ones we watch for are 31
(MMU fault), 43, 45, 61, 63, 64, 74 (NVLink errors), and 79 (GPU fell
off bus).

**Persistence mode**: a setting that keeps the NVIDIA driver loaded
even when no process holds the GPU. Required for low-latency job
startup and stable monitoring.

**MIG**: Multi-Instance GPU. The capability to partition one physical
GPU into smaller isolated instances. Must be **off** for full-cluster
training acceptance.

**DCGM**: Data Center GPU Manager. NVIDIA's first-party telemetry and
diagnostic suite. The `dcgmi diag` command runs the NVVS validation
suite. `dcgm-exporter` is the Prometheus adapter.

**NVVS**: NVIDIA Validation Suite. Lives inside DCGM. Effectively the
official "is this GPU OK?" test suite.

**EUD**: Extended Utility Diagnostics. A DCGM plugin that exercises
HBM more aggressively than `dcgmi diag -r 4`.

**dcgmi diag -r N**: DCGM diagnostic level. `-r 1` is a quick check,
`-r 4` is the most thorough and takes ~25–40 min on B200.

**HPL**: High-Performance Linpack. The classic FP64 dense linear
algebra benchmark used to rank the Top500 supercomputers. Useful for
AI clusters as a homogeneity stress test.

**HPL-MxP** (a.k.a. HPL-AI): a mixed-precision variant of HPL designed
for AI accelerators. Uses FP16/BF16/FP32 in the inner kernel with FP64
refinement. The number we publish to compare against NVIDIA's
reference.

**HPCG**: High-Performance Conjugate Gradient. A memory-bandwidth-bound
counterpart to HPL. Always reports a small fraction of HPL because the
hardware is bandwidth-limited on this kernel.

**MFU**: Model FLOPs Utilisation. The ratio of (FLOPs actually
performed by the model per second) to (theoretical FLOPs the hardware
can do per second). For training, ≥ 40% on BF16 is good. Higher than
throughput in tok/s/GPU because it is invariant to batch size and
parallelism strategy.

**HFU**: Hardware FLOPs Utilisation. A closely related metric that
also counts recomputation and overhead. We track MFU contractually
and HFU diagnostically.

**TP / PP / EP / DP**: parallelism axes used in large-scale training:
- TP = Tensor Parallelism (split a layer across GPUs)
- PP = Pipeline Parallelism (split layers across GPUs)
- EP = Expert Parallelism (split MoE experts across GPUs)
- DP = Data Parallelism (replicate model, split batch)

**MoE**: Mixture of Experts. The architectural pattern DeepSeek-V3 (and
many recent open models) uses, where each token is routed to a small
subset of "expert" sub-networks. Stress-tests the all-to-all
collective heavily, which is why MoE+DP collision is a Phase 6 test.

**MGMN**: Multi-GPU Multi-Node — shorthand for any test that spans
both intra-node and inter-node communication.

**checkpoint**: a periodic dump of model weights, optimiser state, and
training metadata to durable storage. Allows a training job to resume
after a failure without losing more than the most recent interval of
progress.

**straggler**: a single rank (GPU / node) that takes longer than its
peers on a per-step basis. Since the collective at the end of each
step waits for the slowest peer, one straggler wastes all GPUs.

**TDP**: Thermal Design Power. The sustained power draw the cooling
system is designed for. B200 SXM is ~1000 W TDP.

**Thermal throttling**: the GPU lowers its clock rate to stay within
its thermal envelope. Surfaces in DCGM as `PWR_VIOLATION` or
`HW_THERMAL_SLOWDOWN`. Acceptance demands 0 events.

**PDU**: Power Distribution Unit. The rack-mount strip that brings
3-phase AC power to nodes. Phase balance matters: if all three phases
of a PDU draw unequal load, you trip a breaker.

**BMC**: Baseboard Management Controller. The little ARM processor on
the motherboard that lets you remotely power-cycle, monitor sensors,
and view console output. Spoken to via IPMI.

**IPMI**: Intelligent Platform Management Interface. The protocol for
talking to a BMC.

**PTP**: Precision Time Protocol (IEEE 1588). Sub-microsecond clock
synchronisation across nodes. Required for stable training and for
correct telemetry.

**NUMA**: Non-Uniform Memory Access. A multi-socket system where each
CPU has its own local RAM and accesses remote RAM more slowly. Misconfigured
NUMA pinning is one of the most common silent performance killers.

**NVMe**: the storage protocol for SSDs over PCIe. We care about
per-node local NVMe (for scratch / containers / logs) separately from
the shared parallel filesystem.

**Lustre / WekaFS / GPFS / DDN ExaScaler**: the parallel filesystems
typically used for AI training datasets. We are filesystem-agnostic in
this document — the benchmarks (IOR, mdtest, MLPerf-Storage) are
agnostic too.

**IOR**: a parallel filesystem benchmark — measures aggregate
read/write bandwidth. Originally "Interleaved or Random".

**mdtest**: the metadata-operations counterpart to IOR. Measures
creates/sec, opens/sec, stats/sec.

**FIO**: Flexible I/O tester. A general-purpose disk benchmark
ubiquitous in storage qualification.

**Elbencho**: a modern open-source benchmark by Sven Breuner.
GPU-aware via `--cufile` (GDS).

**MLPerf Storage**: an MLCommons benchmark that replays realistic
training I/O patterns (Unet3D, ResNet50, CosmoFlow).

**gpu-burn**: a community CUDA stress test (Ville Timonen). Loops FP16
GEMM at full power for a configurable duration. Used as the thermal-
and power-stress test in Phase 1.6.

**BabelStream**: the GPU port of the STREAM memory-bandwidth benchmark.
We use the CUDA variant for per-GPU HBM bandwidth.

**Slurm**: the workload manager / scheduler used on most HPC and AI
clusters. We use Slurm array jobs to dispatch Phase 1 across all 128
nodes in parallel.

**Pyxis + Enroot**: NVIDIA's container-launch stack for Slurm.
Equivalent to Singularity / Apptainer but tighter integration with
Slurm.

**Cohort outlier**: in this document, a node whose value on a given
metric is either > 1% below the cohort median (for "more is better"
metrics like bandwidth) or > 1% above the cohort median (for "less is
better" metrics like power, temperature, PTP offset), OR more than 3
standard deviations from the cohort mean.

**Gate**: a phase transition that requires all prerequisites to pass
before the next phase begins. We enforce gates between Phase 1 → 2,
2 → 3, 3 → 4, and 4 → 5. After 5, the remaining phases can run in
parallel.
