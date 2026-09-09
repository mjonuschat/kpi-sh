#!/bin/bash
# klipper.sh — Klipper Ecosystem. Discovered values are validated by
# identity and constrained under $HOME; env overrides bypass validation
# (trusted, same class as $repo_url in git.sh) — see spec.

moonraker_query() {
    local endpoint="$1"
    curl -fsS --max-time 8 --max-filesize 1048576 "${MOONRAKER_HOST}${endpoint}"
}

_kpi_klipper_home() {
    if [ -z "${HOME:-}" ]; then
        die "discover_klipper_env: \$HOME is unset"
    fi
    realpath "$HOME" 2>/dev/null || die "discover_klipper_env: \$HOME does not resolve to a real directory: $HOME"
}

_kpi_under_home() {
    # $1: candidate path, $2: canonical $HOME
    local candidate="$1" home="$2" resolved
    resolved="$(realpath "$candidate" 2>/dev/null)" || return 1
    case "$resolved/" in
        "$home/"*) return 0 ;;
        *) return 1 ;;
    esac
}

discover_klipper_env() {
    local home
    # _kpi_klipper_home's own die() only exits the command-substitution
    # subshell it runs in — an unguarded assignment here would let
    # discover_klipper_env continue with an empty $home instead of
    # actually stopping, defeating the "invalid $HOME is a hard stop"
    # contract from the spec.
    home="$(_kpi_klipper_home)" || die "discover_klipper_env: cannot determine \$HOME"

    local host_was_set=0
    [ -n "${MOONRAKER_HOST:-}" ] && host_was_set=1
    : "${MOONRAKER_HOST:=http://localhost:7125}"
    if [ "$host_was_set" -eq 1 ] && [ "$MOONRAKER_HOST" != "http://localhost:7125" ]; then
        log "MOONRAKER_HOST overridden to a non-default host — discovery will trust that host's response"
    fi

    local info=""
    if ! info="$(moonraker_query /printer/info 2>/dev/null)"; then
        log "discover_klipper_env: Moonraker unreachable, falling back to hardcoded defaults"
        info=""
    fi

    if [ -z "${KLIPPER_PATH:-}" ]; then
        local candidate
        # `|| true`: this is a plain assignment, not part of an if/&&/||
        # list, so under a consumer's `set -e` a nonzero json_get (missing
        # key — the normal case when Moonraker has no klipper_path) would
        # otherwise abort the whole installer instead of falling back.
        candidate="$(printf '%s' "$info" | json_get result klipper_path 2>/dev/null)" || true
        if [ -n "$candidate" ] && _kpi_under_home "$candidate" "$home" && [ -f "$candidate/klippy/klippy.py" ]; then
            KLIPPER_PATH="$candidate"
        else
            log "discover_klipper_env: no usable klipper_path from Moonraker, falling back to default"
            KLIPPER_PATH="${HOME}/klipper"
        fi
    fi

    if [ -z "${KLIPPY_PYTHON:-}" ]; then
        local candidate
        candidate="$(printf '%s' "$info" | json_get result python_path 2>/dev/null)" || true
        if [ -n "$candidate" ] && _kpi_under_home "$candidate" "$home" \
            && [ -x "$candidate" ] \
            && [ "$("$candidate" -c 'import sys; print(sys.version_info[0])' 2>/dev/null)" = "3" ]; then
            KLIPPY_PYTHON="$candidate"
        else
            log "discover_klipper_env: no usable python_path from Moonraker, falling back to default"
            KLIPPY_PYTHON="${HOME}/klippy-env/bin/python"
        fi
    fi

    if [ -z "${KLIPPER_PLUGINS_PATH:-}" ]; then
        if [ -d "${KLIPPER_PATH}/klippy/plugins" ]; then
            KLIPPER_PLUGINS_PATH="${KLIPPER_PATH}/klippy/plugins"
        else
            KLIPPER_PLUGINS_PATH="${KLIPPER_PATH}/klippy/extras"
        fi
    fi

    if [ -z "${MOONRAKER_CONFIG:-}" ]; then
        if [ -f "${HOME}/printer_data/config/moonraker.conf" ]; then
            MOONRAKER_CONFIG="${HOME}/printer_data/config/moonraker.conf"
        else
            MOONRAKER_CONFIG="${HOME}/klipper_config/moonraker.conf"
        fi
    fi
}

check_no_active_print() {
    local state
    # `|| true`: a plain assignment, not part of an if/&&/|| list — an
    # unreachable Moonraker or a missing field must not abort a
    # consumer's set -e script here (the documented "unreachable -> 1"
    # outcome needs to be reached, not skipped by an early script exit).
    state="$(moonraker_query /printer/objects/query?print_stats 2>/dev/null | json_get result status print_stats state 2>/dev/null)" || true
    case "$state" in
        standby | complete | cancelled | error) return 0 ;;
        *) return 1 ;;
    esac
}
