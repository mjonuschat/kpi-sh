#!/bin/bash
# header.sh — Library Init. See docs/superpowers/specs/2026-06-27-kpi-sh-design.md
# "header.sh — Library Init" for the full rationale behind every check below.

if declare -F _kpi_init_done >/dev/null 2>&1; then
    return 0 2>/dev/null || exit 0
fi

export LC_ALL=C

if ((BASH_VERSINFO[0] < 4)); then
    echo "error: kpi-sh requires Bash 4.0 or newer (found ${BASH_VERSION})" >&2
    exit 1
fi

: "${_KPI_INPUT_FD:=}"
# _KPI_PYTHON's DETECTION stays lazy (first json_get call, see json.sh) —
# but the variable itself must exist under a consumer's set -u before
# that first call ever happens, same reasoning as _KPI_INPUT_FD above.
: "${_KPI_PYTHON:=}"
if [ -z "${_KPI_INPUT_FD}" ]; then
    if [ -e /proc/self/fd/9 ]; then
        # fd 9 already belongs to the consumer (any mode) — don't touch it.
        _KPI_INPUT_FD=""
    elif { exec 9<>/dev/tty; } 2>/dev/null; then
        _KPI_INPUT_FD=9
    else
        _KPI_INPUT_FD=""
    fi
fi

_kpi_init_done() { :; }
