#!/bin/bash
# version.sh — Version Tracking. Same realpath-first, temp-file,
# permission-preserving pattern as config_block.sh — never in place.

# BSD/macOS realpath has no -m; BSD/macOS chmod has no --reference. Same
# portable replacements as config_block.sh's
# _kpi_config_block_realpath_m / _kpi_config_block_chmod_reference —
# pre-empted here rather than discovered via a later test failure.
_kpi_version_realpath_m() {
    local path="$1"
    if [ -e "$path" ]; then
        realpath "$path"
        return
    fi
    local dir base resolved_dir
    dir="$(dirname "$path")"
    base="$(basename "$path")"
    resolved_dir="$(_kpi_version_realpath_m "$dir")"
    printf '%s/%s\n' "$resolved_dir" "$base"
}

_kpi_version_chmod_reference() {
    local ref="$1" target="$2"
    local mode
    mode="$(stat -c %a "$ref" 2>/dev/null || stat -f %Lp "$ref" 2>/dev/null)"
    [ -n "$mode" ] || return 1
    chmod "$mode" "$target"
}

version_stamp() {
    local repo_dir="$1" dest_file="$2"
    local sha
    sha="$(git -C "$repo_dir" rev-parse HEAD)" || die "version_stamp: cannot resolve HEAD in $repo_dir"

    local resolved
    if [ -e "$dest_file" ]; then
        resolved="$(realpath "$dest_file")"
    else
        resolved="$(_kpi_version_realpath_m "$dest_file")"
    fi

    local tmp=""
    local _kpi_prev_trap _kpi_prev_trap_cmd=""
    _kpi_prev_trap="$(trap -p EXIT)"
    # See config_block.sh's _kpi_config_block_write: eval-ing the full
    # `trap -p` string only re-registers the prior trap, a no-op once it
    # fires from inside our own EXIT trap (the shell is already exiting).
    # Shadowing `trap` as a function while evaluating that string hands us
    # its bare command text instead, which we can actually execute here.
    if [ -n "$_kpi_prev_trap" ]; then
        # shellcheck disable=SC2329  # invoked indirectly: eval-ing
        # "$_kpi_prev_trap" (a `trap -- '...' EXIT` string) calls this
        # shadowed `trap` with the captured command as $2.
        _kpi_prev_trap_cmd="$(trap() { printf '%s' "$2"; }; eval "$_kpi_prev_trap")"
    fi
    trap 'rm -f "$tmp"; if [ -n "$_kpi_prev_trap_cmd" ]; then eval "$_kpi_prev_trap_cmd"; fi' EXIT

    tmp="$(mktemp "$(dirname "$resolved")/.kpi.XXXXXX")" || die "version_stamp: mktemp failed"
    echo "$sha" > "$tmp" || die "version_stamp: write failed: $tmp"
    if [ -f "$resolved" ]; then
        _kpi_version_chmod_reference "$resolved" "$tmp" \
            || die "version_stamp: failed to preserve permissions from $resolved onto temp file"
    fi
    mv "$tmp" "$resolved" || die "version_stamp: rename failed: $tmp -> $resolved"

    if [ -n "$_kpi_prev_trap" ]; then
        eval "$_kpi_prev_trap"
    else
        trap - EXIT
    fi
}

is_first_install() {
    local dest_file="$1"
    [ ! -e "$dest_file" ]
}
