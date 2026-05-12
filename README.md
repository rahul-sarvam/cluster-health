# cluster-health

Acceptance, validation, and continuous health-monitoring for large GPU
clusters at Sarvam. Written initially for our 1024× B200 acceptance
(128 nodes × 8 GPUs), but the structure carries over to any future
cluster with minor parameter changes.

> **Where to start reading:** if you're new to the team, read
> [`CLUSTER_HEALTH_REFERENCE.md`](CLUSTER_HEALTH_REFERENCE.md)
> end-to-end. It's the design doc. This README is the runbook on top
> of it.

## What this repo contains

Eight phases, executed roughly in order, each one a folder. Each phase
gates the next: we don't run intra-rack scale tests until per-node
qualification passes, we don't run full-cluster scale until intra-rack
is clean, and so on. Conventions are uniform across phases:

- Numbered check scripts in `checks/` (Bash or Python).
- A shared `env.sh` (per phase) that holds paths, scales, thresholds,
  and the JSON-emit helper.
- A Slurm wrapper in `slurm/<phase>.sbatch` that grabs a single
  allocation and runs the checks sequentially.
- Each check writes a structured JSON fragment to `${P*_RESULTS}/`.
- An aggregator in `aggregate/report.py` that rolls the fragments into
  a Markdown report and exits `0` (PASS), `1` (WARN), or `2` (FAIL).

## Phase index

| Phase | Folder                                                    | Status                | Sub-folder README                                                   |
| ----- | --------------------------------------------------------- | --------------------- | ------------------------------------------------------------------- |
| 0     | [`phase0-precommission/`](phase0-precommission/)          | IMPLEMENTED (3 of 5)  | [phase0-precommission/README.md](phase0-precommission/README.md)    |
| 1     | [`phase1-qualification/`](phase1-qualification/)          | IMPLEMENTED           | [phase1-qualification/README.md](phase1-qualification/README.md)    |
| 2     | [`phase2-intra-rack/`](phase2-intra-rack/)                | IMPLEMENTED           | [phase2-intra-rack/README.md](phase2-intra-rack/README.md)          |
| 3     | [`phase3-fullscale/`](phase3-fullscale/)                  | IMPLEMENTED           | [phase3-fullscale/README.md](phase3-fullscale/README.md)            |
| 4     | [`phase4-storage/`](phase4-storage/)                      | IMPLEMENTED           | [phase4-storage/README.md](phase4-storage/README.md)                |
| 5     | `phase5-soak/`                                            | NOT-YET-IMPLEMENTED   | —                                                                   |
| 6     | `phase6-multijob/`                                        | NOT-YET-IMPLEMENTED   | —                                                                   |
| 7     | `phase7-aging/`                                           | NOT-YET-IMPLEMENTED   | —                                                                   |
| 8     | `sign-off/`                                               | NOT-YET-IMPLEMENTED   | —                                                                   |

Open work is tracked in [`TODO.md`](TODO.md), grouped by phase and
priority. The design and pass criteria for every check (including the
not-yet-implemented ones) live in
[`CLUSTER_HEALTH_REFERENCE.md`](CLUSTER_HEALTH_REFERENCE.md).

## Bootstrap

One script lays down every dependency for every implemented phase:

```bash
# Install everything for every phase (idempotent):
sudo ./bootstrap/install.sh

# Just one phase:
sudo ./bootstrap/install.sh phase4

# Verify what's missing without installing:
./bootstrap/install.sh verify

# Preview without touching the system:
DRY_RUN=1 ./bootstrap/install.sh
```

See [`bootstrap/README.md`](bootstrap/README.md) for what gets
installed per phase, where binaries land (`INSTALL_PREFIX`, default
`/opt/qualification`), and how to add new phases. Vendor-supplied
components (NVIDIA driver, CUDA, MLNX_OFED, fabric manager, DCGM,
cuFile / GDS) are verified but never auto-installed.

## End-to-end flow

A typical acceptance week looks like:

