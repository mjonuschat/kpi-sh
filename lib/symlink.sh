#!/bin/bash
# symlink.sh — Safe Symlink Management. Concurrency is explicitly out of
# scope (single-shot, single-process installer runs) — see spec.

classify_path() {
    local path="$1"
    local parent
    parent="$(dirname "$path")"

    if [ -d "$parent" ] && [ ! -x "$parent" ]; then
        die "cannot determine status of $path: permission denied on $parent"
    fi

    if [ -L "$path" ]; then
        echo "symlink"
    elif [ -e "$path" ]; then
        echo "real"
    else
        echo "absent"
    fi
}

remove_safe_link() {
    local path="$1"
    local state
    state="$(classify_path "$path")" || return 2

    case "$state" in
        absent) return 0 ;;
        symlink)
            rm -f "$path" || return 2
            return 0
            ;;
        real)
            err "refusing to remove non-symlink: $path"
            return 1
            ;;
    esac
}

link_safe() {
    local allow_dangling=0
    if [ "$1" = "--allow-dangling" ]; then
        allow_dangling=1
        shift
    fi
    local target link_name="$2"
    target="$(abspath "$1")" || die "link_safe: cannot resolve target: $1"

    if [ "$allow_dangling" -eq 0 ] && [ ! -e "$target" ]; then
        die "link_safe: target does not exist: $target"
    fi

    local state
    # classify_path can itself die (permission error on the parent) — that
    # die() only terminates the command-substitution subshell, so it must
    # be checked explicitly here rather than trusting $state to be sane.
    state="$(classify_path "$link_name")" || die "link_safe: cannot determine status of $link_name"
    case "$state" in
        real)
            die "link_safe: refusing to overwrite non-symlink: $link_name"
            ;;
        symlink)
            rm -f "$link_name" || die "link_safe: cannot remove existing symlink: $link_name"
            ;;
    esac

    local parent
    parent="$(dirname "$link_name")"
    mkdir -p "$parent" || die "link_safe: cannot create directory: $parent"
    ln -s "$target" "$link_name" || die "link_safe: cannot create symlink: $link_name -> $target"
}
