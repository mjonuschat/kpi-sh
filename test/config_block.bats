#!/usr/bin/env bats

load 'test_helper/common'

setup() {
    common_setup
    source lib/header.sh
    source lib/log.sh
    source lib/config_block.sh
    cfg="$KPI_TEST_TMPDIR/moonraker.conf"
}

teardown() {
    common_teardown
}

@test "config_block_add dies on a missing file" {
    run config_block_add "$cfg" myplugin "line"
    assert_failure
}

@test "config_block_add appends a sentinel-wrapped block" {
    touch "$cfg"
    config_block_add "$cfg" myplugin "some content"
    run grep -F -- "# --- myplugin ---" "$cfg"
    assert_success
    run grep -F -- "# --- /myplugin ---" "$cfg"
    assert_success
    run grep -F -- "some content" "$cfg"
    assert_success
}

@test "config_block_add is a no-op when the block already exists" {
    touch "$cfg"
    config_block_add "$cfg" myplugin "v1"
    before="$(cat "$cfg")"
    config_block_add "$cfg" myplugin "v2"
    assert_equal "$(cat "$cfg")" "$before"
}

@test "config_block_add dies when name has invalid characters" {
    touch "$cfg"
    run config_block_add "$cfg" 'bad name!' "content"
    assert_failure
}

@test "config_block_add dies when content contains a sentinel-shaped line" {
    touch "$cfg"
    run config_block_add "$cfg" myplugin $'line1\n# --- fake ---\nline2'
    assert_failure
}

@test "config_block_ensure creates a missing file" {
    config_block_ensure "$cfg" myplugin "content"
    assert_file_exist "$cfg"
    run grep -F -- "content" "$cfg"
    assert_success
}

@test "config_block_ensure preserves existing content" {
    echo "existing line" > "$cfg"
    config_block_ensure "$cfg" myplugin "new content"
    run grep -F -- "existing line" "$cfg"
    assert_success
    run grep -F -- "new content" "$cfg"
    assert_success
}

@test "config_block_remove is a no-op on a missing file" {
    run config_block_remove "$cfg" myplugin
    assert_success
}

@test "config_block_remove removes the named block, leaves others intact" {
    touch "$cfg"
    config_block_add "$cfg" plugin_a "block a"
    config_block_add "$cfg" plugin_b "block b"
    config_block_remove "$cfg" plugin_a
    run grep -F -- "block a" "$cfg"
    assert_failure
    run grep -F -- "block b" "$cfg"
    assert_success
}

@test "config_block_remove dies on an unterminated block" {
    printf '# --- myplugin ---\ncontent with no end sentinel\n' > "$cfg"
    run config_block_remove "$cfg" myplugin
    assert_failure
}

@test "config_block_remove dies on a foreign sentinel nested inside" {
    printf '# --- myplugin ---\n# --- other ---\ncontent\n# --- /other ---\n# --- /myplugin ---\n' > "$cfg"
    run config_block_remove "$cfg" myplugin
    assert_failure
}

@test "permissions survive an add/remove round-trip" {
    touch "$cfg"
    chmod 640 "$cfg"
    config_block_add "$cfg" myplugin "content"
    assert_equal "$(stat -c %a "$cfg" 2>/dev/null || stat -f %Lp "$cfg")" "640"
    config_block_remove "$cfg" myplugin
    assert_equal "$(stat -c %a "$cfg" 2>/dev/null || stat -f %Lp "$cfg")" "640"
}

@test "a dangling file symlink is treated as absent by add (dies)" {
    ln -s "$KPI_TEST_TMPDIR/nowhere" "$cfg"
    run config_block_add "$cfg" myplugin "content"
    assert_failure
}

@test "config_block_ensure replaces a dangling symlink with a real file" {
    ln -s "$KPI_TEST_TMPDIR/nowhere" "$cfg"
    config_block_ensure "$cfg" myplugin "content"
    assert [ -f "$cfg" ]
    assert [ ! -L "$cfg" ]
}

@test "a symlinked config file has its real target updated, symlink survives" {
    real="$KPI_TEST_TMPDIR/real.conf"
    touch "$real"
    ln -s "$real" "$cfg"
    config_block_add "$cfg" myplugin "content"
    assert [ -L "$cfg" ]
    run grep -F -- "content" "$real"
    assert_success
}

@test "a pre-existing EXIT trap still fires and is left in place" {
    touch "$cfg"
    script="$KPI_TEST_TMPDIR/run.sh"
    cat > "$script" <<EOF
#!/bin/bash
source "$PWD/lib/header.sh"
source "$PWD/lib/log.sh"
source "$PWD/lib/config_block.sh"
touch "$KPI_TEST_TMPDIR/trap_marker_setup"
trap 'touch "$KPI_TEST_TMPDIR/trap_fired"' EXIT
config_block_add "$cfg" myplugin "content"
trap -p EXIT > "$KPI_TEST_TMPDIR/trap_after"
EOF
    chmod +x "$script"
    run bash "$script"
    assert_success
    assert_file_exist "$KPI_TEST_TMPDIR/trap_fired"
    run grep -F "trap_fired" "$KPI_TEST_TMPDIR/trap_after"
    assert_success
}

@test "die before mktemp does not crash on an unset tmp variable" {
    touch "$cfg"
    run config_block_add "$cfg" 'invalid name' "content"
    assert_failure
    assert_output --partial "config_block_add"
}

@test "config_block_remove dies on a duplicate start sentinel with the same name" {
    # The duplicate start must appear BEFORE the first end sentinel — two
    # complete, separately-closed blocks (start/end, start/end) is valid
    # input, not the malformed case. This is the actual malformed shape:
    # a second start reached while still scanning for the first block's
    # own end.
    printf '# --- myplugin ---\nfirst\n# --- myplugin ---\nsecond\n# --- /myplugin ---\n' > "$cfg"
    run config_block_remove "$cfg" myplugin
    assert_failure
}

