#!/usr/bin/env bash
# ============================================================================
# lib/duration.sh - Shared duration parsing for --last / --since style options
# ============================================================================
# journalctl understands "2 hours ago" but NOT "2hr" or "2h ago". Tools that
# accept a friendly duration shorthand have to translate it. This is the one
# place that translation lives, so every tool understands the same spellings
# and phrases them the same way ("1 hour ago", not "1 hours ago").
#
# Sourced by lib/common.sh (so logz gets it) and directly by printerz.
# No side effects — safe to source from anywhere.
# ============================================================================

[[ -n "${_DURATION_SH_LOADED:-}" ]] && return 0
_DURATION_SH_LOADED=1

# _dur_plural <count> <unit-singular>  →  "1 hour ago" / "3 hours ago"
_dur_plural() {
    local n="$1" unit="$2"
    if [[ "$n" == "1" ]]; then
        printf '1 %s ago' "$unit"
    else
        printf '%s %ss ago' "$n" "$unit"
    fi
}

# duration_ago <spec>  →  "N unit ago" on stdout
#   Returns 1 (and prints nothing) when the spec cannot be parsed.
#
# Accepted specs:
#   bare number          → minutes            (10  ==  10min)
#   NUM + unit suffix, case-insensitive, pluralisation optional:
#     s  sec  secs  second  seconds
#     m  min  mins  minute  minutes
#     h  hr  hrs  hour   hours          ← "1hr" is the one people reach for
#     d  day  days
#     w  wk  wks  week   weeks
duration_ago() {
    local raw="${1:-}"
    local v="${raw,,}"
    v="${v// /}"
    [[ -z "$v" ]] && return 1

    if [[ "$v" =~ ^([0-9]+)$ ]]; then
        _dur_plural "${BASH_REMATCH[1]}" "minute"
        return 0
    fi

    if [[ ! "$v" =~ ^([0-9]+)([a-z]+)$ ]]; then
        return 1
    fi
    local num="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"

    case "$unit" in
        s|sec|secs|second|seconds) _dur_plural "$num" "second" ;;
        m|min|mins|minute|minutes) _dur_plural "$num" "minute" ;;
        h|hr|hrs|hour|hours)       _dur_plural "$num" "hour" ;;
        d|day|days)                _dur_plural "$num" "day" ;;
        w|wk|wks|week|weeks)       _dur_plural "$num" "week" ;;
        *) return 1 ;;
    esac
    return 0
}

# duration_hint — the example list shown when a duration fails to parse.
duration_hint() {
    printf 'try: 30s  5min  1hr  2h  1d  1w   (bare numbers mean minutes)'
}
