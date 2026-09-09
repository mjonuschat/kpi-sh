#!/usr/bin/env bats

load 'test_helper/common'

setup() {
    common_setup
    source lib/header.sh
    source lib/log.sh
    source lib/version.sh

    repo="$KPI_TEST_TMPDIR/repo"
    git init -q "$repo"
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    touch "$repo/f"
    git -C "$repo" add f
    git -C "$repo" commit -q -m "init"
}

teardown() {
    common_teardown
}

@test "is_first_install returns 0 when dest_file does not exist" {
    run is_first_install "$KPI_TEST_TMPDIR/.VERSION"
    assert_success
}

@test "is_first_install returns 1 when dest_file exists" {
    touch "$KPI_TEST_TMPDIR/.VERSION"
    run is_first_install "$KPI_TEST_TMPDIR/.VERSION"
    assert_equal "$status" 1
}

@test "version_stamp writes the repo HEAD sha to dest_file" {
    dest="$KPI_TEST_TMPDIR/.VERSION"
    version_stamp "$repo" "$dest"
    assert_equal "$(cat "$dest")" "$(git -C "$repo" rev-parse HEAD)"
}

@test "version_stamp preserves a symlinked dest_file's target" {
    real="$KPI_TEST_TMPDIR/real.VERSION"
    touch "$real"
    dest="$KPI_TEST_TMPDIR/.VERSION"
    ln -s "$real" "$dest"
    version_stamp "$repo" "$dest"
    assert [ -L "$dest" ]
    assert_equal "$(cat "$real")" "$(git -C "$repo" rev-parse HEAD)"
}

@test "version_stamp preserves existing permissions" {
    dest="$KPI_TEST_TMPDIR/.VERSION"
    touch "$dest"
    chmod 640 "$dest"
    version_stamp "$repo" "$dest"
    assert_equal "$(stat -c %a "$dest" 2>/dev/null || stat -f %Lp "$dest")" "640"
}

@test "a failed write leaves a pre-existing dest_file untouched" {
    dest="$KPI_TEST_TMPDIR/.VERSION"
    echo "original-sha" > "$dest"
    fake_bin="$KPI_TEST_TMPDIR/bin"; mkdir -p "$fake_bin"
    cat > "$fake_bin/mktemp" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$fake_bin/mktemp"
    # A fresh process, not `run version_stamp` (a same-shell subshell):
    # the latter inherits bats' own `bats_teardown_trap` EXIT trap, which
    # our die path then genuinely re-invokes (per the trap-execution fix
    # in config_block.sh) — correct for a real caller, but it runs bats'
    # internal completion protocol out of turn and corrupts its test count.
    script="$KPI_TEST_TMPDIR/run-mktemp-fail.sh"
    cat > "$script" <<EOF
#!/bin/bash
source "$PWD/lib/header.sh"
source "$PWD/lib/log.sh"
source "$PWD/lib/version.sh"
PATH="$fake_bin:\$PATH" version_stamp "$repo" "$dest"
EOF
    chmod +x "$script"
    run bash "$script"
    assert_failure
    assert_equal "$(cat "$dest")" "original-sha"
}

@test "a failed rename leaves a pre-existing dest_file untouched" {
    dest="$KPI_TEST_TMPDIR/.VERSION"
    echo "original-sha" > "$dest"
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
source "$PWD/lib/version.sh"
PATH="$fake_bin:\$PATH" version_stamp "$repo" "$dest"
EOF
    chmod +x "$script"
    run bash "$script"
    assert_failure
    assert_equal "$(cat "$dest")" "original-sha"
}

@test "a failed write to the temp file leaves a pre-existing dest_file untouched" {
    if [ "$EUID" -eq 0 ]; then
        skip "root bypasses permission bits"
    fi
    dest="$KPI_TEST_TMPDIR/.VERSION"
    echo "original-sha" > "$dest"
    fake_bin="$KPI_TEST_TMPDIR/bin"; mkdir -p "$fake_bin"
    # Wraps the real mktemp (via `command -p`, which uses a default PATH
    # and so can't recurse into this very stub) and immediately revokes
    # write permission on the file it created, so the subsequent
    # `echo ... > "$tmp"` fails with a real permission error.
    cat > "$fake_bin/mktemp" <<'EOF'
#!/bin/bash
real="$(command -p mktemp "$@")"
chmod 000 "$real"
echo "$real"
EOF
    chmod +x "$fake_bin/mktemp"
    # Fresh process — same reason as the mktemp-failure test above.
    script="$KPI_TEST_TMPDIR/run-mktemp-permission-fail.sh"
    cat > "$script" <<EOF
#!/bin/bash
source "$PWD/lib/header.sh"
source "$PWD/lib/log.sh"
source "$PWD/lib/version.sh"
PATH="$fake_bin:\$PATH" version_stamp "$repo" "$dest"
EOF
    chmod +x "$script"
    run bash "$script"
    assert_failure
    assert_equal "$(cat "$dest")" "original-sha"
}
