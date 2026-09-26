#!/usr/bin/env bats
# Every failure must behave the same whether the function is called directly
# under `set -eu` or as an `if` condition, where errexit is suppressed and only
# the library's own explicit checks can stop it.

load 'test_helper/common'

setup() {
    common_setup
    fake_bin="$KPI_TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"
    prelude="set -eu; for f in header log path json symlink preflight git config_block service backup prompt version klipper; do source \"$BATS_TEST_DIRNAME/../lib/\$f.sh\"; done; PATH=\"$fake_bin:\$PATH\""
}

teardown() {
    chmod -R u+rwx "$KPI_TEST_TMPDIR" 2>/dev/null || true
    common_teardown
}

# $1: expected exit status, $2: expected stderr substring ("" to skip),
# $3: shell setup run before the call, $4: the call (a single simple command
# or pipeline, so it can stand as an `if` condition)
_assert_same_failure() {
    local want_status="$1" want_msg="$2" pre="$3" call="$4"

    run bash -c "$prelude; $pre; $call; echo CONTINUED"
    refute_output --partial CONTINUED
    assert_equal "$status" "$want_status"
    if [ -n "$want_msg" ]; then assert_output --partial "$want_msg"; fi

    run bash -c "$prelude; $pre; if $call; then echo CONTINUED; else exit \$?; fi"
    refute_output --partial CONTINUED
    assert_equal "$status" "$want_status"
    if [ -n "$want_msg" ]; then assert_output --partial "$want_msg"; fi
}

_skip_if_root() {
    if [ "$EUID" -eq 0 ]; then skip "permission-based failure cannot be provoked as root"; fi
}

@test "abspath: empty path" {
    _assert_same_failure 1 "abspath: empty path" ":" 'abspath ""'
}

@test "classify_path: unreadable parent" {
    _skip_if_root
    mkdir -p "$KPI_TEST_TMPDIR/locked"; chmod 000 "$KPI_TEST_TMPDIR/locked"
    _assert_same_failure 1 "cannot determine status" ":" "classify_path '$KPI_TEST_TMPDIR/locked/x'"
}

@test "remove_safe_link: refuses a real file" {
    touch "$KPI_TEST_TMPDIR/real"
    _assert_same_failure 1 "refusing to remove" ":" "remove_safe_link '$KPI_TEST_TMPDIR/real'"
}

@test "remove_safe_link: rm fails" {
    _skip_if_root
    mkdir -p "$KPI_TEST_TMPDIR/ro"; ln -s /etc "$KPI_TEST_TMPDIR/ro/link"; chmod 555 "$KPI_TEST_TMPDIR/ro"
    _assert_same_failure 2 "" ":" "remove_safe_link '$KPI_TEST_TMPDIR/ro/link'"
}

@test "link_safe: missing target" {
    _assert_same_failure 1 "link_safe: target does not exist" ":" "link_safe '$KPI_TEST_TMPDIR/nope' '$KPI_TEST_TMPDIR/link'"
}

@test "link_safe: existing symlink cannot be removed" {
    _skip_if_root
    touch "$KPI_TEST_TMPDIR/target"
    mkdir -p "$KPI_TEST_TMPDIR/ro"; ln -s /etc "$KPI_TEST_TMPDIR/ro/link"; chmod 555 "$KPI_TEST_TMPDIR/ro"
    _assert_same_failure 1 "link_safe: cannot remove existing symlink" ":" "link_safe '$KPI_TEST_TMPDIR/target' '$KPI_TEST_TMPDIR/ro/link'"
}

@test "link_safe: parent directory cannot be created" {
    _skip_if_root
    touch "$KPI_TEST_TMPDIR/target"
    mkdir -p "$KPI_TEST_TMPDIR/ro"; chmod 555 "$KPI_TEST_TMPDIR/ro"
    _assert_same_failure 1 "link_safe: cannot create directory" ":" "link_safe '$KPI_TEST_TMPDIR/target' '$KPI_TEST_TMPDIR/ro/sub/link'"
}

@test "link_safe: ln fails" {
    _skip_if_root
    touch "$KPI_TEST_TMPDIR/target"
    mkdir -p "$KPI_TEST_TMPDIR/ro"; chmod 555 "$KPI_TEST_TMPDIR/ro"
    _assert_same_failure 1 "link_safe: cannot create symlink" ":" "link_safe '$KPI_TEST_TMPDIR/target' '$KPI_TEST_TMPDIR/ro/link'"
}

@test "require_systemd_service: unit missing" {
    printf '#!/bin/bash\nexit 1\n' > "$fake_bin/systemctl"; chmod +x "$fake_bin/systemctl"
    _assert_same_failure 1 "systemd service not installed" ":" "require_systemd_service klipper"
}

@test "require_python_min: version too low" {
    _assert_same_failure 1 "need >= 99.0" ":" "require_python_min python3 99 0"
}

@test "require_python_min: interpreter unusable" {
    _assert_same_failure 1 "could not query version" ":" "require_python_min false 3 0"
}

@test "json_get: malformed input" {
    _assert_same_failure 1 "malformed" ":" "echo nope | json_get a"
}

@test "json_get: missing key" {
    _assert_same_failure 1 "" ":" "echo '{}' | json_get a"
}

