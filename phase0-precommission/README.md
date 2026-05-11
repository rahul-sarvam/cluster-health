# Phase 0 — Pre-Commission Sweeps

Three read-only sweeps that run **before** any benchmark on a freshly-racked
cluster. The goal: catch vendor-side setup mistakes (mismatched firmware,
miswired cables, unreachable BMCs) before anyone spends a day on
benchmarking.

## Files

| File | Purpose |
| --- | --- |
| `env.sh` | Shared paths, credentials, thresholds, helpers |
| `firmware_baseline.sh` | Fan-out: collect BIOS / driver / VBIOS / FM / OFED / NCCL / kernel versions from every node |
| `cable_inventory.sh` | Local `ibnetdiscover` + per-host `ibstat`/`mlxlink` fan-out for IB link state, width, speed, pre-FEC BER |
| `bmc_sweep.sh` | Per-BMC dump of MC info, power, sensors, SEL, FRU (ipmitool or Redfish) |
| `run_all.sh` | Top-level runner: `firmware`, `cables`, `bmc`, or `all` |
| `helpers/ssh_fanout.sh` | Bounded-parallelism SSH driver (no pdsh / parallel-ssh dependency) |
| `aggregate/firmware_diff.py` | Compares per-host firmware payloads vs manifest **and** vs cohort majority |
| `aggregate/cable_validate.py` | Parses cable text dumps; validates speed/width/state/BER |
| `aggregate/bmc_summary.py` | Distills BMC dumps into pass/warn/fail per BMC |
| `aggregate/report.py` | Renders `PHASE0_REPORT.md` with overall sign-off verdict |
| `reference/expected_firmware.yaml` | Vendor manifest — fill in at burn-in |
| `reference/expected_topology.yaml` | Expected IB topology — fill in from vendor cable map |

## Before first run

1. Edit `env.sh`:
   - `P0_IPMI_USER` / `P0_IPMI_PASS` (or export these from your secrets manager)
   - `P0_BMC_PROTOCOL` — `ipmitool` (default) or `redfish`
   - SSH key / user is set via `P0_SSH_USER` and `P0_SSH_OPTS`

2. Populate the three inventory files (paths in `env.sh`):
   - `${P0_ROOT}/nodes.txt`        — one compute hostname per line
   - `${P0_ROOT}/bmc_hosts.txt`    — one BMC hostname/IP per line
   - `${P0_ROOT}/ib_switches.txt`  — optional, one IB switch IP per line

3. Fill in vendor data (or leave for the first sweep to learn it):
   - `reference/expected_firmware.yaml` — replace `TODO_FILL_AT_BURNIN`
   - `reference/expected_topology.yaml` — replace empty `hosts: []` lists

## Running

```bash
# Everything in sequence (firmware → cables → BMC → report)
./run_all.sh

# Just one sweep
./run_all.sh firmware
./run_all.sh cables
./run_all.sh bmc

# Re-render report from existing JSONs (no sweeps re-run)
./run_all.sh report
```

The final markdown report lands at `${P0_RESULTS}/PHASE0_REPORT.md`.

## Exit-code semantics (for CI / Slurm wrappers)

| Code | Meaning |
| --- | --- |
| 0 | All sweeps succeeded, no inspection failures |
| 1 | At least one sweep had transport-level failure (couldn't reach a node) |
| 2 | At least one inspection rule failed (firmware drift / bad link / bad BMC) |
| 3 | Both transport and inspection failures |

## Idempotency

Every sweep writes into a timestamped subdirectory under `${P0_RESULTS}`.
A `.firmware_latest` / `.cables_latest` / `.bmc_latest` pointer file is
updated atomically so the aggregators always look at the most recent run.
You can re-run any sweep as many times as needed — nothing is mutated on
the targets.

## First-run mode (no manifest yet)

If `reference/expected_firmware.yaml` still contains `TODO_FILL_AT_BURNIN`,
`firmware_diff.py` falls back to **cohort majority** — every host is
compared against the most common value across the cluster. Use the first
sweep to learn what the vendor delivered, then promote those values into
the manifest so subsequent sweeps catch true drift.
