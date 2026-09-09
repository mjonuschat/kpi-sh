#!/usr/bin/env bats

load 'test_helper/common'

setup() {
    common_setup
    source lib/header.sh
    source lib/log.sh
    source lib/git.sh

    remote="$KPI_TEST_TMPDIR/remote.git"
    git init --bare -q "$remote"
    # Local test remotes don't allow fetching an unadvertised raw commit
    # SHA by default; GitHub/GitLab do (that's what git.sh's $ref grammar
    # relies on in production — see spec's explicit host-capability
    # caveat), but this test needs its own local remote to behave the
    # same way to be deterministic rather than depending on the test
    # runner's installed git version's defaults.
    git -C "$remote" config uploadpack.allowReachableSHA1InWant true
    git -C "$remote" config uploadpack.allowAnySHA1InWant true
    # A bare repo's HEAD defaults to whatever branch name git's own config
    # picks (commonly "master" unless init.defaultBranch is set) — pushing
    # to "main" alone does NOT repoint that default, so a fresh clone would
    # check out the empty original branch and marker.txt would be missing.
    # Force HEAD to "main" explicitly rather than relying on git's default.
    git -C "$remote" symbolic-ref HEAD refs/heads/main
    work="$KPI_TEST_TMPDIR/work"
    git clone -q "$remote" "$work"
    git -C "$work" config user.email "test@example.com"
    git -C "$work" config user.name "Test"
    git -C "$work" checkout -q -B main
    echo "v1" > "$work/marker.txt"
    git -C "$work" add marker.txt
    git -C "$work" commit -q -m "v1"
    git -C "$work" push -q origin HEAD:main
}

teardown() {
    common_teardown
}

@test "clones into an empty destination" {
    dest="$KPI_TEST_TMPDIR/dest"
    git_ensure_clone "$remote" "$dest"
    assert_file_exist "$dest/marker.txt"
}

@test "dest resolved via realpath -m works when dest does not exist yet" {
    dest="$KPI_TEST_TMPDIR/does/not/exist/dest"
    git_ensure_clone "$remote" "$dest"
    assert_file_exist "$dest/marker.txt"
}

@test "second call against an already-valid checkout performs no fetch" {
    dest="$KPI_TEST_TMPDIR/dest"
    git_ensure_clone "$remote" "$dest"
    fake_bin="$KPI_TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"
    # Capture the real git's absolute path before PATH is shadowed below.
    # `exec /usr/bin/env git "$@"` would re-resolve "git" through the
    # still-shadowed PATH and call itself forever instead of real git.
    real_git="$(command -v git)"
    cat > "$fake_bin/git" <<EOF
#!/bin/bash
if [ "\$1" = "fetch" ]; then
    echo "FETCH_CALLED" >&2
    exit 1
fi
exec "$real_git" "\$@"
EOF
    chmod +x "$fake_bin/git"
    PATH="$fake_bin:$PATH" run git_ensure_clone "$remote" "$dest"
    assert_success
    refute_output --partial "FETCH_CALLED"
}

@test "dies when dest exists, is non-empty, and is not a git repo" {
    dest="$KPI_TEST_TMPDIR/dest"
    mkdir -p "$dest"
    touch "$dest/somefile"
    run git_ensure_clone "$remote" "$dest"
    assert_failure
}

@test "dies when origin does not match repo_url" {
    dest="$KPI_TEST_TMPDIR/dest"
    other_remote="$KPI_TEST_TMPDIR/other.git"
    git init --bare -q "$other_remote"
    git clone -q "$other_remote" "$dest"
    run git_ensure_clone "$remote" "$dest"
    assert_failure
}

@test "validator missing after clone dies" {
    dest="$KPI_TEST_TMPDIR/dest"
    run git_ensure_clone "$remote" "$dest" "does-not-exist.txt"
    assert_failure
}

@test "ref pins to a specific commit" {
    dest="$KPI_TEST_TMPDIR/dest"
    git_ensure_clone "$remote" "$dest"
    old_sha="$(git -C "$dest" rev-parse HEAD)"

    echo "v2" > "$work/marker.txt"
    git -C "$work" commit -q -am "v2"
    git -C "$work" push -q origin HEAD:main

    rm -rf "$dest"
    git_ensure_clone "$remote" "$dest" "" "$old_sha"
    assert_equal "$(git -C "$dest" rev-parse HEAD)" "$old_sha"
    assert_equal "$(cat "$dest/marker.txt")" "v1"
}

@test "ref created after the initial clone is still found via fetch" {
    dest="$KPI_TEST_TMPDIR/dest"
    git_ensure_clone "$remote" "$dest"

    echo "v2" > "$work/marker.txt"
    git -C "$work" commit -q -am "v2"
    git -C "$work" tag v2.0.0
    git -C "$work" push -q origin HEAD:main --tags
    new_sha="$(git -C "$work" rev-parse HEAD)"

    git_ensure_clone "$remote" "$dest" "" "v2.0.0"
    assert_equal "$(git -C "$dest" rev-parse HEAD)" "$new_sha"
}

@test "ref checkout dies on a dirty worktree" {
    dest="$KPI_TEST_TMPDIR/dest"
    git_ensure_clone "$remote" "$dest"
    echo "dirty" >> "$dest/marker.txt"

    echo "v2" > "$work/marker.txt"
    git -C "$work" commit -q -am "v2"
    git -C "$work" push -q origin HEAD:main

    run git_ensure_clone "$remote" "$dest" "" "$(git -C "$work" rev-parse HEAD)"
    assert_failure
}

@test "unresolvable ref dies" {
    dest="$KPI_TEST_TMPDIR/dest"
    run git_ensure_clone "$remote" "$dest" "" "0000000000000000000000000000000000000000"
    assert_failure
}

@test "validator is checked against the post-ref-checkout state" {
    dest="$KPI_TEST_TMPDIR/dest"
    git_ensure_clone "$remote" "$dest"
    old_sha="$(git -C "$dest" rev-parse HEAD)"

    echo "content" > "$work/only-in-v2.txt"
    git -C "$work" add only-in-v2.txt
    git -C "$work" commit -q -am "v2 adds a file"
    git -C "$work" push -q origin HEAD:main

    rm -rf "$dest"
    run git_ensure_clone "$remote" "$dest" "only-in-v2.txt" "$old_sha"
    assert_failure
}

@test "a raw commit SHA reachable only from a non-default branch tip resolves via fetch" {
    dest="$KPI_TEST_TMPDIR/dest"
    git_ensure_clone "$remote" "$dest"

    git -C "$work" checkout -q -b feature-branch
    echo "feature content" > "$work/feature.txt"
    git -C "$work" add feature.txt
    git -C "$work" commit -q -m "feature commit"
    feature_sha="$(git -C "$work" rev-parse HEAD)"
    git -C "$work" push -q origin feature-branch
    # Never tagged, never merged to main — only reachable via the
    # feature-branch tip. `git fetch origin "$ref"` must still resolve it.

    git_ensure_clone "$remote" "$dest" "" "$feature_sha"
    assert_equal "$(git -C "$dest" rev-parse HEAD)" "$feature_sha"
    assert_file_exist "$dest/feature.txt"
}

@test "dest resolves correctly when its parent directory is a symlink" {
    real_parent="$KPI_TEST_TMPDIR/real_parent"; mkdir -p "$real_parent"
    linked_parent="$KPI_TEST_TMPDIR/linked_parent"
    ln -s "$real_parent" "$linked_parent"
    dest="$linked_parent/dest"

    git_ensure_clone "$remote" "$dest"
    assert_file_exist "$real_parent/dest/marker.txt"
}
