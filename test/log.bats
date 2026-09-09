#!/usr/bin/env bats

load 'test_helper/common'

setup() {
    common_setup
    source lib/header.sh
    source lib/log.sh
}

teardown() {
    common_teardown
}

@test "log writes to stderr, not stdout" {
    run --separate-stderr log "hello"
    assert_equal "$output" ""
    assert_equal "$stderr" "hello"
}

@test "err writes to stderr with an error prefix" {
    run --separate-stderr err "boom"
    assert_equal "$stderr" "error: boom"
}

@test "die writes to stderr and exits 1" {
    run die "fatal"
    assert_failure 1
    assert_output --partial "fatal"
}
