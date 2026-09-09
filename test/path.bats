#!/usr/bin/env bats

load 'test_helper/common'

setup() {
    common_setup
    source lib/header.sh
    source lib/log.sh
    source lib/path.sh
}

teardown() {
    common_teardown
}

@test "abspath dies on empty input" {
    run abspath ""
    assert_failure
}

@test "abspath normalizes repeated slashes and dot components" {
    run abspath "/foo//bar/./baz"
    assert_success
    assert_output "/foo/bar/baz"
}

@test "abspath resolves .. lexically without touching the filesystem" {
    run abspath "/foo/bar/../baz"
    assert_success
    assert_output "/foo/baz"
}

@test "abspath clamps .. at root instead of erroring" {
    run abspath "/../foo"
    assert_success
    assert_output "/foo"
}

@test "abspath works on a path that does not exist" {
    run abspath "/definitely/not/a/real/path/xyz"
    assert_success
    assert_output "/definitely/not/a/real/path/xyz"
}

@test "abspath prepends PWD for a relative path" {
    cd "$KPI_TEST_TMPDIR"
    run abspath "sub/dir"
    assert_success
    assert_output "$KPI_TEST_TMPDIR/sub/dir"
}

@test "abspath does not follow a symlink in the path" {
    mkdir -p "$KPI_TEST_TMPDIR/real"
    ln -s "$KPI_TEST_TMPDIR/real" "$KPI_TEST_TMPDIR/link"
    run abspath "$KPI_TEST_TMPDIR/link/child"
    assert_success
    assert_output "$KPI_TEST_TMPDIR/link/child"
}

@test "script_dir reports the entrypoint directory from a sourced file" {
    mkdir -p "$KPI_TEST_TMPDIR/entry"
    cat > "$KPI_TEST_TMPDIR/entry/main.sh" <<EOF
#!/bin/bash
source "$PWD/lib/header.sh"
source "$PWD/lib/log.sh"
source "$PWD/lib/path.sh"
script_dir
EOF
    chmod +x "$KPI_TEST_TMPDIR/entry/main.sh"
    run bash "$KPI_TEST_TMPDIR/entry/main.sh"
    assert_success
    assert_output "$KPI_TEST_TMPDIR/entry"
}

@test "script_dir reports the entrypoint directory from a nested function call" {
    mkdir -p "$KPI_TEST_TMPDIR/entry"
    cat > "$KPI_TEST_TMPDIR/entry/helper.sh" <<EOF
inner() { script_dir; }
outer() { inner; }
EOF
    cat > "$KPI_TEST_TMPDIR/entry/main.sh" <<EOF
#!/bin/bash
source "$PWD/lib/header.sh"
source "$PWD/lib/log.sh"
source "$PWD/lib/path.sh"
source "$KPI_TEST_TMPDIR/entry/helper.sh"
outer
EOF
    chmod +x "$KPI_TEST_TMPDIR/entry/main.sh"
    run bash "$KPI_TEST_TMPDIR/entry/main.sh"
    assert_success
    assert_output "$KPI_TEST_TMPDIR/entry"
}

@test "script_dir dies when no real file backs the call chain" {
    # Sourcing lib/path.sh from a real file (even via `bash -c "source ...;
    # script_dir"`) always gives BASH_SOURCE at least one real entry — the
    # path to lib/path.sh itself — so that invocation can never trigger
    # this die path; verified empirically, not by assumption. `eval`-ing
    # the module's contents instead of sourcing it from disk is what
    # actually produces bash's no-file placeholder ("bash") as the
    # outermost frame, which is the real condition being tested here.
    run bash -c "
        eval \"\$(cat '$PWD/lib/header.sh')\"
        eval \"\$(cat '$PWD/lib/log.sh')\"
        eval \"\$(cat '$PWD/lib/path.sh')\"
        script_dir
    "
    assert_failure
}
