#!/bin/bash
# preflight.sh — Preflight Checks. require_not_root has NO override of any
# kind — see spec "preflight.sh" for why two prior env-var-gated drafts
# were both rejected as structurally bypassable.

require_not_root() {
    if [ "$EUID" -eq 0 ]; then
        die "this script must not be run as root"
    fi
}

require_systemd_service() {
    local name="$1"
    if ! systemctl cat "$name" >/dev/null 2>&1; then
        die "systemd service not installed: $name"
    fi
}

require_python_min() {
    local -x LC_ALL=C
    local interpreter="$1" major="$2" minor="$3"
    local version
    version="$("$interpreter" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)" \
        || die "require_python_min: could not query version from $interpreter"

    local found_major="${version%%.*}"
    local found_minor="${version##*.}"
    if ((found_major < major)) || ((found_major == major && found_minor < minor)); then
        die "require_python_min: $interpreter is $version, need >= $major.$minor"
    fi
}