```bash
# Day 0 — pre-commission (management host + every node)
sudo ./bootstrap/install.sh phase0
phase0-precommission/run_all.sh

# Day 1–3 — per-node qualification gate
sudo ./bootstrap/install.sh phase1
sbatch phase1-qualification/slurm/qualify_all_nodes.sbatch

# Day 3–5 — intra-rack scale, one Slurm job per rack
sudo ./bootstrap/install.sh phase2
sbatch phase2-intra-rack/slurm/phase2.sbatch

# Day 5–7 — cross-spine scale (full 128-node allocation)
sudo ./bootstrap/install.sh phase3
sbatch phase3-fullscale/slurm/phase3.sbatch

# Day 7–9 — storage scale (same 128-node allocation, on the PFS)
sudo ./bootstrap/install.sh phase4
export P4_STORAGE_ROOT=/mnt/scratch
sbatch phase4-storage/slurm/phase4.sbatch
```

Each phase produces a Markdown report under that phase's `results/`
directory. Phases 5–8 will follow the same pattern once they land.

## How to fill `env.sh` (operator guide)

Every phase has its own `env.sh` and the operator must fill in a
handful of cluster-specific values before the first run. The same
patterns repeat across phases. This section tells you where to find
each kind of value.

### Hostnames and node lists

Phase 0 needs three plain-text inventory files; the other phases read
node lists from Slurm directly.

| File                          | One per line                              | Where to get it |
| ----------------------------- | ----------------------------------------- | --------------- |
| `${P0_ROOT}/nodes.txt`        | Compute node hostnames (128 entries)      | `sinfo -N -h -o '%N' \| sort -u` on the head node, or the vendor's delivery sheet. |
| `${P0_ROOT}/bmc_hosts.txt`    | BMC hostnames / IPs (128 entries, same order as `nodes.txt`) | Vendor's BMC handover sheet. Often `<host>-bmc` or `<host>-ipmi` on the management VLAN; verify with `ping`. |
| `${P0_ROOT}/ib_switches.txt`  | IB leaf + spine switch IPs (optional)     | `ibnetdiscover -p` on any host, or UFM's switch list. Lines starting with `SW` give you the switch GUIDs; `ibhosts` and the management VLAN ARP table resolve them to IPs. |

If you don't have `bmc_hosts.txt` yet, the vendor delivery should have
sent a CSV — convert it with `awk -F, '{print $2}' delivery.csv >
bmc_hosts.txt` after eyeballing column order.

### BMC / IPMI credentials

`P0_IPMI_USER` and `P0_IPMI_PASS` come from the vendor's BMC handover
sheet (often labelled "out-of-band admin"). For day-1 you can keep
them as env exports, but for production they should resolve from a
secrets manager (Vault, `pass`, AWS Secrets Manager, etc.). The repo
deliberately refuses to run if these are still `TODO_FILL`.

```bash
# One-shot during day-1:
export P0_IPMI_USER=admin
export P0_IPMI_PASS=$(cat ~/.bmc_pass)

# Better, once a secrets store is in place:
export P0_IPMI_PASS=$(vault kv get -field=password secret/cluster/bmc)
```

`P0_BMC_PROTOCOL` is `ipmitool` (default) or `redfish`. Use Redfish if
the BMCs support it — it's faster and the JSON returns are easier to
parse.

### SSH user and keys (Phase 0)

`P0_SSH_USER` defaults to `root`. Most vendor handovers ship with an
`admin` or `ubuntu` user that can sudo; set `P0_SSH_USER` accordingly.
The SSH options string assumes key-based, non-interactive auth — make
sure your SSH agent has the right key loaded before running:

```bash
ssh-add ~/.ssh/cluster_admin
ssh ${P0_SSH_USER}@<one-node> 'echo ok'   # smoke test
```

### Firmware and software version pins

`EXPECTED_DRIVER_VERSION`, `EXPECTED_FM_VERSION`, `EXPECTED_OFED_VERSION`,
`EXPECTED_NCCL_VERSION`, `EXPECTED_CUDA_VERSION` live in
[`phase1-qualification/slurm/env.sh`](phase1-qualification/slurm/env.sh).
The vendor's burn-in report has all of these; if you don't have it
yet, run Phase 0 first — the cohort-majority fallback in
`firmware_diff.py` reports the most common value across the cluster,
which you then promote into the env pins.

