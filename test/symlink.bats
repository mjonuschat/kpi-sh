#!/usr/bin/env bats

load 'test_helper/common'

setup() {
    common_setup
    source lib/header.sh
    source lib/log.sh
    source lib/symlink.sh
}

teardown() {
    common_teardown
}

@test "classify_path reports absent for a nonexistent path" {
    run classify_path "$KPI_TEST_TMPDIR/nope"
    assert_success
    assert_output "absent"
}

@test "classify_path reports real for a regular file" {
    touch "$KPI_TEST_TMPDIR/f"
    run classify_path "$KPI_TEST_TMPDIR/f"
    assert_success
    assert_output "real"
}

@test "classify_path reports symlink for a symlink, dangling or not" {
    ln -s "/does/not/exist" "$KPI_TEST_TMPDIR/dangling"
    run classify_path "$KPI_TEST_TMPDIR/dangling"
    assert_success
    assert_output "symlink"
}

@test "classify_path reports absent when the parent is missing" {
    run classify_path "$KPI_TEST_TMPDIR/no/such/parent/leaf"
    assert_success
    assert_output "absent"
}

@test "classify_path dies when the immediate parent is unreadable" {
    if [ "$EUID" -eq 0 ]; then
        skip "root bypasses permission bits — this test is meaningless in the root CI job (same reasoning as require_not_root's skip)"
    fi
    mkdir -p "$KPI_TEST_TMPDIR/locked"
    chmod 000 "$KPI_TEST_TMPDIR/locked"
    run classify_path "$KPI_TEST_TMPDIR/locked/leaf"
    assert_failure
    chmod 755 "$KPI_TEST_TMPDIR/locked"
}

@test "remove_safe_link is idempotent on an absent path" {
    run remove_safe_link "$KPI_TEST_TMPDIR/nope"
    assert_success
}

@test "remove_safe_link removes a symlink" {
    ln -s "/tmp" "$KPI_TEST_TMPDIR/link"
    run remove_safe_link "$KPI_TEST_TMPDIR/link"
    assert_success
    assert_file_not_exist "$KPI_TEST_TMPDIR/link"
}

@test "remove_safe_link refuses to remove a real file" {
    touch "$KPI_TEST_TMPDIR/real"
    run remove_safe_link "$KPI_TEST_TMPDIR/real"
    assert_equal "$status" 1
    assert_file_exist "$KPI_TEST_TMPDIR/real"
}

@test "link_safe creates a symlink when absent" {
    touch "$KPI_TEST_TMPDIR/target"
    link_safe "$KPI_TEST_TMPDIR/target" "$KPI_TEST_TMPDIR/link"
    assert_equal "$(readlink "$KPI_TEST_TMPDIR/link")" "$KPI_TEST_TMPDIR/target"
}

@test "link_safe replaces an existing symlink" {
    touch "$KPI_TEST_TMPDIR/target1" "$KPI_TEST_TMPDIR/target2"
    ln -s "$KPI_TEST_TMPDIR/target1" "$KPI_TEST_TMPDIR/link"
    link_safe "$KPI_TEST_TMPDIR/target2" "$KPI_TEST_TMPDIR/link"
    assert_equal "$(readlink "$KPI_TEST_TMPDIR/link")" "$KPI_TEST_TMPDIR/target2"
}

@test "link_safe dies rather than overwriting a real file" {
    touch "$KPI_TEST_TMPDIR/target" "$KPI_TEST_TMPDIR/link"
    run link_safe "$KPI_TEST_TMPDIR/target" "$KPI_TEST_TMPDIR/link"
    assert_failure
}

@test "link_safe dies when target is missing" {
    run link_safe "$KPI_TEST_TMPDIR/no-target" "$KPI_TEST_TMPDIR/link"
    assert_failure
}

@test "link_safe --allow-dangling suppresses the target-exists check" {
    link_safe --allow-dangling "$KPI_TEST_TMPDIR/future-target" "$KPI_TEST_TMPDIR/link"
    assert_equal "$(readlink "$KPI_TEST_TMPDIR/link")" "$KPI_TEST_TMPDIR/future-target"
}

@test "link_safe creates the parent directory of link_name" {
    touch "$KPI_TEST_TMPDIR/target"
    link_safe "$KPI_TEST_TMPDIR/target" "$KPI_TEST_TMPDIR/new/parent/link"
    assert_equal "$(readlink "$KPI_TEST_TMPDIR/new/parent/link")" "$KPI_TEST_TMPDIR/target"
}
