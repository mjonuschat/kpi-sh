#!/usr/bin/env bats

load 'test_helper/common'

setup() {
    common_setup
    source lib/header.sh
    source lib/log.sh
    source lib/json.sh
}

teardown() {
    common_teardown
}

# `run` executes in the current bats process (functions from setup()'s
# `source` are visible to it) — earlier drafts wrapped these in
# `bash -c '...'`, which spawns a genuinely separate process where
# json_get was never sourced and every test failed with "command not
# found." This helper avoids that by staying in-process.
_kpi_json_get_test() {
    local json="$1"
    shift
    # A here-string, not a `|` pipe: piping into json_get would run it as
    # the last stage of a pipeline, which bash executes in a subshell by
    # default (no `lastpipe`) — die()'s `exit 1` would then only terminate
    # that subshell, indistinguishable from an ordinary `return 1`. A
    # here-string keeps json_get in the current shell, so die() actually
    # propagates the way it does for every other function in this library.
    json_get "$@" <<< "$json"
}

@test "json_get returns a string value" {
    run _kpi_json_get_test '{"a":"hello"}' a
    assert_success
    assert_output "hello"
}

@test "json_get returns a number's literal text" {
    run _kpi_json_get_test '{"a":3}' a
    assert_success
    assert_output "3"
}

@test "json_get returns a boolean's literal text" {
    run _kpi_json_get_test '{"a":true}' a
    assert_success
    assert_output "true"
}

@test "json_get returns empty for null with success status" {
    run _kpi_json_get_test '{"a":null}' a
    assert_success
    assert_output ""
}

@test "json_get walks nested keys" {
    run _kpi_json_get_test '{"a":{"b":"c"}}' a b
    assert_success
    assert_output "c"
}

@test "json_get returns 1 for a missing key" {
    run _kpi_json_get_test '{"a":1}' missing
    assert_equal "$status" 1
    assert_output ""
}

@test "json_get returns 1 when the value is a container, not a leaf" {
    run _kpi_json_get_test '{"a":{"b":1}}' a
    assert_equal "$status" 1
    assert_output ""
}

@test "json_get dies on malformed JSON" {
    # die() (log.sh) is always exit 1, the same numeric code as the
    # ordinary "key not found" `return 1` — there is no distinct exit
    # code to assert here. What actually distinguishes "dies" from
    # "returns 1" is that a real (non-piped, non-subshelled) caller's
    # script terminates entirely on the former and keeps running on the
    # latter — this test asserts failure and the die() message; the
    # "does it actually kill the calling script" property is exercised
    # by the integration suite (Task 16), which calls json_get as an
    # ordinary function from a set -eu installer script.
    run _kpi_json_get_test 'not json' a
    assert_failure
    assert_output --partial "malformed"
}

@test "_KPI_PYTHON is unset until the first json_get call" {
    assert [ -z "${_KPI_PYTHON:-}" ]
    _kpi_json_get_test '{"a":1}' a >/dev/null
    assert [ -n "$_KPI_PYTHON" ]
}
