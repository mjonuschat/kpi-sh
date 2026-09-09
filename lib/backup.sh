#!/bin/bash
# backup.sh — Config Backup. Stages off to the side, one atomic rename to
# the final name. INT/TERM re-raise to $BASHPID (not $$) so command
# substitution invocation terminates correctly — see spec.

# BSD/macOS realpath has no -m (GNU-only: resolve a path that may not
# exist yet). Same portable ancestor-walking replacement as
# config_block.sh's _kpi_config_block_realpath_m.
_kpi_backup_realpath_m() {
    local path="$1"
    if [ -e "$path" ]; then
        realpath "$path"
        return
    fi
    local dir base resolved_dir
    dir="$(dirname "$path")"
    base="$(basename "$path")"
    resolved_dir="$(_kpi_backup_realpath_m "$dir")"
    printf '%s/%s\n' "$resolved_dir" "$base"
}

backup_dir_timestamped() {
    local source="$1" backup_root="$2"

    if [ -n "$source" ] && [ -e "$source" ] && [ ! -d "$source" ]; then
        die "backup_dir_timestamped: source must be a directory or absent: $source"
    fi

    local have_source=0
    if [ -d "$source" ]; then
        have_source=1
        local rsource rroot
        rsource="$(realpath "$source")"
        rroot="$(_kpi_backup_realpath_m "$backup_root")"
        case "$rroot/" in
            "$rsource/"*) die "backup_dir_timestamped: backup_root is inside source" ;;
        esac
        case "$rsource/" in
            "$rroot/"*) die "backup_dir_timestamped: source is inside backup_root" ;;
        esac
    fi

    mkdir -p "$backup_root" || die "backup_dir_timestamped: cannot create backup_root: $backup_root"

    local staging=""
    local _kpi_prev_exit _kpi_prev_exit_cmd="" _kpi_prev_int _kpi_prev_term
    _kpi_prev_exit="$(trap -p EXIT)"
    _kpi_prev_int="$(trap -p INT)"
    _kpi_prev_term="$(trap -p TERM)"
    # See config_block.sh's _kpi_config_block_write: eval-ing the full
    # `trap -p` string only re-registers the prior trap, a no-op once it
    # fires from inside our own EXIT trap (the shell is already exiting).
    # Shadowing `trap` as a function while evaluating that string hands us
    # its bare command text instead, which we can actually execute here.
    if [ -n "$_kpi_prev_exit" ]; then
        # shellcheck disable=SC2329  # invoked indirectly: eval-ing
        # "$_kpi_prev_exit" (a `trap -- '...' EXIT` string) calls this
        # shadowed `trap` with the captured command as $2.
        _kpi_prev_exit_cmd="$(trap() { printf '%s' "$2"; }; eval "$_kpi_prev_exit")"
    fi

    trap 'rm -rf "$staging"; if [ -n "$_kpi_prev_exit_cmd" ]; then eval "$_kpi_prev_exit_cmd"; fi' EXIT
    trap 'rm -rf "$staging"; trap - INT; kill -INT "$BASHPID"' INT
    trap 'rm -rf "$staging"; trap - TERM; kill -TERM "$BASHPID"' TERM

    staging="$(mktemp -d "$backup_root/.kpi-backup.XXXXXX")" \
        || die "backup_dir_timestamped: mktemp -d failed in $backup_root"
    # Checked explicitly: an unchecked failure here would leave $staging
    # empty, and the cp/mv calls below would then operate on "" (which
    # resolves to the filesystem root in several of the path expressions
    # used elsewhere) instead of a real staging directory.

    if [ "$have_source" -eq 1 ]; then
        cp -fa "$source/." "$staging/" || die "backup_dir_timestamped: copy failed from $source"
    else
        log "backup_dir_timestamped: source does not exist, creating empty backup: $source"
    fi

    local base
    base="$backup_root/$(date +%Y_%m_%d-%H%M%S)"
    local final="$base"
    local n=2
    while [ -e "$final" ]; do
        final="${base}-${n}"
        n=$((n + 1))
    done

    mv "$staging" "$final" || die "backup_dir_timestamped: rename failed: $staging -> $final"
    staging=""

    trap - INT
    trap - TERM
    # Re-arming a caller's trap via the `trap` builtin only matters in the
    # shell that will actually reach its own exit later — this function's
    # documented calling convention is `dir="$(backup_dir_timestamped ...)"`,
    # which runs it inside a throwaway command-substitution subshell. Bash
    # does not auto-fire an inherited-but-never-(re)armed EXIT trap when
    # such a subshell terminates (verified by standalone repro), but it
    # DOES fire one that gets explicitly re-armed here via `trap ... EXIT`
    # — so unconditionally eval-ing the caller's prior trap string would
    # make it fire once here (spuriously, mid-caller-run) and again for
    # real at the caller's actual exit. $BASHPID == $$ only in a shell
    # that was never forked, so restore only there.
    if [ "$BASHPID" = "$$" ]; then
        if [ -n "$_kpi_prev_exit" ]; then
            eval "$_kpi_prev_exit"
        else
            trap - EXIT
        fi
        if [ -n "$_kpi_prev_int" ]; then eval "$_kpi_prev_int"; fi
        if [ -n "$_kpi_prev_term" ]; then eval "$_kpi_prev_term"; fi
    else
        trap - EXIT
    fi

    echo "$final"
}

backup_scrub_symlinks() {
    local backup_dir="$1" prefix="$2"
    local rprefix
    rprefix="$(realpath "$prefix")" || die "backup_scrub_symlinks: cannot resolve prefix: $prefix"

    local link rtarget
    while IFS= read -r -d '' link; do
        rtarget="$(realpath "$link" 2>/dev/null)" || continue  # dangling: leave untouched
        case "$rtarget" in
            "$rprefix") rm -f "$link" ;;
            "$rprefix"/*) rm -f "$link" ;;
        esac
    done < <(find "$backup_dir" -type l -print0)
}
