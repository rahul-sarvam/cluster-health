# Day-1 Per-Node Qualification Gate

A runnable scaffold for qualifying every node of a 1024× B200 cluster (128 nodes ×
8 GPUs) **before** any cross-node scale tests are run. The goal of this gate is
narrow but critical: every node must prove it is within ~1% of the cohort mean
on a fixed set of single-node tests. Failing nodes are quarantined and reported
to the vendor for replacement before the cluster as a whole touches the fabric.

## What this gate catches

- Dead / partly-dead GPUs (HBM stack failures, GEMM throughput outliers, P2P route failures inside the NVSwitch).
- Thermal/power problems (early throttling, fan failures, bad PSU phase balance).
- Bad NICs and bad short-haul cables (link speed renegotiated, pre-FEC BER above threshold, no GPUDirect path).
- Driver / firmware / BIOS / OFED / FM version skew across nodes.
- BMC, PTP, NUMA, hugepage, and persistent-mode misconfiguration.

It does **not** test the fabric end-to-end. That is the next phase
(`02_intra_rack`, `03_full_scale`) and lives outside this directory.

## Layout

```
phase1-qualification/
├── README.md
├── slurm/
│   ├── qualify_all_nodes.sbatch    # Slurm array job, one task per node
│   └── env.sh                       # paths, version pins, thresholds
├── checks/
│   ├── 01_node_sanity.sh            # nvidia-smi, dmesg, persistence-mode, MIG off
│   ├── 02_firmware_inventory.sh     # driver, CUDA, NCCL, FM, BMC, BIOS, NIC FW
│   ├── 03_dcgm_diag.sh              # dcgmi diag -r 4 (+ EUD)
│   ├── 04_nvbandwidth.sh            # P2P / H2D / D2H matrix on the node
│   ├── 05_hbm_bandwidth.sh          # BabelStream per GPU
│   ├── 06_gpu_burn.sh               # 30 min thermal stress
│   ├── 07_intra_node_nccl.sh        # 8-GPU all_reduce / alltoall sanity
│   ├── 08_ib_health.sh              # ibstat + mlxlink pre/post-FEC BER per port
│   ├── 09_ib_loopback_bw.sh         # ib_write_bw + ib_write_lat (--use_cuda)
│   └── 10_host_health.sh            # NUMA, STREAM, NVMe smartctl, PTP offset
├── run_node.sh                      # orchestrator: runs all checks, emits JSON
├── aggregate/
│   ├── parse_results.py             # gather per-node JSON into one DataFrame
│   ├── cohort_analysis.py           # flag nodes >1% from cohort mean (per metric)
│   └── report.py                    # emit pass/fail CSV + Markdown summary
└── results/                         # per-node JSON outputs land here
    └── <hostname>.json
```

## How to run

1. Edit `slurm/env.sh` to pin paths, expected versions, and pass/fail thresholds.
2. From the head node:

```bash
sbatch slurm/qualify_all_nodes.sbatch
```

This dispatches a Slurm array job, one task per node, each pinned to its
target host. Each task runs `run_node.sh` which executes all ten check
scripts and writes a single `results/<hostname>.json`.

3. After all tasks complete:

```bash
python3 aggregate/parse_results.py results/ > results/cohort.parquet
python3 aggregate/cohort_analysis.py results/cohort.parquet
python3 aggregate/report.py results/cohort.parquet > results/qualification_report.md
```

You get a single Markdown report listing PASS / FAIL / OUTLIER per node, plus
a CSV of every outlier metric. Hand this report to the vendor.

## Pass criteria (the contract)

| Check | Pass criterion |
|---|---|
| nvidia-smi | All 8 GPUs visible, model = `NVIDIA B200`, mem = 192 GB, persistence-mode ON, MIG off, ECC enabled, no XID since boot |
| Firmware | Versions match `env.sh` pins exactly across all nodes (no per-node drift) |
| `dcgmi diag -r 4` | All plugins PASS, including EUD |
| nvbandwidth | P2P bidir ≥ 0.98 × cohort median per pair, H2D/D2H ≥ 0.98 × cohort median |
| HBM bandwidth | Per-GPU triad ≥ 0.98 × cohort median (~ 7.0–7.5 TB/s on B200) |
| gpu-burn | 30 min completes with 0 errors, no thermal violation, no power violation, no SBE > 0 |
| Intra-node NCCL | 8-GPU all_reduce busbw at 8 GB ≥ 0.98 × cohort median |
| IB health | Every port: link width = 4x, link speed = NDR, pre-FEC BER ≤ 1e-7, 0 symbol errors |
| IB loopback BW | `ib_write_bw --use_cuda` ≥ 380 Gb/s, GPU-mem within 3% of host-mem |
| Host health | NUMA correct, STREAM triad ≥ 0.95 × cohort median, NVMe SMART healthy, PTP offset < 100 µs |

A node fails the gate if **any** check fails outright OR if **two or more** metrics
are flagged as cohort outliers (defined as > 1% below cohort median, or > 3σ).

## Estimated wall time per node

- Sequential: ~45 minutes (dominated by `dcgmi diag -r 4` and `gpu-burn`).
- Run in parallel across all 128 nodes, so the gate clears in ~50 minutes total.

## What this scaffold is, and what it isn't

It's a starting point you can hand to your infra team and have them flesh out
in 1–2 days. The check scripts call real tools (`dcgmi`, `nvbandwidth`,
`gpu-burn`, `mlxlink`, `ib_write_bw`, NCCL tests) and emit structured output.
The aggregator does real outlier detection. It is **not** a polished product
— version pins, NIC layout, NVMe slots, and Slurm partition names need to be
filled in for your environment. Search for `TODO:` in the scripts.
