#!/bin/bash
# prompt.sh — Interactive Prompts. Bounded retry (3 attempts), EOF and
# no-tty both fall back to $default (or die if none) — never blocks,
# never loops forever. See spec.

confirm_yn() {
    local prompt="$1" default="${2:-}"

    if [ -n "$default" ] && [[ "$default" != [yYnN] ]]; then
        die "confirm_yn: invalid default: $default"
    fi

    local hint="(y/n)"
    case "$default" in
        [yY]) hint="(Y/n)" ;;
        [nN]) hint="(y/N)" ;;
    esac

    if [ -z "${_KPI_INPUT_FD:-}" ]; then
        if [ -z "$default" ]; then
            die "confirm_yn: no interactive input available and no default given"
        fi
        log "non-interactive environment, using default: $default"
        [[ "$default" =~ [yY] ]] && return 0 || return 1
    fi

    local attempt=1 answer
    while [ "$attempt" -le 3 ]; do
        log "$prompt $hint"
        if ! IFS= read -u "$_KPI_INPUT_FD" -r answer; then
            answer="__EOF__"
        fi

        if [ -z "$answer" ] && [ -n "$default" ]; then
            answer="$default"
        fi

        case "$answer" in
            [yY] | [yY][eE][sS]) return 0 ;;
            [nN] | [nN][oO]) return 1 ;;
            "__EOF__") break ;;
            *)
                log "please answer y or n"
                attempt=$((attempt + 1))
                ;;
        esac
    done

    if [ -n "$default" ]; then
        log "no valid response, using default: $default"
        [[ "$default" =~ [yY] ]] && return 0 || return 1
    fi
    die "confirm_yn: no valid response and no default given"
}

select_from_dir() {
    local -x LC_ALL=C
    local prompt="$1" dir="$2" glob="$3"

    local -a files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$dir" -maxdepth 1 -type f -name "$glob" -print0 2>/dev/null | sort -z)

    if [ "${#files[@]}" -eq 0 ]; then
        log "select_from_dir: no files match $glob in $dir"
        return 1
    fi

    if [ -z "${_KPI_INPUT_FD:-}" ]; then
        log "non-interactive environment, skipping selection: $prompt"
        return 1
    fi

    local i display
    log "$prompt"
    log "  0) skip"
    for i in "${!files[@]}"; do
        display="$(basename "${files[$i]}")"
        display="${display%.*}"
        display="${display//_/ }"
        display="${display//-/ }"
        log "  $((i + 1))) $display"
    done

    local attempt=1 choice
    while [ "$attempt" -le 3 ]; do
        if ! IFS= read -u "$_KPI_INPUT_FD" -r choice; then
            log "select_from_dir: no more input, skipping"
            return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if [ "$choice" -eq 0 ]; then
                return 1
            elif [ "$choice" -ge 1 ] && [ "$choice" -le "${#files[@]}" ]; then
                echo "${files[$((choice - 1))]}"
                return 0
            fi
        fi
        log "please enter a number between 0 and ${#files[@]}"
        attempt=$((attempt + 1))
    done

    log "select_from_dir: no valid selection, skipping"
    return 1
}