```bash
# On any node:
nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits | head -1   # → EXPECTED_DRIVER_VERSION
nv-fabricmanager --version 2>&1 | awk '{print $NF}'                              # → EXPECTED_FM_VERSION
ofed_info -s                                                                     # → EXPECTED_OFED_VERSION (strip trailing colon)
nvcc --version | awk '/release/{print $6}' | tr -d ,V                            # → EXPECTED_CUDA_VERSION
strings $(ldconfig -p | awk '/libnccl.so / {print $NF; exit}') | grep -oP 'NCCL \K[0-9.]+' | head -1   # → EXPECTED_NCCL_VERSION
```

### Topology and hardware counts

`EXPECTED_NODE_COUNT`, `EXPECTED_GPUS_PER_NODE`, `EXPECTED_NICS_PER_NODE`,
`EXPECTED_LEAF_COUNT`, `EXPECTED_SPINE_COUNT`, `EXPECTED_IB_LINK_SPEED`,
`EXPECTED_IB_LINK_WIDTH` come from the procurement spec. For the
1024× B200 cluster:

| Var                          | Value     | How to verify on the cluster                                                  |
| ---------------------------- | --------- | ----------------------------------------------------------------------------- |
| `EXPECTED_NODE_COUNT`        | 128       | `sinfo -N -h -o '%N' \| sort -u \| wc -l`                                     |
| `EXPECTED_GPUS_PER_NODE`     | 8         | `nvidia-smi -L \| wc -l` on any node                                          |
| `EXPECTED_NICS_PER_NODE`     | 8         | `ibstat -p \| wc -l` on any node                                              |
| `EXPECTED_LEAF_COUNT`        | 16        | `ibnetdiscover \| awk '$1=="Switch"' \| wc -l` minus the spines               |
| `EXPECTED_SPINE_COUNT`       | 8         | Vendor spec; cross-check with `ibnetdiscover` (spines have the most ports up) |
| `EXPECTED_IB_LINK_SPEED`     | `NDR`     | `ibstat \| awk '/Rate:/{print $2; exit}'` (`400` Gb/s == NDR)                 |
| `EXPECTED_IB_LINK_WIDTH`     | `4x`      | `ibstat \| awk '/Width:/{print $2; exit}'`                                    |

### UFM REST endpoint (Phase 3)

Check 3.11 (UFM snapshot) needs three things:

```bash
export UFM_HOST=ufm.cluster.internal           # UFM appliance hostname
export UFM_USER=admin                          # UFM REST user
export UFM_PASS_FILE=/etc/ufm.pass             # file containing the password, mode 0600
```

If `UFM_HOST` is empty, check 3.11 skips cleanly and the rest of Phase
3 carries on. The fabric team usually owns the UFM credentials —
coordinate with them and store the password file with `chmod 600`.

### Parallel filesystem mount (Phase 4)

`P4_STORAGE_ROOT` is the single most important env var in Phase 4 and
has **no safe default**. Set it to whatever path the parallel
filesystem is mounted at on every compute node:

```bash
export P4_STORAGE_ROOT=/mnt/scratch       # or /mnt/lustre, /mnt/weka, /mnt/vast, /mnt/gpfs, ...
```

Confirm the path is mounted on every node before launching:

```bash
srun --nodes=128 --ntasks-per-node=1 bash -c '[[ -d ${P4_STORAGE_ROOT} ]] && echo "$(hostname): ok"' \
  | awk '!/ok/{print "MISSING on " $1; exit 1}'
```

The sbatch wrapper does its own pre-flight (probe write + readback)
but a fan-out smoke is cheap and saves you an allocation.

### Vendor reference numbers

A few thresholds default to `TODO_FILL` because they depend on the
vendor's published reference for the exact hardware revision and
software stack you're running:

