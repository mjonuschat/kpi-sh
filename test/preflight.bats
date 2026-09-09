#!/usr/bin/env bats

load 'test_helper/common'

setup() {
    common_setup
    source lib/header.sh
    source lib/log.sh
    source lib/preflight.sh
}

teardown() {
    common_teardown
}

@test "require_not_root passes as a non-root user" {
    if [ "$EUID" -eq 0 ]; then
        skip "this leg is the root-container CI job; see require_not_root dies test"
    fi
    run require_not_root
    assert_success
}

@test "require_not_root dies as root" {
    if [ "$EUID" -ne 0 ]; then
        skip "only runs in the root-container CI job"
    fi
    run require_not_root
    assert_failure
}

@test "require_systemd_service passes when the unit is installed" {
    fake_bin="$KPI_TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/systemctl" <<'EOF'
#!/bin/bash
[ "$1" = "cat" ] && [ "$2" = "klipper" ] && exit 0
exit 1
EOF
    chmod +x "$fake_bin/systemctl"
    PATH="$fake_bin:$PATH" run require_systemd_service klipper
    assert_success
}

@test "require_systemd_service dies when the unit is not installed" {
    fake_bin="$KPI_TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/systemctl" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$fake_bin/systemctl"
    PATH="$fake_bin:$PATH" run require_systemd_service nonexistent
    assert_failure
}

@test "require_python_min passes when the interpreter meets the minimum" {
    run require_python_min "$(command -v python3)" 3 0
    assert_success
}

@test "require_python_min dies when the interpreter is below the minimum" {
    run require_python_min "$(command -v python3)" 99 0
    assert_failure
}
