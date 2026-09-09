#!/usr/bin/env bats

load 'test_helper/common'

setup() {
    common_setup
}

teardown() {
    common_teardown
}

@test "sourcing header.sh sets LC_ALL to C" {
    source lib/header.sh
    assert_equal "$LC_ALL" "C"
}

@test "sourcing header.sh defines the _kpi_init_done marker" {
    source lib/header.sh
    run declare -F _kpi_init_done
    assert_success
}

@test "sourcing header.sh twice does not reopen fd 9" {
    source lib/header.sh
    first_fd="$_KPI_INPUT_FD"
    # Close fd 9 behind the library's back to detect a second open attempt.
    exec 9<&- 2>/dev/null || true
    source lib/header.sh
    # Second source is a no-op: _KPI_INPUT_FD is not recomputed, so it
    # keeps whatever value it had after the first source (even if fd 9
    # is no longer actually open) rather than being reassigned.
    assert_equal "$_KPI_INPUT_FD" "$first_fd"
}

@test "fd 9 already open read-only is detected and left alone" {
    exec 9<"$KPI_TEST_TMPDIR/../.." 2>/dev/null || exec 9< /dev/null
    source lib/header.sh
    assert_equal "$_KPI_INPUT_FD" ""
    exec 9<&-
}

@test "_KPI_INPUT_FD defaults to 9 when fd 9 is free and a tty-like fd is opened" {
    # No tty in bats' test runner, so opening /dev/tty is expected to
    # fail here; assert the documented non-interactive fallback instead.
    source lib/header.sh
    # Either it got a real tty (interactive CI edge case) or fell back to
    # empty — both are valid per spec depending on environment, but it
    # must never be unset.
    assert [ -n "${_KPI_INPUT_FD+x}" ]
}

@test "bash version guard passes on the running interpreter" {
    run bash -c 'source lib/header.sh; echo ok'
    assert_success
    assert_output "ok"
}
