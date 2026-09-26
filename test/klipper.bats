#!/usr/bin/env bats

load 'test_helper/common'

setup() {
    common_setup
    source lib/header.sh
    source lib/log.sh
    source lib/json.sh
    source lib/klipper.sh
    unset MOONRAKER_HOST KLIPPER_PATH KLIPPY_PYTHON KLIPPER_PLUGINS_PATH MOONRAKER_CONFIG
    fake_bin="$KPI_TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"
}

teardown() {
    common_teardown
}

_install_fake_curl() {
    # $1: response body to print, $2: exit code (default 0)
    local body="$1" rc="${2:-0}"
    cat > "$fake_bin/curl" <<EOF
#!/bin/bash
cat <<'BODY'
$body
BODY
exit $rc
EOF
    chmod +x "$fake_bin/curl"
}

@test "falls back to hardcoded defaults when Moonraker is unreachable" {
    _install_fake_curl "" 7
    PATH="$fake_bin:$PATH" discover_klipper_env
    assert_equal "$MOONRAKER_HOST" "http://localhost:7125"
    assert_equal "$KLIPPER_PATH" "${HOME}/klipper"
    assert_equal "$KLIPPY_PYTHON" "${HOME}/klippy-env/bin/python"
    assert_equal "$KLIPPER_PLUGINS_PATH" "${HOME}/klipper/klippy/extras"
}

@test "a non-default MOONRAKER_HOST logs an override warning" {
    _install_fake_curl "" 7
    MOONRAKER_HOST="http://192.168.1.5:7125"
    PATH="$fake_bin:$PATH" run discover_klipper_env
    assert_output --partial "overridden to a non-default host"
}

@test "a valid Klipper checkout under HOME is accepted" {
    mkdir -p "$HOME/klipper/klippy"
    touch "$HOME/klipper/klippy/klippy.py"
    _install_fake_curl "{\"result\":{\"klipper_path\":\"$HOME/klipper\"}}"
    PATH="$fake_bin:$PATH" discover_klipper_env
    assert_equal "$KLIPPER_PATH" "$HOME/klipper"
}

@test "a discovered klipper_path missing klippy.py falls back to default" {
    mkdir -p "$HOME/klipper"
    _install_fake_curl "{\"result\":{\"klipper_path\":\"$HOME/klipper\"}}"
    PATH="$fake_bin:$PATH" discover_klipper_env
    assert_equal "$KLIPPER_PATH" "${HOME}/klipper"
}

@test "a discovered klipper_path outside HOME is rejected" {
    outside="$KPI_TEST_TMPDIR/outside-home/klipper"
    mkdir -p "$outside/klippy"
    touch "$outside/klippy/klippy.py"
    _install_fake_curl "{\"result\":{\"klipper_path\":\"$outside\"}}"
    PATH="$fake_bin:$PATH" discover_klipper_env
    assert_equal "$KLIPPER_PATH" "${HOME}/klipper"
}

@test "a discovered python_path that is not python fails the probe and falls back" {
    _install_fake_curl "{\"result\":{\"python_path\":\"/bin/sh\"}}"
    PATH="$fake_bin:$PATH" discover_klipper_env
    assert_equal "$KLIPPY_PYTHON" "${HOME}/klippy-env/bin/python"
}

@test "an explicit env override to a path outside HOME is preserved as-is" {
    outside="$KPI_TEST_TMPDIR/outside-home/klipper"
    mkdir -p "$outside"
    _install_fake_curl "" 7
    KLIPPER_PATH="$outside"
    PATH="$fake_bin:$PATH" discover_klipper_env
    assert_equal "$KLIPPER_PATH" "$outside"
}

@test "KLIPPER_PLUGINS_PATH prefers klippy/plugins if it exists" {
    mkdir -p "$HOME/klipper/klippy/plugins"
    _install_fake_curl "" 7
    PATH="$fake_bin:$PATH" discover_klipper_env
    assert_equal "$KLIPPER_PLUGINS_PATH" "${HOME}/klipper/klippy/plugins"
}

@test "check_no_active_print returns 0 for standby" {
    _install_fake_curl "{\"result\":{\"status\":{\"print_stats\":{\"state\":\"standby\"}}}}"
    MOONRAKER_HOST="http://localhost:7125"
    PATH="$fake_bin:$PATH" run check_no_active_print
    assert_success
}

@test "check_no_active_print returns 1 while printing" {
    _install_fake_curl "{\"result\":{\"status\":{\"print_stats\":{\"state\":\"printing\"}}}}"
    MOONRAKER_HOST="http://localhost:7125"
    PATH="$fake_bin:$PATH" run check_no_active_print
    assert_equal "$status" 1
}

@test "check_no_active_print queries only print_stats.state" {
    cat > "$fake_bin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$KPI_TEST_TMPDIR/curl_args"
echo '{"result":{"status":{"print_stats":{"state":"standby"}}}}'
EOF
    chmod +x "$fake_bin/curl"
    MOONRAKER_HOST="http://localhost:7125"
    PATH="$fake_bin:$PATH" run check_no_active_print
    assert_success
    run grep -Fx "http://localhost:7125/printer/objects/query?print_stats=state" "$KPI_TEST_TMPDIR/curl_args"
    assert_success
}

@test "check_no_active_print returns 1 while paused" {
    _install_fake_curl "{\"result\":{\"status\":{\"print_stats\":{\"state\":\"paused\"}}}}"
    MOONRAKER_HOST="http://localhost:7125"
    PATH="$fake_bin:$PATH" run check_no_active_print
    assert_equal "$status" 1
}

@test "check_no_active_print returns 1 when print_stats is missing" {
    _install_fake_curl "{\"result\":{\"status\":{}}}"
    MOONRAKER_HOST="http://localhost:7125"
    PATH="$fake_bin:$PATH" run check_no_active_print
    assert_equal "$status" 1
}

@test "check_no_active_print returns 1 on an API error response" {
    _install_fake_curl "{\"error\":{\"code\":503,\"message\":\"Klippy Host not connected\"}}" 22
    MOONRAKER_HOST="http://localhost:7125"
    PATH="$fake_bin:$PATH" run check_no_active_print
    assert_equal "$status" 1
}

@test "check_no_active_print returns 1 when Moonraker is unreachable" {
    _install_fake_curl "" 7
    MOONRAKER_HOST="http://localhost:7125"
    PATH="$fake_bin:$PATH" run check_no_active_print
    assert_equal "$status" 1
}

@test "moonraker_query prints the response body and returns curl's exit code" {
    _install_fake_curl "some body" 0
    MOONRAKER_HOST="http://localhost:7125"
    PATH="$fake_bin:$PATH" run moonraker_query "/printer/info"
    assert_success
    assert_output "some body"
}

@test "discover_klipper_env dies when HOME is unset" {
    unset HOME
    _install_fake_curl "" 7
    PATH="$fake_bin:$PATH" run discover_klipper_env
    assert_failure
}

@test "discover_klipper_env dies when HOME does not resolve to a real directory" {
    HOME="$KPI_TEST_TMPDIR/does-not-exist-home"
    _install_fake_curl "" 7
    PATH="$fake_bin:$PATH" run discover_klipper_env
    assert_failure
}
