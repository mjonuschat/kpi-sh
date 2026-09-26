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
        # shellcheck disable=SC2317,SC2329  # invoked indirectly: eval-ing
        # "$_kpi_prev_trap" (a `trap -- '...' EXIT` string) calls this
        # shadowed `trap` with the captured command as $2.
        _kpi_prev_trap_cmd="$(trap() { printf '%s' "$2"; }; eval "$_kpi_prev_trap")"
    fi
    trap 'rm -f "$tmp"; if [ -n "$_kpi_prev_trap_cmd" ]; then eval "$_kpi_prev_trap_cmd"; fi' EXIT

    tmp="$(mktemp "$(dirname "$resolved")/.kpi.XXXXXX")" || die "config_block: mktemp failed for $resolved"
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

# Prints $resolved with every block named $name removed or, when a
# replacement is given, the first one's body swapped for it and any later
# duplicates removed. Dies on a malformed block.
_kpi_config_block_rewrite() {
    local caller="$1" resolved="$2" name="$3"
    local start="# --- $name ---" end="# --- /$name ---"
    local replace=0 replacement=""
    if [ "$#" -ge 4 ]; then
        replace=1
        replacement="$4"
    fi

    local out rc=0
    # The replacement goes through ENVIRON: awk -v would interpret backslash
    # escapes in it.
    out="$(KPI_REPLACEMENT="$replacement" awk -v start="$start" -v end="$end" -v replace="$replace" '
        BEGIN { in_block = 0; done = 0 }
        {
            if (!in_block && $0 == start) {
                in_block = 1
                if (replace && !done) { print start; print ENVIRON["KPI_REPLACEMENT"]; print end }
                done = 1
                next
            }
            if (in_block) {
                if ($0 == end) { in_block = 0; next }
                if ($0 ~ /^# --- .+ ---$/) {
                    print "config_block: foreign sentinel inside block: " $0 > "/dev/stderr"
                    exit 3
                }
                next
            }
            print
        }
        END { if (in_block) exit 4 }
    ' "$resolved")" || rc=$?
    if [ "$rc" -eq 3 ] || [ "$rc" -eq 4 ]; then
        die "$caller: malformed block for $name in $resolved"
    elif [ "$rc" -ne 0 ]; then
        # Any other nonzero awk exit (e.g. a read failure) must stop here
        # rather than feed partial output into the atomic write.
        die "$caller: failed to process $resolved (awk exit $rc)"
    fi
    printf '%s' "$out"
}

# Replaces the body of an existing block in place, or no-ops when it
# already matches. Returns 1 if the block is absent.
_kpi_config_block_update() {
    local caller="$1" resolved="$2" name="$3" content="$4"
    local grep_rc=0
    grep -qxF "# --- $name ---" "$resolved" || grep_rc=$?
    if [ "$grep_rc" -eq 1 ]; then
        return 1
    elif [ "$grep_rc" -ne 0 ]; then
        die "$caller: cannot read $resolved (grep exit $grep_rc)"
    fi

    local existing_content new_content
    existing_content="$(cat "$resolved")" || die "$caller: cannot read $resolved"
    new_content="$(_kpi_config_block_rewrite "$caller" "$resolved" "$name" "$content")" \
        || die "$caller: cannot update block $name in $resolved"
    if [ "$new_content" != "$existing_content" ]; then
        _kpi_config_block_write "$resolved" "$new_content"$'\n'
    fi
}

config_block_add() {
    local -x LC_ALL=C
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

    if _kpi_config_block_update config_block_add "$resolved" "$name" "$content"; then
        return 0
    fi
    local start="# --- $name ---"

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
    local -x LC_ALL=C
    local file="$1" name="$2" content="$3"
    _kpi_config_block_check_name "$name" config_block_ensure
    if printf '%s\n' "$content" | grep -qE '^# --- .+ ---$'; then
        die "config_block_ensure: content contains a sentinel-shaped line"
    fi

    # A dangling symlink at $file is removed first so we don't try to
    # write through a broken link.
    if [ -L "$file" ] && [ ! -e "$file" ]; then
        rm -f "$file" || die "config_block_ensure: cannot remove dangling symlink: $file"
    fi

    local resolved
    resolved="$(_kpi_config_block_resolve_existing "$file")"
    local existing=""
    if [ -n "$resolved" ]; then
        if _kpi_config_block_update config_block_ensure "$resolved" "$name" "$content"; then
            return 0
        fi
        local existing_content
        existing_content="$(cat "$resolved")" || die "config_block_ensure: cannot read $resolved"
        existing="$existing_content"$'\n'
    else
        resolved="$(_kpi_config_block_realpath_m "$file")" \
            || die "config_block_ensure: cannot resolve $file"
    fi

    local new_content
    new_content="${existing}# --- $name ---"$'\n'"$content"$'\n'"# --- /$name ---"$'\n'
    _kpi_config_block_write "$resolved" "$new_content"
}

config_block_remove() {
    local -x LC_ALL=C
    local file="$1" name="$2"
    _kpi_config_block_check_name "$name" config_block_remove
    local resolved
    resolved="$(_kpi_config_block_resolve_existing "$file")"
    if [ -z "$resolved" ]; then
        return 0
    fi

    # Distinguish "genuinely not found" (grep exit 1) from "couldn't even
    # read the file" (any other nonzero) — `if ! grep ...` alone treats a
    # permission error identically to "not found" and would silently
    # no-op instead of ever reaching the failure checks below.
    local grep_rc=0
    grep -qxF "# --- $name ---" "$resolved" || grep_rc=$?
    if [ "$grep_rc" -eq 1 ]; then
        return 0
    elif [ "$grep_rc" -ne 0 ]; then
        die "config_block_remove: cannot read $resolved (grep exit $grep_rc)"
    fi

    local new_content
    new_content="$(_kpi_config_block_rewrite config_block_remove "$resolved" "$name")" \
        || die "config_block_remove: cannot remove block $name from $resolved"
    _kpi_config_block_write "$resolved" "$new_content"$'\n'
}
