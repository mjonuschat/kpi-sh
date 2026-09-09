#!/bin/bash
# path.sh — Path Utilities. abspath is purely lexical (never follows
# symlinks); functions elsewhere that need symlink-aware resolution use
# realpath/realpath -m directly instead. See spec "path.sh" section.

abspath() {
    local path="$1"
    if [ -z "$path" ]; then
        die "abspath: empty path"
    fi

    if [[ "$path" != /* ]]; then
        path="$PWD/$path"
    fi

    local -a parts=()
    IFS='/' read -ra parts <<< "$path"
    # `read -ra` splits on IFS without performing pathname expansion, unlike
    # an unquoted `parts=($path)` — that would glob-expand a literal `*` in
    # the path and word-split on embedded spaces. This does neither.

    local -a stack=()
    local part
    for part in "${parts[@]}"; do
        case "$part" in
            "" | ".") continue ;;
            "..")
                if ((${#stack[@]} > 0)); then
                    # Bash 4.0 compat: negative array indices (stack[-1])
                    # require Bash 4.2+. Compute the last index arithmetically
                    # instead — this is the same class of version-floor bug
                    # the spec review already caught once (dynamic fd alloc).
                    unset "stack[$((${#stack[@]} - 1))]"
                fi
                ;;
            *) stack+=("$part") ;;
        esac
    done

    if ((${#stack[@]} == 0)); then
        echo "/"
    else
        local result="" s
        for s in "${stack[@]}"; do
            result="$result/$s"
        done
        echo "$result"
    fi
}

script_dir() {
    # BASH_SOURCE[-1] (negative array indexing) requires Bash 4.2+; this
    # spec's floor is 4.0, so the last frame is computed arithmetically —
    # ${#BASH_SOURCE[@]}-1 — instead of using the shorter negative-index
    # syntax the design doc's prose mentions.
    local n="${#BASH_SOURCE[@]}"
    if [ "$n" -eq 0 ]; then
        die "script_dir: no BASH_SOURCE available (not running from a file)"
    fi
    # ${#BASH_SOURCE[@]} is never actually 0 in practice once any function
    # is executing — bash always populates at least one frame, using the
    # literal placeholder "bash" for code with no real file backing (e.g.
    # a function defined via `eval` rather than `source`). The check above
    # is defensive; this is the check that actually fires for "no
    # meaningful script directory."
    local top="${BASH_SOURCE[$((n - 1))]}"
    if [ ! -f "$top" ]; then
        die "script_dir: no real entrypoint script file backs this call: $top"
    fi
    abspath "$(dirname "$top")"
}
