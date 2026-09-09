#!/usr/bin/env bats

load 'test_helper/common'

setup() {
    common_setup
    source lib/header.sh
    source lib/log.sh
    source lib/service.sh
    fake_bin="$KPI_TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"
}

teardown() {
    common_teardown
}

_install_fake_systemctl() {
    # $1: exit code for `systemctl restart`
    cat > "$fake_bin/sudo" <<'EOF'
#!/bin/bash
exec "$@"
EOF
    chmod +x "$fake_bin/sudo"
    cat > "$fake_bin/systemctl" <<EOF
#!/bin/bash
[ "\$1" = "restart" ] && exit $1
exit 0
EOF
    chmod +x "$fake_bin/systemctl"
}

@test "restarts unconditionally when no predicate is given" {
    _install_fake_systemctl 0
    PATH="$fake_bin:$PATH" run service_restart_if klipper
    assert_success
}

@test "restarts when predicate succeeds" {
    _install_fake_systemctl 0
    predicate() { return 0; }
    PATH="$fake_bin:$PATH" run service_restart_if klipper predicate
    assert_success
}

@test "skips restart when predicate declines" {
    _install_fake_systemctl 0
    cat > "$fake_bin/systemctl" <<'EOF'
#!/bin/bash
echo "RESTART_CALLED" >&2
exit 0
EOF
    chmod +x "$fake_bin/systemctl"
    predicate() { return 1; }
    PATH="$fake_bin:$PATH" run service_restart_if klipper predicate
    assert_success
    refute_output --partial "RESTART_CALLED"
}

@test "skips restart when predicate errors (exit 127)" {
    _install_fake_systemctl 0
    cat > "$fake_bin/systemctl" <<'EOF'
#!/bin/bash
echo "RESTART_CALLED" >&2
exit 0
EOF
    chmod +x "$fake_bin/systemctl"
    PATH="$fake_bin:$PATH" run service_restart_if klipper nonexistent_predicate_command
    assert_success
    refute_output --partial "RESTART_CALLED"
}

@test "dies when systemctl restart fails" {
    _install_fake_systemctl 1
    PATH="$fake_bin:$PATH" run service_restart_if klipper
    assert_failure
    assert_output --partial "restart failed"
}

@test "dies with a timeout-specific message when the restart hangs" {
    # service_restart_if's own timeout is a fixed 30s (see spec — not
    # consumer-configurable). This test genuinely waits past it rather
    # than wrapping the whole call in a shorter outer `timeout` — an
    # outer `timeout 5` would kill the test before the *internal* 30s
    # timeout ever fires, so it would only prove the outer wrapper works,
    # not that service_restart_if's own timeout/die logic does. This test
    # takes >30s to run; that's the tradeoff for actually exercising the
    # real timeout rather than a proxy for it.
    cat > "$fake_bin/sudo" <<'EOF'
#!/bin/bash
exec "$@"
EOF
    chmod +x "$fake_bin/sudo"
    cat > "$fake_bin/systemctl" <<'EOF'
#!/bin/bash
sleep 60
EOF
    chmod +x "$fake_bin/systemctl"
    PATH="$fake_bin:$PATH" run timeout 35 bash -c "
        source lib/header.sh; source lib/log.sh; source lib/service.sh
        service_restart_if klipper
    "
    assert_failure
    assert_output --partial "timed out after 30s"
}
