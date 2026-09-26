#!/bin/bash
# git.sh — Git Repository Management. Never fetches/pulls an
# already-valid existing checkout — see spec "How updates actually
# happen" for why (Moonraker's update_manager owns that, not kpi-sh).

# BSD/macOS realpath has no -m (GNU-only: resolve a path that may not
# exist yet). Walk up to the nearest existing ancestor, realpath that
# (so symlinked ancestors still resolve), then append the missing tail
# lexically.
_kpi_git_realpath_m() {
    local path="$1"
    if [ -e "$path" ]; then
        realpath "$path"
        return
    fi
    local dir base resolved_dir
    dir="$(dirname "$path")"
    base="$(basename "$path")"
    resolved_dir="$(_kpi_git_realpath_m "$dir")"
    printf '%s/%s\n' "$resolved_dir" "$base"
}

git_ensure_clone() {
    local repo_url="$1" dest="$2" validator="${3:-}" ref="${4:-}"
    local resolved
    resolved="$(_kpi_git_realpath_m "$dest")" || die "git_ensure_clone: cannot resolve $dest"

    if [ -e "$resolved" ] && [ "$(ls -A "$resolved" 2>/dev/null)" ]; then
        if [ -d "$resolved/.git" ]; then
            local origin
            origin="$(git -C "$resolved" remote get-url origin 2>/dev/null)"
            if [ "$origin" != "$repo_url" ]; then
                die "git_ensure_clone: $resolved origin ($origin) does not match $repo_url"
            fi
        else
            die "git_ensure_clone: $resolved exists, is non-empty, and is not a git repo"
        fi
    else
        git clone -q "$repo_url" "$resolved" || die "git_ensure_clone: clone failed for $repo_url"
    fi

    if [ -n "$ref" ]; then
        if [ -n "$(git -C "$resolved" status --porcelain 2>/dev/null)" ]; then
            die "git_ensure_clone: $resolved has uncommitted changes, refusing to checkout $ref"
        fi
        # `git fetch origin <tag-or-branch-name>` does not create a local
        # ref by that name (only a raw SHA that's already a local ref
        # would resolve directly) — it only updates FETCH_HEAD. Checking
        # out FETCH_HEAD instead of $ref works uniformly for a branch
        # tip, a tag, or a raw commit SHA. Fetch's exit status must be
        # checked explicitly: on failure, FETCH_HEAD is left unchanged
        # from a prior fetch/clone, so an unchecked fetch would silently
        # check out stale state instead of failing.
        git -C "$resolved" fetch origin "$ref" >/dev/null 2>&1 \
            || die "git_ensure_clone: could not resolve ref $ref in $resolved"
        git -C "$resolved" checkout --detach -q FETCH_HEAD 2>/dev/null \
            || die "git_ensure_clone: could not checkout ref $ref in $resolved"
    fi

    if [ -n "$validator" ] && [ ! -e "$resolved/$validator" ]; then
        die "git_ensure_clone: validator missing after checkout: $resolved/$validator"
    fi
}
