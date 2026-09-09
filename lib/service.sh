#!/bin/bash
# service.sh — Systemd Service Management. sudo is always used; 30s
# timeout is a fixed design constant. Exit 124 is treated as "timed
# out" — a scoped assumption, see spec.

service_restart_if() {
    local service="$1" predicate="${2:-}"

    if [ -n "$predicate" ]; then
        if ! "$predicate"; then
            log "skipping restart of $service: predicate declined or failed"
            return 0
        fi
    fi

    timeout 30 sudo systemctl restart "$service"
    local rc=$?
    if [ "$rc" -eq 124 ]; then
        die "service_restart_if: restart timed out after 30s: $service"
    elif [ "$rc" -ne 0 ]; then
        die "service_restart_if: restart failed for $service (exit $rc)"
    fi
}
