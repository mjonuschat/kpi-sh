#!/bin/bash
set -eu
source "$(dirname "${BASH_SOURCE[0]}")/../../dist/kpi.sh"

require_not_root
require_systemd_service klipper
discover_klipper_env

git_ensure_clone "https://github.com/example/simple-plugin.git" \
    "${HOME}/simple-plugin" "plugin.py"

link_safe "${HOME}/simple-plugin/plugin.py" \
    "${KLIPPER_PLUGINS_PATH}/plugin.py"

service_restart_if klipper check_no_active_print
log "simple-plugin installed."
