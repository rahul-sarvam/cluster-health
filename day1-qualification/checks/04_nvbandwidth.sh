#!/usr/bin/env bash
# 04_nvbandwidth.sh
# Intra-node bandwidth: P2P (NVLink/NVSwitch), H2D, D2H. Catches single-GPU
# NVLink lane failures, partial NVSwitch routes, bad PCIe lanes.
set -uo pipefail
source "${QUAL_ROOT}/slurm/env.sh"

OUT="${QUAL_LOGS}/$(hostname)_nvbandwidth.txt"

# We run the most important matrices. See `nvbandwidth -l` for the full set.
"${NVBANDWIDTH_BIN}" \
    -t device_to_device_memcpy_read_ce \
    -t device_to_device_memcpy_write_ce \
    -t device_to_device_bidirectional_memcpy_ce \
    -t host_to_device_memcpy_ce \
    -t device_to_host_memcpy_ce \
    > "${OUT}" 2>&1
rc=$?

# Parse the bidirectional P2P matrix: extract the min, mean, and worst pair.
metrics=$(python3 - <<'PY'
import re, json, sys, os
out = os.environ["OUT"]
text = open(out).read()
# nvbandwidth prints matrices like:
#   memcpy CE bidirectional bandwidth GPU(row) -> GPU(col) (GB/s)
#         0     1     2     ...
#   0    -    900   899  ...
#   1   898    -    901  ...
def parse_matrix(label):
    m = re.search(rf"{label}.*?\n(?P<body>(?:\s*\d+(?:\s+[\d\-\.]+){{2,}}\n)+)", text, re.S)
    if not m: return None
    vals = []
    for ln in m.group("body").strip().splitlines():
        toks = ln.split()[1:]
        for t in toks:
            if t in ("-", "N/A"): continue
            try: vals.append(float(t))
            except ValueError: pass
    return vals

p2p_bidir = parse_matrix("bidirectional") or []
h2d = parse_matrix("host_to_device") or []
d2h = parse_matrix("device_to_host") or []

def stats(xs):
    if not xs: return dict(n=0, min=0, max=0, mean=0)
    return dict(n=len(xs), min=min(xs), max=max(xs), mean=sum(xs)/len(xs))

result = dict(p2p_bidir=stats(p2p_bidir), h2d=stats(h2d), d2h=stats(d2h))
print(json.dumps(result))
PY
)
export OUT
metrics=$(OUT="${OUT}" python3 -c "
import re, json, os
text = open(os.environ['OUT']).read()
def parse_matrix(label):
    m = re.search(rf'{label}.*?\n(?P<body>(?:\s*\d+(?:\s+[\d\-\.]+){{2,}}\n)+)', text, re.S)
    if not m: return []
    vals = []
    for ln in m.group('body').strip().splitlines():
        for t in ln.split()[1:]:
            if t in ('-','N/A'): continue
            try: vals.append(float(t))
            except ValueError: pass
    return vals
def stats(xs):
    if not xs: return dict(n=0, min=0, max=0, mean=0)
    return dict(n=len(xs), min=min(xs), max=max(xs), mean=sum(xs)/len(xs))
p2p = parse_matrix('bidirectional')
h2d = parse_matrix('host_to_device')
d2h = parse_matrix('device_to_host')
print(json.dumps(dict(p2p_bidir=stats(p2p), h2d=stats(h2d), d2h=stats(d2h))))
")

p2p_min=$(echo "${metrics}" | python3 -c "import json,sys; print(json.load(sys.stdin)['p2p_bidir']['min'])")

status="pass"
fail=0
if (( $(echo "${p2p_min} < ${NVBW_P2P_BIDIR_MIN_GBS}" | bc -l) )); then
    status="fail"
    fail=1
fi

qual_emit nvbandwidth "${status}" \
    log_path="${OUT}" \
    p2p_bidir_min_gbs="${p2p_min}" \
    metrics="${metrics}"

exit "${fail}"