| Var                                | Phase | Where to find the value                                                                                  |
| ---------------------------------- | ----- | -------------------------------------------------------------------------------------------------------- |
| `P3_HPL_MXP_REF_TFLOPS`            | 3.9   | NVIDIA HPC Benchmarks release notes (matching the DGX OS / container you're targeting). Until filled, check 3.9 emits `warn`. |
| `P4_MLPERF_REF_SAMPLES_PER_SEC`    | 4.5   | MLCommons published number for the workload (`P4_MLPERF_MODEL`) and accelerator profile. Until filled, check 4.5 emits `warn`. |

Both checks are designed to *capture* the measured number on first
run, so you can promote your own measurement into the env var if the
vendor reference is unavailable. Just record where the number came
from in your run notes.

### Per-cluster performance tuning

The throughput / latency thresholds in each `env.sh` (NCCL busbw
floors, IB latency ceilings, IOR GB/s minimums, etc.) are conservative
defaults that any healthy B200 + NDR + good PFS configuration should
clear. After the first real-hardware run, you should:

1. Read the captured numbers out of `${P*_RESULTS}/report.md`.
2. Compare to the vendor's spec sheet and the contractual threshold
   table (`CLUSTER_HEALTH_REFERENCE.md` §13).
3. Edit the corresponding env vars in `slurm/env.sh` to tighten them
   toward the contractual targets — but never above the measured
   number, or you'll fail every subsequent run.

The TODO doc has a "Cross-cutting follow-ups" section per phase that
spells out exactly which knobs need attention after the first run.

### Where exports live

For ad-hoc work, plain `export` lines in your shell are fine:

```bash
export P4_STORAGE_ROOT=/mnt/scratch
export UFM_HOST=ufm.cluster.internal
sbatch phase4-storage/slurm/phase4.sbatch
```

For production, put a `cluster-health.env` file next to the cluster's
Slurm config and source it from your sbatch wrappers. Don't commit
secrets (`P0_IPMI_PASS`, UFM password files); use `pass` / Vault /
your team's existing secrets flow.

## Conventions used across phases

- **Exit codes.** `0` = PASS (everything passed or cleanly skipped), `1`
  = WARN (at least one warn / cross-cutting audit warned), `2` = FAIL.
  Every aggregator follows this mapping. Wrapper scripts and CI should
  treat `0` and `1` differently — a WARN is not a failure but a thing
  to look at.
- **`skip` status.** A check that can't run because of a missing
  dependency (e.g. `libcufile` not present, UFM_HOST unset, ior binary
  missing) emits `skip` and a `reason` field. Skips do not fail the
  phase; the operator sees them in the report and decides whether to
  install the missing piece.
- **JSON fragment per check.** Every check writes a single JSON file
  `${P*_RESULTS}/<check>_<jobid>.json` with `check`, `status`, `ts`,
  and any check-specific key=value pairs. The aggregator never parses
  log files — only JSON.
- **Bookended snapshots.** Phase 3 captures a baseline and a final
  snapshot for fabric counters (FEC + UFM) so the aggregator can diff
  for mid-phase degradation. Phase 5 will do the same for XID / ECC /
  power. Avoid one-shot counter reads where a delta is what you want.
- **Cross-cutting audits.** The aggregator can run analyses that span
  multiple check fragments (Phase 3 has cliff/FEC/UFM audits; Phase 4
  has `tail_audit`). These let us catch end-to-end pathologies that
  individual checks can't see.
- **Smoke tests.** Each aggregator has a `smoke_test.py` next to it
  that fabricates synthetic JSON fragments for both a happy path and
  a deliberate-failure path, runs the aggregator, and asserts the
  expected verdict + exit code. Run them before pushing aggregator
  changes.

## Glossary

The reference doc has the canonical glossary — see
[`CLUSTER_HEALTH_REFERENCE.md` §18](CLUSTER_HEALTH_REFERENCE.md#18-glossary).
If you hit an acronym (NCCL, SHARP, MFU, FEC, XID, GDS, UFM, AR,
busbw, …) and don't know what it means, that's where to look first.