@test "a failing mktemp leaves the original file untouched and no stray temp file" {
    touch "$cfg"
    config_block_add "$cfg" existing "original content"
    before="$(cat "$cfg")"
    fake_bin="$KPI_TEST_TMPDIR/bin"; mkdir -p "$fake_bin"
    cat > "$fake_bin/mktemp" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$fake_bin/mktemp"
    # A fresh process, not `run config_block_add` (a same-shell subshell):
    # the latter inherits bats' own `bats_teardown_trap` EXIT trap, which
    # our die path then genuinely re-invokes (per the trap-execution fix
    # above) — correct for a real caller, but it runs bats' internal
    # completion protocol out of turn and corrupts its test count.
    script="$KPI_TEST_TMPDIR/run-mktemp-fail.sh"
    cat > "$script" <<EOF
#!/bin/bash
source "$PWD/lib/header.sh"
source "$PWD/lib/log.sh"
source "$PWD/lib/config_block.sh"
PATH="$fake_bin:\$PATH" config_block_add "$cfg" newblock "new content"
EOF
    chmod +x "$script"
    run bash "$script"
    assert_failure
    assert_equal "$(cat "$cfg")" "$before"
    run bash -c "ls -A '$(dirname "$cfg")' | grep -c '\.kpi\.'"
    assert_output "0"
}

@test "a failing mv leaves the original file untouched" {
    touch "$cfg"
    config_block_add "$cfg" existing "original content"
    before="$(cat "$cfg")"
    fake_bin="$KPI_TEST_TMPDIR/bin"; mkdir -p "$fake_bin"
    cat > "$fake_bin/mv" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$fake_bin/mv"
    # Fresh process — same reason as the mktemp-failure test above.
    script="$KPI_TEST_TMPDIR/run-mv-fail.sh"
    cat > "$script" <<EOF
#!/bin/bash
source "$PWD/lib/header.sh"
source "$PWD/lib/log.sh"
source "$PWD/lib/config_block.sh"
PATH="$fake_bin:\$PATH" config_block_add "$cfg" newblock "new content"
EOF
    chmod +x "$script"
    run bash "$script"
    assert_failure
    assert_equal "$(cat "$cfg")" "$before"
}

@test "a pre-existing EXIT trap that itself errors on re-invocation does not crash config_block_add" {
    touch "$cfg"
    script="$KPI_TEST_TMPDIR/run.sh"
    cat > "$script" <<EOF
#!/bin/bash
source "$PWD/lib/header.sh"
source "$PWD/lib/log.sh"
source "$PWD/lib/config_block.sh"
trap 'exit 1' EXIT
config_block_add "$cfg" myplugin "content"
echo "REACHED_AFTER_ADD"
EOF
    chmod +x "$script"
    run bash "$script"
    assert_output --partial "REACHED_AFTER_ADD"
}

@test "a pre-existing EXIT trap actually runs (not just re-registers) when a write fails" {
    touch "$cfg"
    fake_bin="$KPI_TEST_TMPDIR/bin"; mkdir -p "$fake_bin"
    cat > "$fake_bin/mktemp" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$fake_bin/mktemp"
    script="$KPI_TEST_TMPDIR/run-trap-fires-on-die.sh"
    cat > "$script" <<EOF
#!/bin/bash
source "$PWD/lib/header.sh"
source "$PWD/lib/log.sh"
source "$PWD/lib/config_block.sh"
trap 'echo "CONSUMER_CLEANUP_RAN"' EXIT
PATH="$fake_bin:\$PATH" config_block_add "$cfg" myplugin "content"
EOF
    chmod +x "$script"
    run bash "$script"
    assert_failure
    assert_output --partial "CONSUMER_CLEANUP_RAN"
}

@test "config_block_remove dies on an invalid name, same as add/ensure" {
    touch "$cfg"
    run config_block_remove "$cfg" 'bad name!'
    assert_failure
}

@test "config_block_add dies on an unreadable existing file rather than discarding its content" {
    if [ "$EUID" -eq 0 ]; then
        skip "root bypasses permission bits"
    fi
    printf 'irreplaceable content\n' > "$cfg"
    chmod 000 "$cfg"
    run config_block_add "$cfg" myplugin "new content"
    assert_failure
    chmod 644 "$cfg"
    assert_equal "$(cat "$cfg")" "irreplaceable content"
}

@test "config_block_ensure dies on an unreadable existing file rather than discarding its content" {
    if [ "$EUID" -eq 0 ]; then
        skip "root bypasses permission bits"
    fi
    printf 'irreplaceable content\n' > "$cfg"
    chmod 000 "$cfg"
    run config_block_ensure "$cfg" myplugin "new content"
    assert_failure
    chmod 644 "$cfg"
    assert_equal "$(cat "$cfg")" "irreplaceable content"
}

@test "config_block_remove dies on an unreadable file rather than mangling it" {
    if [ "$EUID" -eq 0 ]; then
        skip "root bypasses permission bits"
    fi
    printf '# --- myplugin ---\ncontent\n# --- /myplugin ---\n' > "$cfg"
    original="$(cat "$cfg")"
    chmod 000 "$cfg"
    run config_block_remove "$cfg" myplugin
    assert_failure
    chmod 644 "$cfg"
    # Failing is necessary but not sufficient — a regression could still
    # partially rewrite the file before dying and this would go unnoticed
    # without an explicit content check.
    assert_equal "$(cat "$cfg")" "$original"
}
