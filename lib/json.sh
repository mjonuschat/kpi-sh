#!/bin/bash
# json.sh — JSON Parsing. Python 3 is autodetected lazily here (first
# call), not at header.sh init — see spec "Python 3 detection is lazy."

_kpi_ensure_python() {
    if [ -n "${_KPI_PYTHON:-}" ]; then
        return 0
    fi
    local candidate
    for candidate in python3 python; do
        if command -v "$candidate" >/dev/null 2>&1; then
            if "$candidate" -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' 2>/dev/null; then
                _KPI_PYTHON="$(command -v "$candidate")"
                return 0
            fi
        fi
    done
    die "json_get: no Python 3 interpreter found (tried python3, python)"
}

json_get() {
    _kpi_ensure_python

    "$_KPI_PYTHON" -c '
import sys, json

keys = sys.argv[1:]
try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError) as exc:
    print(f"json_get: malformed JSON: {exc}", file=sys.stderr)
    sys.exit(2)

cur = data
for key in keys:
    if not isinstance(cur, dict) or key not in cur:
        sys.exit(1)
    cur = cur[key]

if isinstance(cur, (dict, list)):
    sys.exit(1)
if cur is None:
    print("")
elif isinstance(cur, bool):
    print("true" if cur else "false")
else:
    print(cur)
sys.exit(0)
' "$@"
    local rc=$?
    if [ "$rc" -eq 2 ]; then
        die "json_get: malformed input JSON"
    fi
    return "$rc"
}
