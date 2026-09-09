#!/bin/bash
# config_block.sh — Sentinel-Delimited Config Blocks. Writes are atomic
# via temp-file-then-rename (visibility-only, not fsync durability — see
# spec). Matching is fixed-string, never regex.

# BSD/macOS realpath has no -m (GNU-only: resolve a path that may not
# exist yet). Walk up to the nearest existing ancestor, realpath that
# (so symlinked ancestors still resolve), then append the missing tail
# lexically. Same fix pattern as git.sh's _kpi_git_realpath_m.
_kpi_config_block_realpath_m() {
    local path="$1"
    if [ -e "$path" ]; then
        realpath "$path"
        return
    fi
    local dir base resolved_dir
    dir="$(dirname "$path")"
    base="$(basename "$path")"
    resolved_dir="$(_kpi_config_block_realpath_m "$dir")"
    printf '%s/%s\n' "$resolved_dir" "$base"
}

# BSD/macOS chmod has no --reference (GNU-only). Read the source file's
# mode with stat (whose format flag also differs: GNU `-c %a`, BSD
# `-f %Lp`) and apply it numerically instead.
_kpi_config_block_chmod_reference() {
    local ref="$1" target="$2"
    local mode
    mode="$(stat -c %a "$ref" 2>/dev/null || stat -f %Lp "$ref" 2>/dev/null)"
    [ -n "$mode" ] || return 1
    chmod "$mode" "$target"
}

