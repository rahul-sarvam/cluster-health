# Questions for E2E Networks

A focused list we want answered before we finalise the acceptance strategy
on the `e2e` branch. Most of these gate concrete engineering decisions on
our side — phrased so each is yes/no, a number, an endpoint URL, or a
named-product answer.

The strategy these unblock is in [`E2E_STRATEGY.md`](E2E_STRATEGY.md).

## 1. Provisioning and API surface

| # | Question | Why we ask | Answer |
|---|----------|-------------|---------|
| 1.1 | Is there a Terraform provider for E2E? If yes, what is the registry path and minimum version? | Determines whether IaC is the source of truth or just convenience | |
| 1.2 | Is there a public REST API? Link to docs. | Backstop if Terraform doesn't cover a workflow | |
| 1.3 | Is there a vendor CLI? Name + install path. | For interactive ops |  |
| 1.4 | Do you offer service-account credentials for CI use, or only user-bound tokens? | Affects how we automate | |
| 1.5 | What is the smallest unit of provisioning — a single GPU pod, a fixed-size cluster, or arbitrary node counts? | Affects test sizing | |
| 1.6 | What is the maximum cluster size we can provision in one call? | For full-scale Phase 3 | |
| 1.7 | How long does a typical 128-node Slinky cluster take to come up, from `terraform apply` to a usable `sinfo`? | For CI test budget | |
| 1.8 | Is provisioning idempotent — does re-running `terraform apply` with the same config yield the same cluster shape? | Reproducibility of acceptance | |

## 2. Cluster composition and topology

| # | Question | Answer |
|---|----------|---------|
| 2.1 | What GPU types are available? (B200 / H200 / H100 / etc.) | |
| 2.2 | What's the per-node GPU count for the B200 SKU? Is it fixed at 8? | |
| 2.3 | Is the IB fabric NDR end-to-end? | |
| 2.4 | Rail-optimised topology? Pinned NIC-to-GPU mapping? | |
| 2.5 | How are K8s nodes labelled for topology? Do they expose `topology.kubernetes.io/zone`, a rack ID, a leaf ID? | |
| 2.6 | Is SHARP enabled by default on the IB fabric? | |
| 2.7 | Is Adaptive Routing enabled by default? | |
| 2.8 | Can we control SHARP / AR per-job (e.g. via NCCL env vars), or only at the platform level? | |
| 2.9 | What's the host CPU + RAM per B200 node? | |
| 2.10 | Is there local NVMe per node accessible to the pod? If yes, size and mount path. | |
| 2.11 | When we ask for N nodes, are we guaranteed N *physical* nodes (not shared), or is the underlying allocation shared? | |

## 3. Container images and registry

| # | Question | Answer |
|---|----------|---------|
| 3.1 | What's the catalog of pre-built images? Names + tag conventions. | |
| 3.2 | For each image, what versions are pinned — driver, CUDA, NCCL, MOFED, UCX, PyTorch, NeMo, vLLM, TGI, TRT-LLM? | |
| 3.3 | Are images published with sha256 digests we can pin to? | |
| 3.4 | Where is the registry — a public URL we can `docker pull` from, an internal mirror we have to use? | |
| 3.5 | Can we bring our own image? Any size limit? Any forbidden base images? | |
| 3.6 | Do pre-built images include `dcgmi`, `nccl-tests`, `nvbandwidth`, `gpu-burn`, `BabelStream`? Or do we need to build a qualification image? | |
| 3.7 | Container runtime under the hood — Docker / containerd / Enroot+Pyxis for Slurm jobs? | |
| 3.8 | For Slurm-on-Slinky, how do we pass an image to `sbatch`? `--container-image=` flag (Pyxis convention), or a different mechanism? | |
| 3.9 | What's the cold-start time for a 30 GB image on a fresh node? Is there an image pre-pull mechanism we can opt into? | |

## 4. Storage and filesystems

| # | Question | Answer |
|---|----------|---------|
| 4.1 | What parallel filesystems are on offer? Weka / Lustre / VAST / GPFS / cloud-native blob / other? | |
| 4.2 | For each, what's the per-cluster vs. shared model — do we get a dedicated PFS instance, or share with other tenants? | |
| 4.3 | What's the published peak read / write throughput per PFS option, at the smallest and largest provisioning size? | |
| 4.4 | Is GDS (libcufile + nvidia-fs) enabled on all PFS options, some of them, or none? | |
| 4.5 | Mount path inside the pod — is it consistent across the cluster (so it can be `P4_STORAGE_ROOT` without per-pod logic)? | |
| 4.6 | Can we control stripe size / replica count / placement policy? | |
| 4.7 | Is there ephemeral local NVMe per node? Size, mount path, lifecycle. | |
| 4.8 | How is the PFS provisioned — via the same Terraform module as compute, separately, or only via UI? | |
| 4.9 | Are there quotas per tenant? What's the default, and can we ask for more? | |
| 4.10 | What happens to PFS contents when we tear down the cluster — purged, retained, billable separately? | |

