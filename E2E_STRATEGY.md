# Acceptance strategy — E2E Networks managed platform

> **Status:** planning document on the `e2e` branch. No code has been
> rewritten yet. The bare-metal acceptance work on `main` (Phases 0–4) is
> preserved verbatim; this branch will fork from it once the strategy in
> this document is signed off.

## 1. What changed

The cluster we are testing is no longer a bare-metal handover. The platform
underneath is a managed offering from **E2E Networks**:

- The hardware substrate (compute nodes, IB fabric, parallel filesystem) is
  owned and operated by E2E. We do not get IPMI/BMC, switch shells, port
  telemetry, BIOS exports, or root on the underlying nodes.
- We instantiate compute through a UI **and** a Terraform / public API
  surface. Provisioning is declarative and scriptable.
- For training, we ask for a Slurm cluster; E2E spins it up via
  [Slinky](https://slinky.ai) (Slurm-on-Kubernetes). Slinky is invisible
  to us — we see only `sbatch`, `srun`, `sinfo`, `squeue`.
- For inference and general workloads, we get K8s pods, with pre-built
  images for `transformers`, NeMo, vLLM, TensorRT-LLM, TGI, etc.
- The workload mix that matters for acceptance: **large-scale pre-training
  + production inference**.

## 2. Operating model — tenant, not operator

The most important reframe: **we are now a tenant, not the cluster
operator**. That changes both what we can verify and what we are entitled
to assert as "broken."

| Dimension                      | Bare-metal (old)                                                                    | Managed E2E (new)                                                                                  |
|--------------------------------|---------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------|
| Provisioning                   | Vendor hands over 128 servers; we boot, install, configure                          | We call Terraform / UI; E2E hands back endpoints                                                    |
| Acceptance unit                | The cluster, once at handover                                                       | Every allocation, every time we instantiate                                                         |
| Things we can directly verify  | Firmware, BMC, cables, BIOS, switches, kernel, every package                        | Everything visible from inside a pod (GPU, RDMA endpoint, mounted FS, env, NCCL, container content) |
| Things we cannot verify        | (essentially none, given enough access)                                             | BMC, port-level telemetry, UFM REST, switch FW, BIOS settings, cable maps, subnet manager state    |
| Failure ownership              | We own the cluster post-handover; vendor RMA covers parts                           | E2E owns the substrate; our SLA covers availability + performance bands                            |
| Repeatability                  | Once a config is accepted, it's stable (same machines, same FW)                     | Every allocation may be different nodes, possibly different microcode                              |
| What "sign-off" means          | One-shot, end of acceptance week                                                    | Continuous — re-run on every fresh cluster, plus periodic on long-lived clusters                   |

This implies three big consequences:

1. **The acceptance battery shrinks on the substrate side, grows on the
   workload side.** Fabric/FW/BMC introspection is replaced by SLA
   attestation. Pre-training and inference workloads become first-class.
2. **A "Provider SLA" artifact replaces the firmware manifest.** We will
   not have `expected_firmware.yaml` as a contractual baseline; instead
   we will have written commitments from E2E about minimum performance,
   maximum error rates, recovery times.
3. **Acceptance is per-allocation, not per-cluster.** Every time we
   provision a fresh Slinky cluster (e.g. for a new training run), we
   re-run the relevant battery to confirm *this* allocation meets spec.
   This is closer to a CI test than a one-shot vendor sign-off.

## 3. Phase-by-phase impact

### 3.1 Phase 0 (pre-commission) — mostly retired

Everything in `phase0-precommission/` assumes management-host SSH access to
every node, BMC credentials, and a flat fabric we can reach with `ibstat`,
`mlxlink`, `ibdiagnet`, `dmidecode`, `ipmitool`. None of that is available
to us.

| Old check                              | Status on E2E         | Replacement |
|----------------------------------------|------------------------|--------------|
| `firmware_baseline.sh` + `firmware_diff.py` | Gone — no node access | Provider attests to driver / CUDA / OFED / NCCL versions per allocation; we verify what's visible inside a pod |
| `bmc_sweep.sh` (IPMI SEL, sensors)    | Gone — no BMC          | Provider SLA on hardware error rate, plus E2E status page |
| `cable_telemetry.sh` (`mlxlink` per port) | Gone — no switch / port access | Provider attestation; we infer from end-to-end NCCL health |
| `expected_firmware.yaml`               | Retired                | Replace with `provider_sla.yaml` capturing what E2E commits to |
| Cohort firmware-drift detection        | Gone                   | Provider's problem; surfaced to us only via support tickets |

What replaces Phase 0 entirely is a new phase we'll call **Phase 0 —
Platform Pre-check**, covered in §4 below.

### 3.2 Phase 1 (per-node qualification) — mostly survives; rename to per-pod

The substance of Phase 1 — DCGM diag, gpu-burn, nvbandwidth, BabelStream,
local NVMe FIO, single-port IB latency, ECC counters — all run from
*inside* a pod, given GPU + RDMA passthrough. What changes:

| Old check                          | Survives on E2E?                            | Notes |
|------------------------------------|----------------------------------------------|--------|
| DCGM diag (`dcgmi diag -r 3`)     | Yes (inside pod, container must include dcgmi) | confirm pre-built training image ships dcgmi; otherwise we build a qualification image |
| `nvbandwidth`                      | Yes                                          | tests intra-pod / NVLink — survives full strength |
| `gpu-burn`                         | Yes                                          | thermal stress still works, but E2E may evict if power budget is hit |
| `BabelStream`                      | Yes                                          | HBM bandwidth, intra-GPU |
| Local NVMe FIO                     | Conditional                                  | Depends on what E2E exposes for ephemeral local storage. Investigate. |
| `ib_write_lat` to neighbor         | Conditional                                  | Needs RDMA exposed and at least one other pod scheduled on a different node |
| ECC counters baseline              | Yes (read-only) — but values may not be ours alone | GPUs may be re-allocated between tenants; baseline is per-allocation, not durable |
| Single-node NCCL `all_reduce_perf` | Yes                                          | works in a single pod with 8 GPUs |

New per-pod check we need to add: **"did we actually get what we asked
for?"** — a sanity probe that confirms the pod has 8× B200, NVLink intact
(via `nvidia-smi topo -m`), RDMA accessible, libcufile loadable, expected
driver / CUDA / NCCL versions. This is small but critical given that we
provision fresh clusters frequently.

### 3.3 Phase 2 (intra-rack) — partial; depends on topology surface

Phase 2's premise — "tests that fan out within a rack / leaf-group" —
requires knowing which nodes share a leaf. On bare metal we knew that from
the cable schedule. On E2E it depends on whether Slurm topology is
populated (Slinky can configure `topology.conf` from K8s node labels, but
only if the labels exist on the nodes).

| Old check                             | E2E equivalent | Notes |
|---------------------------------------|----------------|--------|
| 8-GPU pair-matrix NCCL                | Yes — pair-matrix at the granularity Slurm gives us | If topology labels exist, we can still do leaf-aware analysis. If not, we get an unsorted matrix and look for outliers only. |
| Intra-rack collective sweep           | Yes            | Same caveat |
| Rack-level FIO local NVMe             | Same as Phase 1 | Depends on local storage exposure |

**Action item:** before Phase 2, query Slurm for `scontrol show topology`
and `sinfo -N -o "%N %f"` (features field) to see if rack/leaf data is
exposed. If yes, port the leaf-aware code. If no, drop "intra-leaf" framing
and keep just "pair-matrix outlier detection."

### 3.4 Phase 3 (full-scale) — collectives + HPL survive; everything fabric-introspection is gone

This is the phase that loses the most depth.

| Old check                                | E2E equivalent | Notes |
|------------------------------------------|----------------|--------|
| NCCL all-5 at 1024 GPUs                 | Yes            | submit via Slinky; works the same |
| 64→1024 cliff detection                 | Yes            | scale sweep still possible |
| Variance (100 back-to-back AR)          | Yes            | works the same |
| SHARP on/off A/B                        | **No** (probably) | Provider-controlled. We can only test "whatever SHARP setting they shipped us." |
| Adaptive Routing on/off A/B             | **No** (probably) | Same as SHARP |
| ClusterKit pair-matrix                  | Yes            | container-launchable |
| IB latency sweep (intra-leaf / cross-spine) | Conditional | Needs topology surface (per §3.3) |
| FEC / pre-FEC BER (UFM REST)            | **No**          | Almost certainly not exposed. Drop. |
| Cliff-detection (port-level)            | **No**          | Same — no port access |
| HPL / HPL-MxP / HPCG                    | Yes            | NVIDIA HPC Benchmarks container is pre-pulled; run from Slurm |
| `llmb-run` for DeepSeek-V3              | Yes (Phase 5 territory) | available via Slurm submit |

What we *gain* from being on Slurm is straightforward — we don't have to
maintain `sbatch` wrappers as carefully because Slinky handles allocation.
What we *lose* is fabric introspection, which means a degraded test
becomes harder to root-cause.

**Mitigation:** ask E2E whether any UFM / DCGM exporter / SHARP-stats
endpoint can be exposed read-only to our tenant. Even a "we'll share the
weekly fabric health report" beats nothing.

### 3.5 Phase 4 (storage) — survives if we choose a PFS via the UI

The functional shape of Phase 4 transfers cleanly. What we have to verify
first:

- Which PFS types E2E exposes (Weka? Lustre? VAST? something else?).
- Whether GDS / libcufile is configured on each.
- How the PFS appears to the pod — bind-mount, CSI volume, native mount?
- Whether we can choose stripe size / mount options.

| Old check                                | Survives | Notes |
|------------------------------------------|----------|--------|
| IOR sequential (read + write GB/s)       | Yes      | unchanged |
| mdtest                                   | Yes      | unchanged |
| FIO mixed IOPS / P99 latency             | Yes      | unchanged |
| elbencho GDS line rate                   | Conditional | depends on libcufile + GDS path being available |
| MLPerf Storage                           | Yes      | unchanged |
| Checkpoint write storm                   | Yes      | unchanged |
| Noisy neighbour (mixed workload)         | Yes      | unchanged — and arguably more important on a shared-tenant platform |
| PyTorch GDS dataloader                   | Conditional | same caveat as elbencho |
| Tail audit cross-test                    | Yes      | unchanged |

### 3.6 Phase 5 (long-soak training) — main acceptance vector under E2E

Where this becomes the headline phase. The substrate is now opaque, so the
strongest acceptance signal is "can we sustain real training for N days at
expected MFU with bounded interruption?"

New questions:

- Failure recovery: when a Slinky node dies mid-training, does the
  scheduler restart it? Do we have hot spares? How fast?
- Checkpoint cadence and resume cost.
- Pre-emption: are we sharing the cluster with anyone? Can our long-soak
  job be pre-empted?
- Provider-side maintenance windows during the soak.

Tests to add:
- Multi-day DeepSeek-V3 (or NeMo / Megatron equivalent) at full scale,
  step-variance and straggler detection.
- Deliberate fault injection (kill a Slurm pod) → measure recovery time.
- Checkpoint resume from a 1-hour-old checkpoint, confirm step-time
  recovers in <2 minutes.

### 3.7 Phase 6 — inference acceptance (NEW)

This is the largest greenfield work. None of the bare-metal phases
addressed inference. With vLLM/TGI/TRT-LLM available as pre-built images,
we add a new phase focused on production-serving health.

Proposed tests:

| Test                                          | What it proves |
|-----------------------------------------------|------------------|
| Cold-start time of vLLM pod with a reference model | image pull + load latency in spec |
| Time-to-first-token (TTFT) at 1 / 8 / 64 concurrent requests | latency band |
| Inter-token latency (ITL) at the same concurrencies | tail under load |
| Throughput (tokens/sec) vs. batch size       | curve matches published vLLM numbers for the GPU class |
| Multi-pod scale-out (Triton / vLLM router)   | horizontal scaling works under E2E's networking |
| Tensor-parallel across pods (large model)    | multi-node TP feasibility — relevant for DeepSeek-V3 671B, which won't fit on 8× B200 |
| KV-cache memory accounting                   | OOM thresholds match the documented model footprint |
| Cold pod failover                            | when a pod dies, the router fails over correctly |
| Sustained inference soak (24h)               | no memory leak, no perf drift |

This phase needs its own test harness — most of the bare-metal scaffolding
(JSON-fragment-per-check, aggregator with PASS/WARN/FAIL exit codes) ports
cleanly, but the actual checks are Python load-generators against HTTP
endpoints, not `srun` invocations.

### 3.8 Phase 7 — multi-tenancy, quotas, monitoring (re-shaped)

On bare metal this was about Slurm fairshare and DCGM/Prometheus
exporters. On E2E it becomes:

- Reservation honoured? Do we get the GPUs we paid for?
- Quota enforcement (CPU, GPU, storage, bandwidth).
- Noisy-neighbour: does another tenant's job hurt our P99?
- What monitoring/observability does E2E expose to us? DCGM exporter
  endpoint? Slurm metrics scrape URL? Grafana dashboards?
- Billing reconciliation — do the consumed hours match what we paid for?

### 3.9 Phase 8 — sign-off and ongoing acceptance

Sign-off is no longer a one-shot ceremony. We propose a two-track model:

- **One-time platform acceptance:** verify the SLA terms, baseline
  numbers, monitoring access, and Terraform reproducibility once at
  contract start.
- **Per-allocation acceptance:** automated smoke + qualification +
  collective check (Phases 0–3 collapsed into a 20-minute battery) every
  time we provision a fresh Slinky cluster, before training starts.

## 4. New phase taxonomy

Proposed restructuring of the repo for the `e2e` branch:

```
cluster-health/
├── E2E_STRATEGY.md             ← this document
├── PROVIDER_QUESTIONS.md       ← formal Q&A for E2E to answer
├── README.md                   ← updated to point at the e2e flow
├── CLUSTER_HEALTH_REFERENCE.md ← updated; bare-metal sections move to legacy
├── TODO.md                     ← updated for e2e work
│
├── terraform/                  ← IaC modules to provision clusters
│   ├── slinky-cluster/         ← reproducible training cluster definition
│   ├── inference-cluster/      ← K8s deploy for vLLM/TGI/TRT-LLM
│   └── storage/                ← PFS provisioning
│
├── phase0-platform-precheck/   ← REPLACES bare-metal Phase 0
│   ├── sla_verify.py           ← cross-check provider attestations
│   ├── terraform_smoke/        ← provision + tear down + re-provision
│   ├── kubectl_probe.sh        ← what does E2E expose in our namespace?
│   └── README.md
│
├── phase1-pod-qualification/   ← REPLACES bare-metal Phase 1
│   ├── checks/                 ← DCGM diag, nvbandwidth, BabelStream, etc.
│   ├── pod_sanity.py           ← "did we get what we asked for?"
│   └── README.md
│
├── phase2-intra-allocation/    ← REPLACES bare-metal Phase 2
│   ├── checks/                 ← pair-matrix NCCL, ClusterKit
│   ├── topology_probe.sh       ← what does Slurm tell us about topology?
│   └── README.md
│
├── phase3-allocation-scale/    ← REPLACES bare-metal Phase 3 (collectives + HPL only)
│   ├── checks/                 ← NCCL all-5, scale sweep, HPL/HPL-MxP/HPCG
│   └── README.md
│
├── phase4-storage/             ← LARGELY UNCHANGED from bare metal
│   └── ...
│
├── phase5-training-soak/       ← NEW (NeMo / DeepSeek-V3 multi-day)
│   ├── recipes/                ← Slurm wrapper around llmb-run / NeMo
│   ├── faultinjection/         ← deliberate pod kills, checkpoint recovery
│   └── README.md
│
├── phase6-inference/           ← NEW
│   ├── checks/
│   │   ├── 01_coldstart.py     ← image pull + model load latency
│   │   ├── 02_ttft.py          ← TTFT sweep
│   │   ├── 03_throughput.py    ← tokens/sec vs batch
│   │   ├── 04_multipod.py      ← scale-out and TP across pods
│   │   ├── 05_kvcache.py       ← memory accounting
│   │   ├── 06_failover.py      ← pod loss and router behaviour
│   │   └── 07_soak.py          ← 24h sustained inference
│   ├── workloads/              ← prompt sets, request shapes
│   └── README.md
│
├── phase7-multitenant/         ← NEW
│   ├── quota_check.py
│   ├── noisy_neighbour.sh
│   └── monitoring_probe.sh
│
├── phase8-signoff/             ← NEW
│   ├── one_time_platform_acceptance.md
│   └── per_allocation_smoke.sh
│
├── legacy-baremetal/           ← FROZEN copies of the old phase0/1/2/3 bare-metal scripts
│   ├── phase0-precommission/
│   ├── phase1-qualification/
│   ├── phase2-intra-rack/
│   └── phase3-fullscale/
│
└── bootstrap/
    └── install.sh              ← stripped down: nothing on the substrate side, only client tooling for our laptop / runner
```

Notes on this layout:

- The bare-metal scripts get moved under `legacy-baremetal/` rather than
  deleted. If we ever do bare-metal acceptance again (or if a partner
  ships us hardware directly), the work is still there.
- `terraform/` is new and central — provisioning is now a part of the
  test surface. Every test starts from a Terraform-provisioned baseline.
- Phase 4 (storage) is the least disturbed because storage tests were
  always client-side. The only change is "operator provides PFS mount"
  becomes "Terraform provisions PFS and exports `P4_STORAGE_ROOT`."
- Phase 6 (inference) is a wholly new family. The aggregator pattern
  ports over but the checks are Python load-gen, not bash + srun.

## 5. Principles — preserved, changed, new

**Preserved.** Pass/Warn/Fail with exit codes 0/1/2. JSON-fragment-per-check
plus aggregator. Idempotent re-runs. Smoke tests in `aggregate/`.
Hierarchical gating (don't run scale tests until pod sanity passes).
Skip-cleanly when an optional dependency is missing.

**Changed.**

- *Provisioning is part of the test surface.* Bare metal assumed someone
  else did this. Under E2E, `terraform apply` is the first acceptance step,
  and its idempotence is itself a property under test.
- *Pinning shifts from firmware to container images + Terraform module
  versions.* We pin by digest, not by `dpkg -l`.
- *Acceptance is recurrent, not one-shot.* A successful run today says
  nothing about a fresh allocation tomorrow.
- *Provider attestation supplements verification.* Where we can't see,
  the SLA tells us what the provider commits to.

**New.**

- *Inference is a first-class workload.* New phase, new harness.
- *Failure recovery is testable from outside.* We deliberately kill pods
  and measure how fast Slinky recovers; bare metal had no equivalent.
- *Cost / billing reconciliation* sits alongside performance acceptance.
  If E2E charges per GPU-hour, we verify usage equals invoice.

## 6. Provider SLA — what we ask E2E to commit to

Replaces the `expected_firmware.yaml` baseline. Concrete commitments we
want in writing, in a machine-checkable form (`provider_sla.yaml` in the
repo):

- Driver / CUDA / NCCL / MOFED version floor and ceiling per image catalog.
- Maximum permissible XID error rate per GPU-day.
- Minimum guaranteed NCCL all-reduce busbw at the negotiated cluster size.
- Minimum guaranteed PFS aggregate read / write GB/s at the negotiated
  capacity.
- Maximum scheduled-maintenance window per quarter.
- Maximum unscheduled-outage budget per month.
- Time-to-replacement for a failed node within a Slinky cluster.
- Whether SHARP and Adaptive Routing are enabled by default.
- What topology information surfaces in Slurm (rack labels?).
- Whether GDS is configured on the PFS we choose.

The acceptance harness should load `provider_sla.yaml` once and verify the
measured numbers fall inside the committed bands. A measured number below
the floor is a vendor-side failure; one comfortably above the floor is
informational.

## 7. What we ask E2E for (before we start writing code)

Tracked in [`PROVIDER_QUESTIONS.md`](PROVIDER_QUESTIONS.md). High-level:

- API surface for provisioning, scale, tear-down.
- kubectl access into our namespace.
- Topology labels on K8s nodes (and Slinky-populated Slurm topology.conf).
- Read-only monitoring: DCGM exporter, Slurm metrics, Grafana, UFM
  read-only.
- Pre-built image manifest and digest list (with NCCL / CUDA / driver /
  OFED versions baked in).
- Bring-your-own-image policy.
- PFS catalog: which types, which performance bands, GDS support.
- Reservation / capacity terms.
- Reservation guarantees vs. spot / shared.
- Maintenance window policy.
- Pod / node failure recovery semantics.
- Cost model and metering granularity.

## 8. Phasing of the work

Order in which we propose to build out the `e2e` branch:

1. **Strategy + provider Q&A (this document and `PROVIDER_QUESTIONS.md`).**
   Get E2E to sign off on what's possible before we invest engineering
   time on assumptions that may not hold.
2. **Terraform skeleton.** One module that provisions the smallest viable
   Slinky cluster + one PFS + one inference pod. Once this is repeatable,
   every other phase can be built on top.
3. **Phase 0 platform pre-check.** SLA verifier + kubectl probe +
   `terraform apply` / `terraform destroy` idempotence test.
4. **Phase 1 pod qualification.** Translate the existing per-node checks
   (DCGM, nvbandwidth, BabelStream, gpu-burn, single-node NCCL) to run as
   a Slurm job from inside a pre-built image.
5. **Phase 3 allocation-scale collective sweep.** NCCL at full
   negotiated size + HPL via the NVIDIA HPC Benchmarks container. Skip
   the fabric-introspection checks.
6. **Phase 4 storage.** Port from bare metal. Confirm GDS path is open
   on the PFS option we chose.
7. **Phase 6 inference.** New phase. Start with TTFT + throughput
   against a single vLLM pod, then scale-out.
8. **Phase 5 training soak.** Multi-day NeMo / DeepSeek-V3 run with
   fault injection.
9. **Phase 7 multi-tenancy / monitoring.** Last because it requires
   long-lived clusters to be useful.
10. **Phase 8 sign-off doc.** Compile a per-allocation smoke runbook (the
    20-minute battery a future operator runs before kicking off a real
    training job).

## 9. Open questions (for us, not E2E)

- **Do we keep one cluster-health repo, or fork into `cluster-health-baremetal`
  and `cluster-health-e2e`?** Probably keep one repo with `legacy-baremetal/`
  as a frozen subdirectory, so future hardware acceptance work has a
  starting point.
- **What does the new bootstrap look like?** Bare-metal `bootstrap/install.sh`
  installed binaries on every node. The new "bootstrap" is more like:
  install Terraform, configure E2E API credentials, pull container images
  to a registry mirror. Mostly a developer-laptop / CI concern.
- **Container strategy: bring-your-own image, or use E2E's pre-builts?**
  Pre-builts are faster to start with; BYO is more reproducible. Probably:
  start with E2E's pre-builts for inference acceptance, build a custom
  qualification image for Phase 1 (so we control dcgmi / nccl-tests
  versions).
- **How do we handle GPU counter resets between allocations?** ECC counter
  accumulation only makes sense within a single allocation's lifetime.
  Phase 7 soak duration becomes the meaningful window.
- **Do we want chaos-testing (kill a random pod every 6 hours) as part of
  acceptance, or as a separate exercise?** Recommend folding into Phase 5
  soak — that's where it has signal.

## 10. Recommended next step

Hand `PROVIDER_QUESTIONS.md` to E2E and get answers before we cut code.
The answers determine which checks survive verbatim, which need
re-shaping, and which we drop. Once the answers are back, I'll do a
follow-up pass on this document and stub out the directory tree under §4.
