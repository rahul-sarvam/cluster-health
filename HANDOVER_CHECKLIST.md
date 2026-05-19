# Cluster Handover Checklist

What the cluster provider must **install** on the cluster before handing it
over to Sarvam, and what **information** they must give us so we can run our
acceptance tests without back-and-forth.

Hardware, fabric topology, firmware versions, power/cooling, etc. are
already locked in by the PO and are out of scope here. This document is
strictly the software stack and the operational data we need on Day 0.

Two sections:

- [§1 — Packages to install](#1-packages-to-install)
- [§2 — Information to deliver](#2-information-to-deliver)

---

## 1. Packages to install

Our own bootstrap script ([`bootstrap/install.sh`](bootstrap/install.sh))
installs most user-space tooling we need (IOR, mdtest, elbencho, nccl-tests,
nvbandwidth, gpu-burn, jq, fio, perftest, MLPerf Storage, NumPy, pandas,
etc.). What we **cannot** install ourselves — and what the provider must
have in place before handover — is the kernel-mode stack, the cluster-wide
services, the storage client, and the container runtime.

### 1.1 NVIDIA stack — every compute node

| # | Item | What we check it with | Status |
|---|------|------------------------|--------|
| 1.1.1 | NVIDIA driver, vendor-blessed version, **identical** on all 128 nodes | `nvidia-smi` | ☐ |
| 1.1.2 | CUDA toolkit installed, `nvcc` on `$PATH` | `nvcc --version` | ☐ |
| 1.1.3 | NVIDIA Fabric Manager service `active` | `systemctl is-active nvidia-fabricmanager` | ☐ |
| 1.1.4 | DCGM installed and host-engine running | `dcgmi discovery -l` | ☐ |
| 1.1.5 | `nvidia-peermem` kernel module loaded | `lsmod \| grep nvidia_peermem` | ☐ |
| 1.1.6 | `libcufile` + GDS path enabled on the storage mount | `gdscheck -p` | ☐ |
| 1.1.7 | NVIDIA HPC SDK available (for ClusterKit / pgcc) at `/opt/nvidia/hpc_sdk/...` | dir exists | ☐ |

### 1.2 Mellanox / IB stack — every compute node

| # | Item | What we check it with | Status |
|---|------|------------------------|--------|
| 1.2.1 | MLNX_OFED (or DOCA-Host) installed, version pinned in PO | `ofed_info -n` | ☐ |
| 1.2.2 | `ibstat`, `mlxlink`, `mlxfwmanager`, `mst` on `$PATH` | which / `mst status` | ☐ |
| 1.2.3 | `perftest` package (`ib_write_lat`, `ib_write_bw`, etc.) | `apt list --installed perftest` | ☐ |
| 1.2.4 | NCCL (`libnccl2`) installed, vendor-blessed version | `dpkg -l libnccl2` | ☐ |
| 1.2.5 | NCCL SHARP plugin (`libnccl-net-sharp.so`) present + loadable | `ldconfig -p \| grep nccl-net-sharp` | ☐ |
| 1.2.6 | UFM running on a dedicated host, REST API enabled | `curl -k https://$UFM_HOST/ufmRest/...` | ☐ |
| 1.2.7 | Subnet manager (UFM SM or OpenSM) active, exactly one master | UFM dashboard | ☐ |
| 1.2.8 | SHARP aggregation trees configured | UFM dashboard | ☐ |
| 1.2.9 | Adaptive Routing enabled cluster-wide | UFM dashboard | ☐ |

### 1.3 Container runtime — every compute node

| # | Item | What we check it with | Status |
|---|------|------------------------|--------|
| 1.3.1 | Enroot installed | `enroot version` | ☐ |
| 1.3.2 | Pyxis Slurm plugin installed | `srun --container-image=...` works | ☐ |
| 1.3.3 | Container registry (`nvcr.io` or internal mirror) reachable from every compute node | `enroot import docker://nvcr.io/...` | ☐ |

### 1.4 Pre-staged container images / binaries

These ship as containers from NVIDIA. We need them either pulled into the
local registry **or** extracted on shared storage so every node can launch
them. Without these, Phase 3 (`§3.8–3.11`) and Phase 5 cannot run.

| # | Item | Path / source | Status |
|---|------|----------------|--------|
| 1.4.1 | NVIDIA HPC Benchmarks container (provides `xhpl`, `xhpl_mxp`, `xhpcg`) | `nvcr.io/nvidia/hpc-benchmarks:...` | ☐ |
| 1.4.2 | `llmb-run` callable from login node | `which llmb-run` | ☐ |
| 1.4.3 | NeMo / training image (for Phase 5 long-soak) | `nvcr.io/nvidia/nemo:...` | ☐ |

### 1.5 Cluster services

| # | Item | What we check it with | Status |
|---|------|------------------------|--------|
| 1.5.1 | Slurm (`slurmctld`, `slurmd`, `slurmdbd`) running | `sinfo`, `sacctmgr list assoc` | ☐ |
| 1.5.2 | MUNGE running on every node, shared key deployed | `munge -n \| ssh node unmunge` | ☐ |
| 1.5.3 | A Slurm partition that holds all 128 nodes, accessible to our test account | `sinfo -p <partition>` | ☐ |
| 1.5.4 | Slurm prolog/epilog clears `/dev/shm`, drops caches, resets GPU clocks between jobs | provider's prolog scripts | ☐ |
| 1.5.5 | Shared home (`/home/<test-user>`) mounted on every compute node | `srun -N 128 ls $HOME` | ☐ |
| 1.5.6 | NTP / chrony in sync across compute + switches + BMCs + UFM | `chronyc tracking` | ☐ |

### 1.6 Storage client

| # | Item | What we check it with | Status |
|---|------|------------------------|--------|
| 1.6.1 | Parallel filesystem client (Lustre / GPFS / WekaFS / VAST / etc.) installed on every compute node | `mount \| grep <fstype>` | ☐ |
| 1.6.2 | Filesystem mounted at the **same path** on every node | `srun -N 128 mountpoint <path>` | ☐ |
| 1.6.3 | The test account has read/write under a dedicated scratch directory, no quota | `touch / dd` from compute | ☐ |
| 1.6.4 | GDS path validated (`libcufile` opens files on this mount with `O_DIRECT` + GPU buffers) | `gdscheck -f <path>` | ☐ |

### 1.7 Network egress from compute / login (so our bootstrap can run)

If any of these are blocked, the provider needs to mirror the relevant repos
internally and tell us the mirror URL. Otherwise `bootstrap/install.sh`
fails on every node.

| # | Endpoint | What we use it for | Status |
|---|----------|---------------------|--------|
| 1.7.1 | `archive.ubuntu.com` (or mirror) | `apt-get install` | ☐ |
| 1.7.2 | `pypi.org` (or mirror) | `pip install` | ☐ |
| 1.7.3 | `github.com` (or mirror) | clone IOR, elbencho, nccl-tests, nvbandwidth, gpu-burn, BabelStream | ☐ |
| 1.7.4 | `nvcr.io` (or internal copy) | pull HPC Benchmarks + NeMo containers | ☐ |

### 1.8 What the provider does **not** need to install

For their convenience — this is the list of things our bootstrap installs
itself, so they should not duplicate the work but should ensure §1.7 holds:

- **apt packages**: `infiniband-diags`, `ipmitool`, `curl`, `dmidecode`, `python3`, `python3-pip`, `openssh-client`, `build-essential`, `cmake`, `git`, `pkg-config`, `numactl`, `nvme-cli`, `chrony`, `linux-tools-common`, `jq`, `fio`, `libnuma-dev`, `autoconf`, `automake`, `libtool`, `libboost-program-options-dev`, `libboost-system-dev`, `libncurses-dev`, `libaio-dev`, `uuid-dev`.
- **pip packages**: `pyyaml`, `pandas`, `pyarrow`, `numpy`, `mlperf-storage`.
- **Source builds** (pinned tags in `bootstrap/install.sh`): IOR + mdtest, elbencho (with `CUDA_SUPPORT=1 CUFILE_SUPPORT=1`), nccl-tests, nvbandwidth, gpu-burn, BabelStream.

---

## 2. Information to deliver

Every value below feeds either an `env.sh` knob or an inventory file in
this repo. Where the destination is known, the right-hand column points at
it so the provider can hand back values in the same shape we consume them.

### 2.1 Inventory files (plain text, one entry per line)

| # | File | Contents | Status |
|---|------|----------|--------|
| 2.1.1 | `nodes.txt` | 128 compute hostnames, one per line | ☐ |
| 2.1.2 | `bmc_hosts.txt` | 128 BMC addresses / hostnames, **same order** as `nodes.txt` | ☐ |
| 2.1.3 | `ib_switches.txt` | All IB leaf + spine switch management IPs | ☐ |

These get dropped at `${P0_ROOT}/`, where `P0_ROOT` defaults to
`/opt/qualification/phase0`. They are read by every Phase 0 sweep.

### 2.2 Access credentials

| # | Field | Format | Goes into | Status |
|---|-------|--------|-----------|--------|
| 2.2.1 | SSH test account username | string | — | ☐ |
| 2.2.2 | SSH public key acceptance | confirm our pubkey is in `~/.ssh/authorized_keys` on every node | — | ☐ |
| 2.2.3 | sudo policy for test account | passwordless / NOPASSWD command allowlist / none | `P0_SSH_USER` | ☐ |
| 2.2.4 | IPMI / Redfish username | string | `P0_IPMI_USER` | ☐ |
| 2.2.5 | IPMI / Redfish password | string (delivered via sealed envelope / secrets manager, not email) | `P0_IPMI_PASS` | ☐ |
| 2.2.6 | BMC protocol to use | `ipmitool` or `redfish` | `P0_BMC_PROTOCOL` | ☐ |
| 2.2.7 | UFM REST hostname | FQDN or IP | `UFM_HOST` | ☐ |
| 2.2.8 | UFM REST username | string | `UFM_USER` | ☐ |
| 2.2.9 | UFM REST password | string (sealed) | `UFM_PASS_FILE` (we'll place at `/etc/ufm.pass`) | ☐ |
| 2.2.10 | Login node hostname | FQDN reachable over Sarvam VPN | — | ☐ |
| 2.2.11 | Container registry creds (if `nvcr.io` requires login) | username + token | passed to `enroot` | ☐ |

### 2.3 Slurm

| # | Field | Goes into | Status |
|---|-------|-----------|--------|
| 2.3.1 | Slurm partition name (holds all 128 nodes) | `phase*.sbatch --partition=` | ☐ |
| 2.3.2 | Slurm account name (with charging set up if needed) | `phase*.sbatch --account=` | ☐ |
| 2.3.3 | Max wall-clock the account can request | sizing Phase 3 (8 h) and Phase 5 (72 h+) jobs | ☐ |
| 2.3.4 | QoS levels available (if any) | optional | ☐ |

### 2.4 Storage

| # | Field | Goes into | Status |
|---|-------|-----------|--------|
| 2.4.1 | Filesystem mount path on compute nodes | `P4_STORAGE_ROOT` | ☐ |
| 2.4.2 | Scratch sub-directory the test account can use freely | under `P4_STORAGE_ROOT/phase4/` | ☐ |
| 2.4.3 | Default stripe count / size we should use for large-IO tests | passed to IOR via `lfs setstripe` (or vendor equivalent) | ☐ |

### 2.5 Topology counts (confirm vs PO)

These are already pinned in `phase0-precommission/env.sh` to the contracted
values. We need the provider to confirm one number per row, so any
last-minute change to the build (e.g. a leaf cut) gets caught up-front.

| # | Field | Pinned default | Provider confirms | Status |
|---|-------|----------------|--------------------|--------|
| 2.5.1 | `EXPECTED_NODE_COUNT` | 128 | | ☐ |
| 2.5.2 | `EXPECTED_GPUS_PER_NODE` | 8 | | ☐ |
| 2.5.3 | `EXPECTED_NICS_PER_NODE` | 8 | | ☐ |
| 2.5.4 | `EXPECTED_LEAF_COUNT` | 16 | | ☐ |
| 2.5.5 | `EXPECTED_SPINE_COUNT` | 8 | | ☐ |

### 2.6 Firmware actually shipped

Filled by the provider into
[`phase0-precommission/reference/expected_firmware.yaml`](phase0-precommission/reference/expected_firmware.yaml).
We use this as the contractual baseline for `firmware_diff.py`: any node
that drifts is FAIL. The exact YAML keys to fill (each currently
`TODO_FILL_AT_BURNIN`):

| YAML key | Where they read it from | Status |
|----------|--------------------------|--------|
| `host_firmware.bios_version` | `dmidecode -s bios-version` | ☐ |
| `host_firmware.bios_date` | `dmidecode -s bios-release-date` | ☐ |
| `host_firmware.sys_product` | `dmidecode -s system-product-name` | ☐ |
| `host_firmware.baseboard_mfg` | `dmidecode -s baseboard-manufacturer` | ☐ |
| `host_os.kernel` | `uname -r` | ☐ |
| `host_os.os_release_contains` | `cat /etc/os-release` | ☐ |
| `nvidia_stack.driver_smi` | `nvidia-smi --query-gpu=driver_version` | ☐ |
| `nvidia_stack.vbios` | `nvidia-smi --query-gpu=vbios_version` | ☐ |
| `nvidia_stack.fm_version_contains` | `nv-fabricmanager --version` | ☐ |
| `mellanox_stack.mlx_fw_contains` | `mst status -v` / `flint -d ... q` | ☐ |
| `software_stack.enroot_contains` | `enroot version` | ☐ |
| `software_stack.pyxis_contains` | `dpkg -l nvslurm-plugin-pyxis` | ☐ |
| `kernel_modules.mod_nvidia_srcversion` | `modinfo nvidia \| grep srcversion` | ☐ |
| `kernel_modules.mod_peermem_srcversion` | `modinfo nvidia-peermem \| grep srcversion` | ☐ |
| `kernel_modules.mod_mlx5_srcversion` | `modinfo mlx5_core \| grep srcversion` | ☐ |

### 2.7 Vendor reference performance numbers

These are the "what to expect" numbers our threshold knobs compare measured
results against. If the provider already has a published reference for the
exact configuration (e.g. NVIDIA's B200 reference results), point us at it
and we'll extract them; otherwise fill in directly.

| # | Number | env.sh knob | Status | Value |
|---|--------|--------------|--------|-------|
| 2.7.1 | NCCL all-reduce busbw, 1024 GPUs (GB/s) | `NCCL_AR_BUSBW_MIN_1024GPU_GBS` | ☐ | |
| 2.7.2 | NCCL all-gather busbw, 1024 GPUs (GB/s) | `NCCL_AG_BUSBW_MIN_1024GPU_GBS` | ☐ | |
| 2.7.3 | NCCL reduce-scatter busbw, 1024 GPUs (GB/s) | `NCCL_RS_BUSBW_MIN_1024GPU_GBS` | ☐ | |
| 2.7.4 | NCCL alltoall busbw, 1024 GPUs (GB/s) | `NCCL_AA_BUSBW_MIN_1024GPU_GBS` | ☐ | |
| 2.7.5 | NCCL sendrecv busbw, 1024 GPUs (GB/s) | `NCCL_SR_BUSBW_MIN_1024GPU_GBS` | ☐ | |
| 2.7.6 | SHARP-on uplift % | `P3_SHARP_MIN_GAIN_PCT` | ☐ | |
| 2.7.7 | IB intra-leaf latency ceiling (µs) | `P3_IB_INTRA_LEAF_LAT_MAX_US` | ☐ | |
| 2.7.8 | IB cross-spine latency ceiling (µs) | `P3_IB_CROSS_SPINE_LAT_MAX_US` | ☐ | |
| 2.7.9 | Pre-FEC BER per-port ceiling | `P3_PRE_FEC_BER_MAX` | ☐ | |
| 2.7.10 | HPL-MxP reference TFLOPS | `P3_HPL_MXP_REF_TFLOPS` | ☐ | |
| 2.7.11 | Storage aggregate read GB/s | `P4_IOR_READ_GBS_MIN` | ☐ | |
| 2.7.12 | Storage aggregate write GB/s | `P4_IOR_WRITE_GBS_MIN` | ☐ | |
| 2.7.13 | Storage creates/sec | `P4_MDTEST_CREATES_PER_SEC_MIN` | ☐ | |
| 2.7.14 | Per-client FIO IOPS minimum | `P4_FIO_IOPS_MIN` | ☐ | |
| 2.7.15 | Per-client FIO P99 latency ceiling (µs) | `P4_FIO_P99_LAT_US_MAX` | ☐ | |
| 2.7.16 | GDS per-NIC line rate (GB/s) | `P4_ELBENCHO_LINE_RATE_GBS` | ☐ | |
| 2.7.17 | MLPerf Storage samples/sec (reference accel profile) | `P4_MLPERF_REF_SAMPLES_PER_SEC` | ☐ | |
| 2.7.18 | Checkpoint storm aggregate write GB/s | `P4_CKPT_AGG_GBS_MIN` | ☐ | |

### 2.8 Operational contacts

| # | Field | Value | Status |
|---|-------|-------|--------|
| 2.8.1 | Provider on-call lead (Slack / email / phone) | | ☐ |
| 2.8.2 | Provider escalation contact | | ☐ |
| 2.8.3 | RMA / parts replacement procedure (1-page summary) | | ☐ |
