#!/usr/bin/env bats

load 'test_helper/common'

setup() {
    common_setup
    source lib/header.sh
    source lib/log.sh
    source lib/prompt.sh
}

teardown() {
    common_teardown
}

@test "confirm_yn dies on an invalid default (caller bug)" {
    run confirm_yn "proceed?" "maybe"
    assert_failure
}

@test "confirm_yn returns default without blocking when no tty (no default given dies)" {
    _KPI_INPUT_FD=""
    run confirm_yn "proceed?"
    assert_failure
}

@test "confirm_yn returns default without blocking when no tty (default given)" {
    _KPI_INPUT_FD=""
    run confirm_yn "proceed?" "y"
    assert_success
}

@test "confirm_yn accepts default on blank input" {
    # A fixed fd number (8), not bash's {fd} dynamic-allocation syntax —
    # that syntax requires Bash 4.1+ and would fail under this project's
    # own Bash 4.0 floor (same class of bug the fd-9 header.sh check
    # exists to avoid inside the library itself).
    exec 8<<< ""
    _KPI_INPUT_FD=8
    run confirm_yn "proceed?" "y"
    assert_success
    exec 8<&-
}

@test "confirm_yn accepts y" {
    exec 8<<< "y"
    _KPI_INPUT_FD=8
    run confirm_yn "proceed?" "n"
    assert_success
    exec 8<&-
}

@test "confirm_yn accepts n and returns 1" {
    exec 8<<< "n"
    _KPI_INPUT_FD=8
    run confirm_yn "proceed?" "y"
    assert_equal "$status" 1
    exec 8<&-
}

@test "confirm_yn re-prompts on invalid input then falls back to default" {
    exec 8<<< $'garbage1\ngarbage2\ngarbage3'
    _KPI_INPUT_FD=8
    run confirm_yn "proceed?" "y"
    assert_success
    exec 8<&-
}

@test "confirm_yn falls back to default on EOF" {
    # /dev/null reads as immediate EOF — no line at all, not even a blank
    # one — which is the genuine "no more input" case this exercises.
    exec 8< /dev/null
    _KPI_INPUT_FD=8
    run confirm_yn "proceed?" "y"
    assert_success
    exec 8<&-
}

@test "select_from_dir lists matching files and returns the selection" {
    dir="$KPI_TEST_TMPDIR/opts"; mkdir -p "$dir"
    touch "$dir/one.cfg" "$dir/two.cfg"
    exec 8<<< "1"
    _KPI_INPUT_FD=8
    run select_from_dir "pick one" "$dir" "*.cfg"
    assert_success
    exec 8<&-
}

@test "select_from_dir returns 1 when user selects 0 (skip)" {
    dir="$KPI_TEST_TMPDIR/opts"; mkdir -p "$dir"
    touch "$dir/one.cfg"
    exec 8<<< "0"
    _KPI_INPUT_FD=8
    run select_from_dir "pick one" "$dir" "*.cfg"
    assert_equal "$status" 1
    exec 8<&-
}

@test "select_from_dir returns 1 when no files match" {
    dir="$KPI_TEST_TMPDIR/empty"; mkdir -p "$dir"
    _KPI_INPUT_FD=""
    run select_from_dir "pick one" "$dir" "*.cfg"
    assert_equal "$status" 1
}

@test "select_from_dir re-prompts on invalid selection then skips" {
    dir="$KPI_TEST_TMPDIR/opts"; mkdir -p "$dir"
    touch "$dir/one.cfg"
    exec 8<<< $'99\n99\n99'
    _KPI_INPUT_FD=8
    run select_from_dir "pick one" "$dir" "*.cfg"
    assert_equal "$status" 1
    exec 8<&-
}
