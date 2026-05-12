#!/usr/bin/env bash
# 03_dcgm_diag.sh
# Run the most thorough DCGM diagnostic. -r 4 takes 25-40 minutes on B200.
# We also separately run the EUD plugin which probes HBM more aggressively.
set -uo pipefail
source "${QUAL_ROOT}/slurm/env.sh"

JSON_OUT="${QUAL_LOGS}/$(hostname)_dcgmi.json"
EUD_OUT="${QUAL_LOGS}/$(hostname)_dcgmi_eud.json"

"${DCGMI_BIN}" diag -r 4 --json > "${JSON_OUT}" 2>&1 || true
"${DCGMI_BIN}" diag -r 3 --plugin "eud" --json > "${EUD_OUT}" 2>&1 || true

# Parse: every test must have result==PASS.
fail=$(python3 - <<PY
import json, sys
fail = 0
fails = []
for f in ("${JSON_OUT}", "${EUD_OUT}"):
    try:
        with open(f) as fh:
            data = json.load(fh)
    except Exception as e:
        fail = 1
        fails.append(f"unparseable:{f}:{e}")
        continue
    # Walk the structure; result-bearing nodes have a "status" or "result" key.
    def walk(obj, path=""):
        global fail
        if isinstance(obj, dict):
            for k, v in obj.items():
                if k in ("status","result") and isinstance(v, str) and v.upper() not in ("PASS","SKIP","WARN"):
                    fail = 1
                    fails.append(f"{path}.{k}={v}")
                else:
                    walk(v, f"{path}.{k}")
        elif isinstance(obj, list):
            for i,v in enumerate(obj):
                walk(v, f"{path}[{i}]")
    walk(data)
print(fail)
print(";".join(fails[:20]))
PY
)
rc_fail=$(echo "${fail}" | head -n1)
fail_list=$(echo "${fail}" | tail -n1)

status="pass"; [[ "${rc_fail}" -eq 1 ]] && status="fail"
qual_emit dcgmi_diag "${status}" \
    json_path="${JSON_OUT}" \
    eud_path="${EUD_OUT}" \
    failure_summary="${fail_list}"

exit "${rc_fail}"
