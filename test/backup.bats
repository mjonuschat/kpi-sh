#!/usr/bin/env bats

load 'test_helper/common'

setup() {
    common_setup
    source lib/header.sh
    source lib/log.sh
    source lib/backup.sh
}

teardown() {
    common_teardown
}

@test "creates backup_root if it does not exist yet" {
    src="$KPI_TEST_TMPDIR/src"; mkdir -p "$src"; touch "$src/f"
    root="$KPI_TEST_TMPDIR/does/not/exist/backups"
    dir="$(backup_dir_timestamped "$src" "$root")"
    assert_file_exist "$dir/f"
}

@test "copies source contents into the timestamped directory" {
    src="$KPI_TEST_TMPDIR/src"; mkdir -p "$src"; echo "hi" > "$src/f"
    root="$KPI_TEST_TMPDIR/backups"
    dir="$(backup_dir_timestamped "$src" "$root")"
    assert_equal "$(cat "$dir/f")" "hi"
}

@test "absent source creates an empty backup dir without error" {
    root="$KPI_TEST_TMPDIR/backups"
    # --separate-stderr: backup_dir_timestamped logs an informational
    # message to stderr on this path (per the stdout-is-return-data
    # contract); bats' `run` merges stdout+stderr into $output by
    # default, which would otherwise make $output not a bare path.
    run --separate-stderr backup_dir_timestamped "$KPI_TEST_TMPDIR/no-such-source" "$root"
    assert_success
    assert [ -d "$output" ]
}

@test "dies when source exists but is a regular file" {
    src="$KPI_TEST_TMPDIR/src-file"; touch "$src"
    root="$KPI_TEST_TMPDIR/backups"
    run backup_dir_timestamped "$src" "$root"
    assert_failure
}

@test "a dangling source symlink is treated as absent" {
    src="$KPI_TEST_TMPDIR/dangling"; ln -s "$KPI_TEST_TMPDIR/nowhere" "$src"
    root="$KPI_TEST_TMPDIR/backups"
    run backup_dir_timestamped "$src" "$root"
    assert_success
}

@test "dies when source and backup_root overlap" {
    root="$KPI_TEST_TMPDIR/backups"; mkdir -p "$root"
    run backup_dir_timestamped "$root" "$root/nested"
    assert_failure
}

@test "timestamp collision appends -2 instead of overwriting" {
    src="$KPI_TEST_TMPDIR/src"; mkdir -p "$src"
    root="$KPI_TEST_TMPDIR/backups"
    dir1="$(backup_dir_timestamped "$src" "$root")"
    dir2="$(backup_dir_timestamped "$src" "$root")"
    assert_not_equal "$dir1" "$dir2"
}

