#!/bin/bash
# log.sh — Logging. stdout is reserved for return data across this entire
# library; log/err/die never write to it.

log() {
    printf '%s\n' "$1" >&2
}

err() {
    printf 'error: %s\n' "$1" >&2
}

die() {
    err "$1"
    exit 1
}