## 5. Slurm / Slinky

| # | Question | Answer |
|---|----------|---------|
| 5.1 | What Slurm version does Slinky deploy? | |
| 5.2 | Does `scontrol show topology` return populated rack / leaf data? | |
| 5.3 | Does `sinfo -N -o "%f"` return useful features (rack ID, GPU model, NVLink generation)? | |
| 5.4 | Is `srun --container-image=...` the right way to launch containerised steps, or do we use a different mechanism? | |
| 5.5 | Are GPUs exposed via `gres/gpu` with autodetect, or do we need to specify gres counts manually? | |
| 5.6 | Is GPUDirect RDMA available from Slurm-launched pods without extra config? | |
| 5.7 | Does Slinky pre-empt our jobs for higher-priority tenants? | |
| 5.8 | Can we run a single Slurm job for ≥72 hours, or are there hard wall-clock limits? | |
| 5.9 | Is `sacct` history accessible from the login pod? For how long? | |
| 5.10 | Pre-emption / requeue behaviour when a Slinky pod dies mid-job? | |
| 5.11 | Does Slinky configure `--with-pmix` so NCCL bootstraps correctly at scale, or do we need to set `NCCL_BOOTSTRAP=...`? | |

## 6. Monitoring and observability

| # | Question | Answer |
|---|----------|---------|
| 6.1 | Do you expose a DCGM exporter endpoint we can scrape? Or a hosted Grafana with DCGM dashboards? | |
| 6.2 | Do you expose Slurm metrics (`slurm-exporter` or similar)? | |
| 6.3 | Is there a per-tenant Prometheus endpoint we can query? | |
| 6.4 | Read-only UFM access — even just a weekly fabric health report — possible? | |
| 6.5 | Per-node XID / ECC error logs accessible to us, or only to platform ops? | |
| 6.6 | Can we get `kubectl` into our namespace? (`kubectl get pods/nodes/events` is enough) | |
| 6.7 | What does the platform status page URL look like? | |
| 6.8 | Do we get notified for maintenance windows and unscheduled outages? How? | |

## 7. Multi-tenancy and isolation

| # | Question | Answer |
|---|----------|---------|
| 7.1 | Are reserved (dedicated) instances available, or is the only model shared with pre-emption? | |
| 7.2 | When we reserve N nodes, is that a hard contract or a soft target? | |
| 7.3 | Network isolation — do other tenants' workloads share our IB rails, or is each tenant on its own rail-partition? | |
| 7.4 | Storage isolation — same question for PFS bandwidth. | |
| 7.5 | If a co-located tenant's job interferes with ours, what's the remediation path? | |

## 8. Failure handling and recovery

| # | Question | Answer |
|---|----------|---------|
| 8.1 | When a physical node in a Slinky cluster fails, does Slurm see it as DOWN automatically? | |
| 8.2 | Hot spares — do you keep an N+M reserve and auto-substitute, or do we get N-1 until replacement? | |
| 8.3 | Time-to-replacement for a failed node — SLA number? | |
| 8.4 | If a GPU XID-errors, do you migrate the pod automatically or do we have to re-submit? | |
| 8.5 | What happens to a long-running training job when its pod's underlying node fails? Does Slinky requeue, or do we have to checkpoint-and-restart ourselves? | |
| 8.6 | Power / cooling incidents — automatic drain, or hard kill? | |

## 9. SLA and operations

| # | Question | Answer |
|---|----------|---------|
| 9.1 | What's the contractual SLA for compute availability (% / month)? | |
| 9.2 | SLA for PFS availability and minimum throughput? | |
| 9.3 | SLA for scheduler responsiveness (time from `sbatch` to first allocation)? | |
| 9.4 | Maintenance window policy — when, how often, how much notice? | |
| 9.5 | Driver / firmware update cadence — is it pinned for the duration of our contract or rolling? | |
| 9.6 | Notification channel for unscheduled outages affecting our tenant? | |
| 9.7 | Support response time tiers — P0 / P1 / P2? | |
| 9.8 | Who is our named contact, and is there a Slack / shared channel? | |

## 10. Cost and metering

| # | Question | Answer |
|---|----------|---------|
| 10.1 | Billing granularity — per-second / per-minute / per-hour? | |
| 10.2 | Charged on provisioning or on use? E.g. if a Slinky cluster is up but idle, are we charged? | |
| 10.3 | Storage billing — per-GB-hour at provisioned capacity, or actual used? | |
| 10.4 | Network egress charges? Inter-cluster transfer charges? | |
| 10.5 | Is there a usage report we can pull programmatically for reconciliation against acceptance test runs? | |

---

## Format for the response

If it helps E2E, the answers can be returned in any form — but if they
hand us a YAML keyed by the IDs above (`1.1`, `1.2`, …), we can ingest it
directly into a `provider_sla.yaml` and start automating the SLA-verify
phase. A short doc with the same numbering also works.