@test "backup directory never appears at its real path until fully populated" {
    src="$KPI_TEST_TMPDIR/src"; mkdir -p "$src"
    for i in $(seq 1 200); do echo "line $i" >> "$src/big.txt"; done
    root="$KPI_TEST_TMPDIR/backups"
    mkdir -p "$root"

    (
        for _ in $(seq 1 50); do
            for d in "$root"/*/; do
                [ -d "$d" ] && [ ! -f "${d}big.txt" ] && touch "$KPI_TEST_TMPDIR/OBSERVED_PARTIAL"
            done
            sleep 0.01
        done
    ) &
    watcher=$!

    backup_dir_timestamped "$src" "$root" >/dev/null
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true

    assert_file_not_exist "$KPI_TEST_TMPDIR/OBSERVED_PARTIAL"
}

_kpi_backup_signal_test() {
    # $1: signal name (INT/TERM), $2: expected numeric signal (2/15)
    local sig="$1" signum="$2"
    src="$KPI_TEST_TMPDIR/src"; mkdir -p "$src"
    root="$KPI_TEST_TMPDIR/backups"; mkdir -p "$root"
    pid_file="$KPI_TEST_TMPDIR/subshell.pid"
    ready_file="$KPI_TEST_TMPDIR/cp.ready"
    rm -f "$pid_file" "$ready_file"
    script="$KPI_TEST_TMPDIR/run.sh"
    # set -eu matters here: signaling the SUBSHELL that runs
    # backup_dir_timestamped (inside the command substitution) makes that
    # subshell exit 128+signum, but that alone doesn't stop the OUTER
    # script — only `set -e` turns the failing assignment into an
    # immediate exit with that same code, which is what "SHOULD_NOT_PRINT"
    # is actually checking for.
    cat > "$script" <<EOF
#!/bin/bash
set -eu
source "$PWD/lib/header.sh"
source "$PWD/lib/log.sh"
source "$PWD/lib/backup.sh"
slow_source="\$1"
pid_file="\$2"
backup_dir="\$(echo "\$BASHPID" > "\$pid_file"; backup_dir_timestamped "\$slow_source" "$root")"
echo "SHOULD_NOT_PRINT"
EOF
    chmod +x "$script"
    slow_src="$KPI_TEST_TMPDIR/slow_src"
    mkdir -p "$slow_src"
    # Make cp slow by shadowing it in a PATH stub the script's `cp` call
    # finds. The stub also touches a readiness marker the instant it
    # starts — since traps are installed and mktemp -d has already run by
    # the time backup_dir_timestamped's `cp` call is reached, seeing this
    # marker is what proves the signal below actually lands mid-copy,
    # after the trap is live, rather than racing it (signaling based only
    # on the pid_file could hit the subshell before it ever installs the
    # trap, letting bash's default un-trapped disposition handle the
    # signal instead of exercising the cleanup/re-raise logic at all).
    fake_bin="$KPI_TEST_TMPDIR/bin"; mkdir -p "$fake_bin"
    cat > "$fake_bin/cp" <<EOF
#!/bin/bash
touch "$ready_file"
sleep 5
EOF
    chmod +x "$fake_bin/cp"

    # Invoke via `bash "$script"` (PATH resolution), not `"$script"`
    # directly (shebang resolution) — same convention as every other
    # embedded test script in this suite (config_block.bats, path.bats,
    # etc.). On this dev Mac /bin/bash is the ancient system bash 3.2,
    # which header.sh's version guard rejects; PATH here resolves to a
    # bash 4+. Behavior-identical to a direct exec on the Linux target,
    # where /bin/bash already satisfies the guard.
    #
    # The launch/signal/wait sequence below runs inside its own harness
    # script — a separate, un-instrumented bash process — rather than
    # directly in this bats test function. Two reasons, both verified by
    # standalone repro outside bats:
    #  1. Delivering SIGINT/SIGQUIT to an asynchronous (`&`) job only
    #     works with job control (`set -m`) on: without it, a
    #     non-interactive shell sets those two signals to ignored for
    #     every async command, and that ignored disposition is inherited
    #     by all of that command's descendants (including our library's
    #     command-substitution subshell) — a `trap ... INT` inside can't
    #     override a disposition that was already ignored on entry.
    #  2. With job control on, bash's own `wait` re-raises the same
    #     signal to the CALLING shell once it reaps a job that died from
    #     one (this is how a job-control shell mimics a real terminal
    #     Ctrl-C once a foreground-ish job is interrupted). Inside bats,
    #     that re-raise lands on bats-exec-test's own top-level INT trap,
    #     which exists to detect a real user abort of the whole suite —
    #     it flags BATS_INTERRUPTED and mis-reports *this* test as
    #     interrupted, regardless of what our own assertions find
    #     afterward. Doing the wait in a separate process sidesteps that:
    #     the harness process itself may go on to die from the re-raised
    #     signal, but that just becomes its own exit code (128+signum) —
    #     exactly the value we want to observe via `run`.
    harness="$KPI_TEST_TMPDIR/harness.sh"
    cat > "$harness" <<EOF
#!/bin/bash
set -m
PATH="$fake_bin:\$PATH" bash "$script" "$slow_src" "$pid_file" &
outer_pid=\$!

for _ in \$(seq 1 50); do
    [ -s "$pid_file" ] && [ -e "$ready_file" ] && break
    sleep 0.1
done
[ -e "$ready_file" ] || { echo "cp readiness marker never appeared within 5s" >&2; exit 99; }
subshell_pid="\$(cat "$pid_file")"

kill "-$sig" "\$subshell_pid"
wait "\$outer_pid"
exit \$?
EOF
    chmod +x "$harness"

    run bash "$harness"
    assert_equal "$status" "$((128 + signum))"
    run bash -c "ls -A '$root' | grep -c kpi-backup"
    assert_output "0"
}

@test "SIGINT during command substitution terminates conventionally and cleans up staging" {
    _kpi_backup_signal_test INT 2
}

@test "SIGTERM during command substitution terminates conventionally and cleans up staging" {
    _kpi_backup_signal_test TERM 15
}

@test "backup_scrub_symlinks removes only symlinks under prefix, path-boundary correct" {
    dir="$KPI_TEST_TMPDIR/backup"; mkdir -p "$dir"
    managed_root="$KPI_TEST_TMPDIR/managed/bar"; mkdir -p "$managed_root"
    sibling_root="$KPI_TEST_TMPDIR/managed/barista"; mkdir -p "$sibling_root"
    ln -s "$managed_root" "$dir/managed_link"
    ln -s "$sibling_root" "$dir/sibling_link"
    ln -s "/etc" "$dir/unmanaged_link"

    backup_scrub_symlinks "$dir" "$managed_root"

    # assert_file_exist checks `-f` (regular file, dereferenced) — wrong
    # for these, since sibling_link and unmanaged_link point at
    # directories. assert_link_exist checks `-L` (the path itself is a
    # symlink, regardless of what it points to) which is what "this
    # symlink was left alone" actually means here.
    assert_file_not_exist "$dir/managed_link"
    assert_link_exist "$dir/sibling_link"
    assert_link_exist "$dir/unmanaged_link"
}

@test "backup_scrub_symlinks removes links under a prefix subdirectory but keeps a _old sibling" {
    dir="$KPI_TEST_TMPDIR/backup"; mkdir -p "$dir"
    prefix="$KPI_TEST_TMPDIR/klippain_config"; mkdir -p "$prefix/sub" "${prefix}_old"
    ln -s "$prefix/sub" "$dir/sub_link"
    ln -s "${prefix}_old" "$dir/old_link"
    backup_scrub_symlinks "$dir" "$prefix"
    assert_file_not_exist "$dir/sub_link"
    assert_link_exist "$dir/old_link"
}

@test "backup_scrub_symlinks keeps relative links even if they resolve under prefix" {
    dir="$KPI_TEST_TMPDIR/backup"; mkdir -p "$dir/managed"
    ln -s managed "$dir/rel_link"
    backup_scrub_symlinks "$dir" "$dir"
    assert_link_exist "$dir/rel_link"
}

@test "backup_scrub_symlinks canonicalizes a symlinked prefix" {
    dir="$KPI_TEST_TMPDIR/backup"; mkdir -p "$dir"
    real="$KPI_TEST_TMPDIR/real_config"; mkdir -p "$real"
    ln -s "$real" "$KPI_TEST_TMPDIR/alias_config"
    ln -s "$real" "$dir/managed_link"
    backup_scrub_symlinks "$dir" "$KPI_TEST_TMPDIR/alias_config"
    assert_file_not_exist "$dir/managed_link"
}

@test "backup_scrub_symlinks dies when backup_dir does not exist" {
    run backup_scrub_symlinks "$KPI_TEST_TMPDIR/no/such/backup" "$KPI_TEST_TMPDIR"
    assert_failure
}

@test "backup_scrub_symlinks dies on an unresolvable prefix" {
    dir="$KPI_TEST_TMPDIR/backup"; mkdir -p "$dir"
    run backup_scrub_symlinks "$dir" "$KPI_TEST_TMPDIR/no/such/prefix"
    assert_failure
}

@test "backup_scrub_symlinks leaves a dangling symlink untouched" {
    dir="$KPI_TEST_TMPDIR/backup"; mkdir -p "$dir"
    ln -s "$KPI_TEST_TMPDIR/nowhere" "$dir/dangling"
    backup_scrub_symlinks "$dir" "$KPI_TEST_TMPDIR"
    # assert_file_exist dereferences (`-f`) and a dangling symlink has no
    # target to dereference to, so it would always report "does not
    # exist" here even though the symlink itself was correctly left in
    # place. assert_link_exist checks `-L`, which doesn't dereference.
    assert_link_exist "$dir/dangling"
}

@test "a cp failure mid-copy leaves no stray staging directory and dies" {
    if [ "$EUID" -eq 0 ]; then
        skip "root bypasses permission bits — cp can't be made to fail this way as root"
    fi
    src="$KPI_TEST_TMPDIR/src"; mkdir -p "$src"
    touch "$src/unreadable"; chmod 000 "$src/unreadable"
    root="$KPI_TEST_TMPDIR/backups"; mkdir -p "$root"
    # A fresh process, not `run backup_dir_timestamped` (a same-shell
    # command-substitution subshell): die's EXIT trap genuinely EXECUTES
    # the prior trap it captured (see backup.sh's comment on this), and
    # inside `run`'s subshell that prior trap is bats' own teardown
    # trap — executing bats' internal completion protocol out of turn
    # corrupts its test count (same reasoning as config_block.bats's
    # mktemp/mv-failure tests, verified here with a standalone repro).
    script="$KPI_TEST_TMPDIR/run-cp-fail.sh"
    cat > "$script" <<EOF
#!/bin/bash
source "$PWD/lib/header.sh"
source "$PWD/lib/log.sh"
source "$PWD/lib/backup.sh"
backup_dir_timestamped "$src" "$root"
EOF
    chmod +x "$script"
    run bash "$script"
    assert_failure
    run bash -c "ls -A '$root' | grep -c kpi-backup"
    assert_output "0"
    chmod 644 "$src/unreadable"
}

@test "an uncreatable backup_root dies with a clear error" {
    if [ "$EUID" -eq 0 ]; then
        skip "root bypasses permission bits"
    fi
    src="$KPI_TEST_TMPDIR/src"; mkdir -p "$src"
    parent="$KPI_TEST_TMPDIR/locked"; mkdir -p "$parent"; chmod 000 "$parent"
    run backup_dir_timestamped "$src" "$parent/backups"
    assert_failure
    chmod 755 "$parent"
}
