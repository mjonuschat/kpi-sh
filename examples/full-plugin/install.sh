#!/bin/bash
set -eu
source "$(dirname "${BASH_SOURCE[0]}")/../../dist/kpi.sh"

REPO_URL="https://github.com/example/full-plugin.git"
PLUGIN_PATH="${HOME}/full-plugin"
BACKUP_PATH="${HOME}/full-plugin-backups"

# Moonraker only reads moonraker.conf at startup, so the updater entry needs a
# Moonraker restart too. The print check runs once, before either restart:
# while one service restarts, the check against the other would fail closed.
restart_services() {
    if check_no_active_print; then
        service_restart_if moonraker
        service_restart_if klipper
    else
        log "Print active: restart moonraker and klipper once it finishes."
    fi
}

main() {
    local action="${1:-install}"
    case "$action" in
        install)
            require_not_root
            require_systemd_service klipper
            discover_klipper_env

            git_ensure_clone "$REPO_URL" "$PLUGIN_PATH" "plugin.py"

            backup_dir="$(backup_dir_timestamped "${HOME}/printer_data/config" "$BACKUP_PATH")"
            backup_scrub_symlinks "$backup_dir" "$PLUGIN_PATH"

            link_safe "${PLUGIN_PATH}/plugin.py" "${KLIPPER_PLUGINS_PATH}/plugin.py"

            config_block_add "$MOONRAKER_CONFIG" "full_plugin" \
"[update_manager full_plugin]
type: git_repo
path: ${PLUGIN_PATH}
origin: ${REPO_URL}
managed_services: klipper
primary_branch: main"

            version_stamp "$PLUGIN_PATH" "${HOME}/printer_data/config/.full-plugin-VERSION"
            restart_services
            log "full-plugin installed."
            ;;
        uninstall)
            discover_klipper_env
            remove_safe_link "${KLIPPER_PLUGINS_PATH}/plugin.py"
            config_block_remove "$MOONRAKER_CONFIG" "full_plugin"
            restart_services
            log "full-plugin uninstalled."
            ;;
        *) die "usage: install.sh [install|uninstall]" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
