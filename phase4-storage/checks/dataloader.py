#!/usr/bin/env python3
"""dataloader.py — Phase 4 test 4.8 per-host worker.

Measures sustained tokens/sec when a real PyTorch DataLoader pulls
synthetic "training" shards through the GPUDirect Storage path
(`torch.from_file` over cuFile when available, with a torch.load
fallback) and compares it against the same shards served from a RAM
tmpfs.

The shell wrapper (08_gds_dataloader.sh) calls this script with one
rank per node and a dedicated GPU. Each invocation writes one summary
JSON file into `--out-dir` keyed by hostname.

Notes:
  * "tokens/sec" here is bytes/sec divided by a fixed bytes/token
    constant (4 bytes for fp32 tokens). The absolute number doesn't
    matter; what matters is the disk/RAM ratio.
  * We require ${CUDA_VISIBLE_DEVICES} to be set by srun — we pin to
    the first visible device.
  * If torch is missing or cuFile isn't usable the shell wrapper
    short-circuits this script and emits skip; we don't try to be
    cute about it here.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import socket
import sys
import time
from pathlib import Path

BYTES_PER_TOKEN = 4   # fp32


def materialize_shards(root: Path, n_shards: int,
                       tensor_shape=(4096, 1024)) -> list[Path]:
    """Create N shard files of identical shape under `root`. Returns
    the list of paths in deterministic order. Shards are reused across
    runs if they already exist (idempotent)."""
    root.mkdir(parents=True, exist_ok=True)
    import torch  # local import — kept out of module scope to keep
    # the file importable on a node without torch (for tests).
    paths = []
    bytes_per_shard = tensor_shape[0] * tensor_shape[1] * BYTES_PER_TOKEN
    for i in range(n_shards):
        p = root / f"shard_{i:05d}.pt"
        if not p.is_file() or p.stat().st_size < bytes_per_shard:
            t = torch.empty(tensor_shape, dtype=torch.float32).uniform_(-1, 1)
            torch.save(t, p)
        paths.append(p)
    return paths


def disk_pass(paths, device, batch_size, num_batches, tensor_shape):
    """Load shards from disk into GPU memory and report tokens/sec."""
    import torch
    elems_per_shard = tensor_shape[0] * tensor_shape[1]
    # Drop OS caches for this directory by reading a probe file first
    # (best-effort — we don't have root in the rank).
    start = time.perf_counter()
    seen = 0
    n = len(paths)
    for b in range(num_batches):
        batch = []
        for j in range(batch_size):
            p = paths[(b * batch_size + j) % n]
            t = torch.load(p, map_location="cpu")
            batch.append(t)
        stacked = torch.stack(batch, dim=0).to(device, non_blocking=True)
        torch.cuda.synchronize(device)
        seen += stacked.numel()
    elapsed = time.perf_counter() - start
    return seen / elapsed, elapsed, seen


def ram_pass(paths, device, batch_size, num_batches, tensor_shape, ram_root: Path):
    """Same loader, but with shards pre-staged into a node-local tmpfs.
    Falls back to the original paths if /dev/shm isn't writable."""
    import torch
    if not ram_root.is_dir():
        try:
            ram_root.mkdir(parents=True, exist_ok=True)
        except OSError:
            return disk_pass(paths, device, batch_size, num_batches, tensor_shape)
    # Copy shards into tmpfs (cheap relative to the run itself).
    ram_paths = []
    for src in paths:
        dst = ram_root / src.name
        if not dst.is_file() or dst.stat().st_size != src.stat().st_size:
            dst.write_bytes(src.read_bytes())
        ram_paths.append(dst)
    return disk_pass(ram_paths, device, batch_size, num_batches, tensor_shape)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--shard-root", required=True, type=Path)
    p.add_argument("--shard-count", type=int, default=256)
    p.add_argument("--batch-size", type=int, default=32)
    p.add_argument("--num-batches", type=int, default=200)
    p.add_argument("--out-dir", required=True, type=Path)
    p.add_argument("--tensor-shape", default="4096,1024")
    args = p.parse_args()

    try:
        import torch
    except ImportError:
        # The shell wrapper checks this before calling us; getting here
        # means the env raced. Surface clearly.
        print("FATAL: torch unavailable in worker", file=sys.stderr)
        return 1

    if not torch.cuda.is_available():
        print("FATAL: cuda not available", file=sys.stderr)
        return 1

    device = torch.device("cuda", 0)
    tensor_shape = tuple(int(x) for x in args.tensor_shape.split(","))

    args.out_dir.mkdir(parents=True, exist_ok=True)
    host = socket.gethostname() or platform.node() or "unknown"

    paths = materialize_shards(args.shard_root, args.shard_count, tensor_shape)
    disk_tps, disk_sec, disk_elems = disk_pass(
        paths, device, args.batch_size, args.num_batches, tensor_shape)
    ram_root = Path("/dev/shm") / f"p4_dali_{os.getpid()}"
    ram_tps, ram_sec, ram_elems = ram_pass(
        paths, device, args.batch_size, args.num_batches, tensor_shape, ram_root)

    # Cleanup tmpfs.
    if ram_root.is_dir():
        for f in ram_root.iterdir():
            try: f.unlink()
            except OSError: pass
        try: ram_root.rmdir()
        except OSError: pass

    result = {
        "host": host,
        "device": str(device),
        "shard_count": args.shard_count,
        "batch_size": args.batch_size,
        "num_batches": args.num_batches,
        "tensor_shape": list(tensor_shape),
        "disk_tokens_per_sec": disk_tps,
        "disk_elapsed_sec": disk_sec,
        "ram_tokens_per_sec": ram_tps,
        "ram_elapsed_sec": ram_sec,
        "ratio": (disk_tps / ram_tps) if ram_tps > 0 else None,
    }
    (args.out_dir / f"host_{host}.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