@test "git_ensure_clone: non-empty non-git destination" {
    mkdir -p "$KPI_TEST_TMPDIR/dest"; touch "$KPI_TEST_TMPDIR/dest/file"
    _assert_same_failure 1 "is not a git repo" ":" "git_ensure_clone https://example.invalid/r.git '$KPI_TEST_TMPDIR/dest'"
}

@test "git_ensure_clone: origin mismatch" {
    git init -q "$KPI_TEST_TMPDIR/dest"
    git -C "$KPI_TEST_TMPDIR/dest" remote add origin https://example.invalid/other.git
    touch "$KPI_TEST_TMPDIR/dest/file"
    _assert_same_failure 1 "does not match" ":" "git_ensure_clone https://example.invalid/r.git '$KPI_TEST_TMPDIR/dest'"
}

@test "config_block_add: missing file" {
    _assert_same_failure 1 "config_block_add: file does not exist" ":" "config_block_add '$KPI_TEST_TMPDIR/none.conf' p x"
}

@test "config_block_add: malformed existing block" {
    printf '# --- p ---\nold\n' > "$KPI_TEST_TMPDIR/c.conf"
    _assert_same_failure 1 "malformed block" ":" "config_block_add '$KPI_TEST_TMPDIR/c.conf' p new"
}

@test "config_block_ensure: dangling symlink cannot be removed" {
    _skip_if_root
    mkdir -p "$KPI_TEST_TMPDIR/ro"; ln -s "$KPI_TEST_TMPDIR/nowhere" "$KPI_TEST_TMPDIR/ro/c.conf"; chmod 555 "$KPI_TEST_TMPDIR/ro"
    _assert_same_failure 1 "config_block_ensure: cannot remove dangling symlink" ":" "config_block_ensure '$KPI_TEST_TMPDIR/ro/c.conf' p x"
}

@test "config_block_remove: malformed block" {
    printf '# --- p ---\nold\n' > "$KPI_TEST_TMPDIR/c.conf"
    _assert_same_failure 1 "malformed block" ":" "config_block_remove '$KPI_TEST_TMPDIR/c.conf' p"
}

@test "service_restart_if: restart fails" {
    printf '#!/bin/bash\nexit 5\n' > "$fake_bin/sudo"; chmod +x "$fake_bin/sudo"
    _assert_same_failure 1 "restart failed" ":" "service_restart_if klipper"
}

@test "backup_dir_timestamped: source is a regular file" {
    touch "$KPI_TEST_TMPDIR/src"
    _assert_same_failure 1 "source must be a directory" ":" "backup_dir_timestamped '$KPI_TEST_TMPDIR/src' '$KPI_TEST_TMPDIR/bk'"
}

@test "backup_scrub_symlinks: backup_dir missing" {
    _assert_same_failure 1 "backup_scrub_symlinks: cannot read" ":" "backup_scrub_symlinks '$KPI_TEST_TMPDIR/none' '$KPI_TEST_TMPDIR'"
}

@test "backup_scrub_symlinks: managed link cannot be removed" {
    _skip_if_root
    mkdir -p "$KPI_TEST_TMPDIR/managed" "$KPI_TEST_TMPDIR/bk"
    ln -s "$KPI_TEST_TMPDIR/managed" "$KPI_TEST_TMPDIR/bk/link"; chmod 555 "$KPI_TEST_TMPDIR/bk"
    _assert_same_failure 1 "backup_scrub_symlinks: cannot remove" ":" "backup_scrub_symlinks '$KPI_TEST_TMPDIR/bk' '$KPI_TEST_TMPDIR/managed'"
}

@test "confirm_yn: no input and no default" {
    _assert_same_failure 1 "no interactive input available" "_KPI_INPUT_FD=" "confirm_yn proceed"
}

@test "select_from_dir: no matching files" {
    mkdir -p "$KPI_TEST_TMPDIR/opts"
    _assert_same_failure 1 "no files match" ":" "select_from_dir pick '$KPI_TEST_TMPDIR/opts' '*.cfg'"
}

@test "version_stamp: not a git repo" {
    mkdir -p "$KPI_TEST_TMPDIR/notrepo"
    _assert_same_failure 1 "cannot resolve HEAD" ":" "version_stamp '$KPI_TEST_TMPDIR/notrepo' '$KPI_TEST_TMPDIR/.VERSION'"
}

@test "is_first_install: stamp exists" {
    touch "$KPI_TEST_TMPDIR/.VERSION"
    _assert_same_failure 1 "" ":" "is_first_install '$KPI_TEST_TMPDIR/.VERSION'"
}

@test "discover_klipper_env: HOME does not resolve" {
    _assert_same_failure 1 "cannot determine" "HOME='$KPI_TEST_TMPDIR/no-home'" "discover_klipper_env"
}

@test "check_no_active_print: Moonraker unreachable" {
    printf '#!/bin/bash\nexit 7\n' > "$fake_bin/curl"; chmod +x "$fake_bin/curl"
    _assert_same_failure 1 "" ":" "check_no_active_print"
}

@test "moonraker_query: curl fails" {
    printf '#!/bin/bash\nexit 7\n' > "$fake_bin/curl"; chmod +x "$fake_bin/curl"
    _assert_same_failure 7 "" ":" "moonraker_query /printer/info"
}
