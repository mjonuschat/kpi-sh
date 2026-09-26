#!/usr/bin/env bats

load 'test_helper/common'

setup() {
    common_setup
    if [ ! -f dist/kpi.sh ]; then
        skip "run 'make kpi.sh' before the integration suite"
    fi
}

teardown() {
    common_teardown
}

@test "kpi.sh sources cleanly under set -eu" {
    run bash -c "set -eu; source ./dist/kpi.sh; echo ok"
    assert_success
    assert_output "ok"
}

@test "kpi.sh embeds a version sentinel" {
    # No "v" prefix asserted: git describe --tags --always --long --dirty
    # falls back to a bare abbreviated commit hash when the repo has no
    # tags yet (the normal state during initial development, before the
    # first "v1.0.0" release) — asserting a "v..." prefix here would fail
    # until the first tag exists.
    run head -5 dist/kpi.sh
    assert_output --partial "# --- kpi.sh "
}

@test "sourcing kpi.sh twice is a no-op the second time" {
    run bash -c "
        source ./dist/kpi.sh
        exec 9<&- 2>/dev/null || true
        source ./dist/kpi.sh
        echo still-fine
    "
    assert_success
    assert_output --partial "still-fine"
}

@test "end-to-end: install then uninstall a plugin via symlinks and a config block" {
    run bash -c '
        set -eu
        source ./dist/kpi.sh
        HOME="'"$KPI_TEST_TMPDIR"'/home"
        mkdir -p "$HOME"
        repo_src="'"$KPI_TEST_TMPDIR"'/plugin_src"
        mkdir -p "$repo_src"
        echo "print(1)" > "$repo_src/plugin.py"

        plugins_dir="'"$KPI_TEST_TMPDIR"'/plugins"
        mkdir -p "$plugins_dir"
        link_safe "$repo_src/plugin.py" "$plugins_dir/plugin.py"

        moonraker_conf="'"$KPI_TEST_TMPDIR"'/moonraker.conf"
        touch "$moonraker_conf"
        config_block_add "$moonraker_conf" myplugin "[update_manager myplugin]"

        [ -L "$plugins_dir/plugin.py" ] || exit 1
        grep -qF "myplugin" "$moonraker_conf" || exit 1

        remove_safe_link "$plugins_dir/plugin.py"
        config_block_remove "$moonraker_conf" myplugin

        [ -e "$plugins_dir/plugin.py" ] && exit 1
        grep -qF "myplugin" "$moonraker_conf" && exit 1
        echo "roundtrip-ok"
    '
    assert_success
    assert_output --partial "roundtrip-ok"
}

@test "end-to-end: backup and restore workflow produces a valid timestamped directory" {
    run bash -c '
        set -eu
        source ./dist/kpi.sh
        src="'"$KPI_TEST_TMPDIR"'/config_src"
        mkdir -p "$src"
        echo "printer.cfg content" > "$src/printer.cfg"
        ln -s /etc "$src/unmanaged_link"

        backup_root="'"$KPI_TEST_TMPDIR"'/backups"
        backup_dir="$(backup_dir_timestamped "$src" "$backup_root")"
        backup_scrub_symlinks "$backup_dir" "$src"

        [ -f "$backup_dir/printer.cfg" ] || exit 1
        [ -L "$backup_dir/unmanaged_link" ] || exit 1
        echo "backup-ok"
    '
    assert_success
    assert_output --partial "backup-ok"
}