_kpi_config_block_check_name() {
    local name="$1" caller="${2:-config_block}"
    [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || die "$caller: invalid name: $name"
}

_kpi_config_block_write() {
    # Args: resolved_file, new_content (already has trailing newline)
    local resolved="$1" new_content="$2"
    local tmp=""
    local _kpi_prev_trap _kpi_prev_trap_cmd=""
    _kpi_prev_trap="$(trap -p EXIT)"
    # `eval "$_kpi_prev_trap"` (the full `trap -- '...' EXIT` string) only
    # re-registers the trap — a no-op if it fires from inside our own EXIT
    # trap, since the shell is already exiting and an EXIT trap fires once.
    # Shadow `trap` as a function so evaluating that string hands us its
    # bare command text ($2) instead, which we can actually execute on the
    # abnormal-exit path below.
    if [ -n "$_kpi_prev_trap" ]; then
        # shellcheck disable=SC2329  # invoked indirectly: eval-ing
        # "$_kpi_prev_trap" (a `trap -- '...' EXIT` string) calls this
        # shadowed `trap` with the captured command as $2.
        _kpi_prev_trap_cmd="$(trap() { printf '%s' "$2"; }; eval "$_kpi_prev_trap")"
    fi
    trap 'rm -f "$tmp"; if [ -n "$_kpi_prev_trap_cmd" ]; then eval "$_kpi_prev_trap_cmd"; fi' EXIT

    tmp="$(mktemp "$(dirname "$resolved").kpi.XXXXXX")" || die "config_block: mktemp failed for $resolved"
    printf '%s' "$new_content" > "$tmp" || die "config_block: write to temp file failed: $tmp"
    if [ -f "$resolved" ]; then
        _kpi_config_block_chmod_reference "$resolved" "$tmp" \
            || die "config_block: failed to preserve permissions from $resolved onto temp file"
    fi
    mv "$tmp" "$resolved" || die "config_block: rename failed: $tmp -> $resolved"

    if [ -n "$_kpi_prev_trap" ]; then
        eval "$_kpi_prev_trap"
    else
        trap - EXIT
    fi
}

_kpi_config_block_resolve_existing() {
    # Prints the realpath of $1 if it resolves to a real (non-dangling)
    # file, empty string if absent/dangling. Never dies here — callers
    # decide what absence means for them.
    local file="$1"
    if [ -L "$file" ] && [ ! -e "$file" ]; then
        echo ""
        return 0
    fi
    if [ -e "$file" ]; then
        realpath "$file"
    else
        echo ""
    fi
}

config_block_add() {
    local file="$1" name="$2" content="$3"
    _kpi_config_block_check_name "$name" config_block_add
    if printf '%s\n' "$content" | grep -qE '^# --- .+ ---$'; then
        die "config_block_add: content contains a sentinel-shaped line"
    fi

    local resolved
    resolved="$(_kpi_config_block_resolve_existing "$file")"
    if [ -z "$resolved" ]; then
        die "config_block_add: file does not exist: $file"
    fi

    local start="# --- $name ---"
    if grep -qxF "$start" "$resolved"; then
        return 0
    fi

    # Checked explicitly: an unreadable existing file (e.g. permission
    # revoked after resolve) would otherwise make this `cat` fail
    # silently, and the atomic write below would then replace the whole
    # file with just the new block — a real data-loss path, not just a
    # missed error message.
    local existing_content
    existing_content="$(cat "$resolved")" || die "config_block_add: cannot read $resolved"
    local new_content
    new_content="$existing_content"$'\n'"$start"$'\n'"$content"$'\n'"# --- /$name ---"$'\n'
    _kpi_config_block_write "$resolved" "$new_content"
}

config_block_ensure() {
    local file="$1" name="$2" content="$3"
    _kpi_config_block_check_name "$name" config_block_ensure
    if printf '%s\n' "$content" | grep -qE '^# --- .+ ---$'; then
        die "config_block_ensure: content contains a sentinel-shaped line"
    fi

    # A dangling symlink at $file is removed first so we don't try to
    # write through a broken link.
    if [ -L "$file" ] && [ ! -e "$file" ]; then
        rm -f "$file"
    fi

    local resolved
    resolved="$(_kpi_config_block_resolve_existing "$file")"
    local existing=""
    if [ -n "$resolved" ]; then
        if grep -qxF "# --- $name ---" "$resolved"; then
            return 0
        fi
        local existing_content
        existing_content="$(cat "$resolved")" || die "config_block_ensure: cannot read $resolved"
        existing="$existing_content"$'\n'
    else
        resolved="$(_kpi_config_block_realpath_m "$file")"
    fi

    local new_content
    new_content="${existing}# --- $name ---"$'\n'"$content"$'\n'"# --- /$name ---"$'\n'
    _kpi_config_block_write "$resolved" "$new_content"
}

config_block_remove() {
    local file="$1" name="$2"
    _kpi_config_block_check_name "$name" config_block_remove
    local resolved
    resolved="$(_kpi_config_block_resolve_existing "$file")"
    if [ -z "$resolved" ]; then
        return 0
    fi

    local start="# --- $name ---"
    local end="# --- /$name ---"
    # Distinguish "genuinely not found" (grep exit 1) from "couldn't even
    # read the file" (any other nonzero) — `if ! grep ...` alone treats a
    # permission error identically to "not found" and would silently
    # no-op instead of ever reaching the failure checks below.
    grep -qxF "$start" "$resolved"
    local grep_rc=$?
    if [ "$grep_rc" -eq 1 ]; then
        return 0
    elif [ "$grep_rc" -ne 0 ]; then
        die "config_block_remove: cannot read $resolved (grep exit $grep_rc)"
    fi

    local new_content
    new_content="$(awk -v start="$start" -v end="$end" '
        BEGIN { in_block = 0 }
        {
            if (!in_block && $0 == start) { in_block = 1; next }
            if (in_block) {
                if ($0 == end) { in_block = 0; next }
                if ($0 ~ /^# --- .+ ---$/) {
                    print "config_block_remove: foreign sentinel inside block: " $0 > "/dev/stderr"
                    exit 3
                }
                next
            }
            print
        }
        END { if (in_block) exit 4 }
    ' "$resolved")"
    local rc=$?
    if [ "$rc" -eq 3 ] || [ "$rc" -eq 4 ]; then
        die "config_block_remove: malformed block for $name in $resolved"
    elif [ "$rc" -ne 0 ]; then
        # Any other nonzero awk exit (e.g. a read failure — permission
        # revoked on $resolved after resolve) must also stop here.
        # Checking only 3/4 and letting everything else fall through
        # would feed incomplete/wrong output into the atomic write below.
        die "config_block_remove: failed to process $resolved (awk exit $rc)"
    fi

    _kpi_config_block_write "$resolved" "$new_content"$'\n'
}
