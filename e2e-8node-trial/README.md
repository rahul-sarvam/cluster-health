# e2e-8node-trial

Login-node driver for an 8-node acceptance trial on the E2E Networks
Slinky-on-K8s platform. Re-uses every Phase 1 / 2 / 3 check we already
have on `main`, narrowed to 8-node scale and redirected so every output
lands under a single run directory that can be tarballed at the end.

## What it does

1. **Pre-flight** — confirm Slurm is reachable, auto-detect the partition,
   verify the shared filesystem is visible on every compute node, probe
   one node for GPU + IB + driver basics.
2. **Bootstrap** — run [`bootstrap/install.sh`](../bootstrap/install.sh)
   once per node via `srun`. Idempotent: skips anything already there.
3. **Inventory** — per-node hardware + software fingerprint
   (`nvidia-smi`, `ofed_info`, `dpkg -l libnccl2`, `dmidecode`, etc.)
   into one JSON per host.
4. **Phase 0 cohort drift** — compare the 8 inventories field by
   field. Flags anything where one node disagrees with the cohort
   majority (different driver, different VBIOS, etc.).
5. **Phase 1** — per-node qualification. Slurm array job, one task per
   node, running the existing `phase1-qualification/run_node.sh` (DCGM
   diag, nvbandwidth, BabelStream, gpu-burn, single-node NCCL,
   ib_write_bw loopback, host_health).
6. **Phase 2** — intra-cluster collectives. NCCL sweep, small-message,
   rail-isolated, ClusterKit pair-matrix, OSU intra, topology check.
7. **Phase 3 at 8-node scale** — NCCL all-5 sweep across 1/2/4/8
   nodes, variance run, ClusterKit fullscale, IB latency, HPL /
   HPL-MxP / HPCG. **Provider-side checks skipped**: SHARP A/B, AR A/B,
   FEC sweep, UFM snapshot (these need switch / UFM access we don't
   have as a tenant).
8. **Executive aggregator** — rolls every JSON fragment into one
   `report/REPORT.md` plus a `report/summary.json`. Exit code mirrors
   the worst phase verdict.
9. **Tarball** — single `.tar.gz` at `$HOME/cluster-health-runs/run-<ts>.tar.gz`
   for fetching back to your laptop.

## How to run it on the login node

```bash
# From the login node, after scp'ing the cluster-health repo over:
cd ~/cluster-health
nohup ./e2e-8node-trial/run_all.sh > ~/cluster-health/nohup.out 2>&1 &
disown

# Tail progress at any time:
tail -f ~/cluster-health-runs/run-*/orchestrator.log
```

Total runtime budget: ~6 hours under default settings.

## Configuration knobs

All overridable via env before launch:

| Variable | Default | What it does |
|----------|---------|---------------|
| `E2E_PARTITION` | auto-detected from `sinfo` | Slurm partition for all sbatch / srun calls |
| `E2E_NODE_COUNT` | 8 | nodes used in every phase |
| `E2E_GPUS_PER_NODE` | 8 | GPU count we ask Slurm for |
| `E2E_RUN_DIR` | `$HOME/cluster-health-runs/run-<ts>` | root of every output path |
| `E2E_PHASE1_TIME` | `01:30:00` | Slurm `--time` for the Phase 1 array |
| `E2E_PHASE2_TIME` | `02:00:00` | Slurm `--time` for Phase 2 |
| `E2E_PHASE3_TIME` | `02:30:00` | Slurm `--time` for Phase 3 |
| `E2E_SKIP` | empty | CSV of phases to skip (`preflight,bootstrap,inventory,phase1,phase2,phase3`) |
| `GPU_BURN_SECONDS` | `300` | gpu-burn duration per node (Phase 1) |

## Where every log lands

```
$HOME/cluster-health-runs/run-<ts>/                ← E2E_RUN_DIR
├── orchestrator.log                               ← top-level driver tee
├── preflight/
│   ├── preflight.log                              ← every command + output
│   ├── preflight.json                             ← structured summary
│   ├── nodelist.txt                               ← canonical node order
│   ├── discovered.env                             ← partition + nodelist (sourceable)
│   ├── shared_fs_probe.<host>.out
│   └── compute_probe.out
├── inventory/
│   ├── <host>.json                                ← per-node fingerprint
│   └── <host>.raw                                 ← raw command output
├── phase0/
│   ├── cohort_drift.json                          ← structured drift report
│   └── cohort_drift.md                            ← human-readable
├── phase1/
│   ├── results/<host>_<check>.json                ← per-check JSON fragments
│   ├── results/<host>.json                        ← per-host rollup
│   ├── results/phase1_cohort_report.md            ← cross-host outlier report
│   └── logs/<host>.log
├── phase2/
│   ├── results/<check>_<jobid>.json
│   ├── results/phase2_report_<jobid>.md
│   └── logs/
├── phase3/
│   ├── results/<check>_<jobid>.json
│   ├── results/phase3_report_<jobid>.md
│   └── logs/
├── slurm-logs/
│   ├── bootstrap-<host>.out
│   ├── inventory-<host>.out
│   ├── phase1-<jobid>_<arrayid>.out
│   ├── phase2-<jobid>.out
│   └── phase3-<jobid>.out
└── report/
    ├── REPORT.md                                  ← executive summary
    └── summary.json                               ← machine-readable rollup
```

And one tarball one level up:

```
$HOME/cluster-health-runs/run-<ts>.tar.gz
```

## What to fetch back to the laptop

Just the tarball — it contains everything above:

```bash
scp -i ~/.ssh/rahul-mac.pem root@151.185.46.51:cluster-health-runs/run-*.tar.gz \
    ~/code/cluster-health/runs/
```

## What it does NOT test (and why)

| Skipped check | Reason |
|---------------|--------|
| Phase 0 BMC / IPMI sweep | no tenant access to BMC on a managed platform |
| Phase 0 mlxlink port telemetry | switch ports not visible to tenant |
| Phase 3 §3.3 SHARP A/B | SHARP enable/disable is provider-side |
| Phase 3 §3.5 AR-on/off A/B | adaptive routing toggle is provider-side |
| Phase 3 §3.7 FEC sweep | needs switch-port access |
| Phase 3 §3.11 UFM snapshot | needs UFM REST credentials |
| Phase 4 storage | not selected for this trial; PFS mount may not exist |
| Phase 5 / 6 / 7 | not selected for this trial |

Each skipped Phase 3 sub-check still emits a `skip` JSON fragment with
`reason: not_testable_from_tenant_on_managed_platform`, so the
aggregator records the gap explicitly.

## Resuming after a failure

The script writes everything under `E2E_RUN_DIR`. To resume after a
mid-run crash:

```bash
# point at the existing run dir and skip what already completed:
E2E_RUN_DIR=~/cluster-health-runs/run-20260524-093015 \
E2E_SKIP=preflight,bootstrap,inventory,phase1 \
    ./e2e-8node-trial/run_all.sh
```

## What success looks like

Executive `REPORT.md` should show:

- **Verdict: PASS** at the top
- Preflight: PASS
- Cohort drift: PASS (no outliers)
- Phase 1: every host PASS, no outliers in the cohort report
- Phase 2: every check PASS or SKIP-by-design
- Phase 3: every tenant-runnable check PASS, provider-side checks SKIP

If any check is WARN, that's a "scale-with-caution" signal — not a
blocker for the 128-node ramp but something to investigate. Any FAIL
is a blocker.
