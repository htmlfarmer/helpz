#!/usr/bin/env bash
# ============================================================================
# lib/hist.sh — per-run metric history ("what are the common values?")
# ----------------------------------------------------------------------------
# run_comparison.sh already keeps the LAST run of every tool. This keeps the
# numbers behind every run, forever, so a run can be judged against what is
# normal for this machine instead of against only the run before it.
#
# Every finished run appends ONE line to
#
#     ~/.security-runs/history/<tool>.jsonl
#
#   {
#     "ts": 1794693000,            <- meta: when
#     "date": "2026-11-14 12:03:49 PST",
#     "tool": "slowz",             <- which command
#     "boot": "3a082930-...",      <- which boot it ran during
#     "boot_start": "2026-11-14 11:59:02",
#     "host": "ashy", "kernel": "7.3.4-kz", "uptime_s": 287,
#     "m": {                       <- metrics: the numbers
#       ...a snapshot EVERY tool shares (load, mem, swap, disk, PSI,
#          failed units, verdict counts, duration)...
#       ...plus whatever the tool registered with hist_metric()...
#     }
#   }
#
# Usage from a tool:
#
#   hist_metric score 85          # register a tool-specific number
#                                 # (any time before run_comparison_finalize)
#   hist_secs "1min 2.5s"         # helper: systemd duration -> seconds
#
# hist_record() is called by lib/run_comparison.sh, so a tool that already
# calls run_comparison_init/finalize gets history for free — no edits.
#
# Env knobs:
#   HIST_ENABLED=0        stop recording
#   SECURITY_HIST_DIR=..  move the history (default ~/.security-runs/history)
#   HIST_MAX_LINES=500    cap per tool file (oldest lines are dropped)
#   HIST_WINDOW=50        "common" = median of the last N runs (trendz reads)
#
# Read by: ./trendz
# ============================================================================

[[ -n "${_HIST_SH_LOADED:-}" ]] && return 0
_HIST_SH_LOADED=1

HIST_DIR="${SECURITY_HIST_DIR:-${COMPARISON_DIR:-$HOME/.security-runs}/history}"
HIST_ENABLED="${HIST_ENABLED:-1}"
HIST_MAX_LINES="${HIST_MAX_LINES:-500}"
HIST_WINDOW="${HIST_WINDOW:-50}"

declare -A _HIST_METRICS=()   # tool-registered, this run only
declare -A _HIST_AUTO=()      # shared system snapshot, this run only

# ---------- registration ----------
# hist_metric <key> <number> — record a tool-specific value for this run.
# Keys must be plain identifiers, values must be plain numbers: anything else
# is silently dropped rather than allowed to corrupt a history line.
hist_metric() {
    [[ "${HIST_ENABLED}" == "1" ]] || return 0
    local k="${1:-}" v="${2:-}"
    [[ -n "$k" && -n "$v" ]] || return 0
    [[ "$k" =~ ^[a-z][a-z0-9_]*$ ]] || return 0
    [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || return 0
    _HIST_METRICS["$k"]="$v"
    return 0
}

# hist_secs "<duration>" → integer seconds. Accepts what systemd prints:
#   "45.2s"  "1min 2.345s"  "2h"  "1min"  "350ms"
hist_secs() {
    local raw="${1:-}"
    [[ -z "$raw" ]] && return 1
    awk -v s="$raw" 'BEGIN {
        n = split(s, a, /[ \t]+/)
        tot = 0
        for (i = 1; i <= n; i++) {
            t = a[i]
            if (t == "") continue
            num = t; sub(/[^0-9.].*$/, "", num)
            if (num == "") continue
            unit = t; sub(/^[0-9.]+/, "", unit)
            if      (unit == "ms")            tot += num / 1000
            else if (unit == ""  || unit == "s"  || unit == "sec")   tot += num
            else if (unit == "m"  || unit == "min") tot += num * 60
            else if (unit == "h"  || unit == "hr")  tot += num * 3600
            else if (unit == "d")             tot += num * 86400
        }
        printf "%d\n", tot
    }'
}

# ---------- shared snapshot ----------
# The values every tool has in common, so any tool's history can be compared
# with any other's (and with the boot it ran in).
_hist_snapshot() {
    _HIST_AUTO=()
    local k v l1 l5 l15 _rest

    if read -r l1 l5 l15 _rest < /proc/loadavg 2>/dev/null; then
        [[ "$l1"  =~ ^[0-9.]+$ ]] && _HIST_AUTO[load1]="$l1"
        [[ "$l5"  =~ ^[0-9.]+$ ]] && _HIST_AUTO[load5]="$l5"
        [[ "$l15" =~ ^[0-9.]+$ ]] && _HIST_AUTO[load15]="$l15"
    fi

    # memory + swap in one pass over /proc/meminfo
    while IFS='=' read -r k v; do
        [[ -n "$k" && "$v" =~ ^[0-9]+$ ]] && _HIST_AUTO["$k"]="$v"
    done < <(awk '
        /^MemTotal:/     { mt = $2 }
        /^MemAvailable:/ { ma = $2 }
        /^SwapTotal:/    { st = $2 }
        /^SwapFree:/     { sf = $2 }
        END {
            if (mt > 0) printf "mem_pct=%d\n", (mt - ma) * 100 / mt
            if (st > 0) printf "swap_pct=%d\n", (st - sf) * 100 / st
        }' /proc/meminfo 2>/dev/null)

    # root filesystem fill level
    local dp
    dp=$(df -P / 2>/dev/null | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')
    [[ "$dp" =~ ^[0-9]+$ ]] && _HIST_AUTO[disk_pct]="$dp"

    # pressure stall information — the "is anything actually waiting?" numbers
    while IFS='=' read -r k v; do
        [[ -n "$k" && "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] && _HIST_AUTO["$k"]="$v"
    done < <(for pf in cpu io memory; do
                 [[ -r "/proc/pressure/$pf" ]] || continue
                 awk -v n="$pf" '$1 == "some" {
                     for (i = 2; i <= NF; i++)
                         if ($i ~ /^avg10=/) { split($i, b, "="); printf "psi_%s=%.1f\n", n, b[2] + 0; exit }
                 }' "/proc/pressure/$pf" 2>/dev/null
             done)

    # units in the failed state (systemd only, and never hang on it)
    local fu=""
    if command -v systemctl >/dev/null 2>&1; then
        fu=$( (timeout 3 systemctl --failed --no-pager --no-legend 2>/dev/null || true) | grep -c . )
        [[ "$fu" =~ ^[0-9]+$ ]] && _HIST_AUTO[failed_units]="$fu"
    fi

    # the verdict this run reached, and how long it took to reach it
    [[ "${CRITICAL:-0}" =~ ^[0-9]+$ ]] && _HIST_AUTO[crit]="${CRITICAL:-0}"
    [[ "${WARNINGS:-0}"  =~ ^[0-9]+$ ]] && _HIST_AUTO[warn]="${WARNINGS:-0}"
    local now start
    now=$(date +%s)
    start="${START_TS:-${START_TIME:-}}"
    if [[ "$start" =~ ^[0-9]+$ ]] && (( start <= now )); then
        _HIST_AUTO[dur]=$(( now - start ))
    fi

    return 0
}

# ---------- JSON string safety ----------
_hist_str() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# ---------- recording ----------
# hist_record <tool> — append this run's line, then prune the file.
# Called by run_comparison_finalize, so it must never fail loudly, never write
# to stdout (that is still teed into the run capture) and never trip `set -e`.
hist_record() {
    local tool="${1:-}"
    [[ "${HIST_ENABLED}" == "1" ]] || return 0
    [[ -n "$tool" ]] || tool="${0##*/}"
    [[ "$tool" =~ ^[A-Za-z0-9._-]+$ ]] || return 0
    mkdir -p "$HIST_DIR" 2>/dev/null || return 0

    _hist_snapshot

    local ts date_s boot boot_start host kernel up
    ts=$(date +%s)
    date_s=$(date '+%Y-%m-%d %H:%M:%S %Z')
    boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    boot_start=$(uptime -s 2>/dev/null)
    host=$(hostname -s 2>/dev/null)
    kernel=$(uname -r 2>/dev/null)
    up=$(awk '{ printf "%d", $1 }' /proc/uptime 2>/dev/null)
    [[ "$up" =~ ^[0-9]+$ ]] || up=0
    [[ -z "$boot" ]]       && boot="unknown"
    [[ -z "$boot_start" ]] && boot_start="unknown"
    [[ -z "$host" ]]       && host="host"
    [[ -z "$kernel" ]]     && kernel="unknown"

    # merge the shared snapshot with whatever this tool registered
    local -a kv=() k
    for k in "${!_HIST_AUTO[@]}";    do kv+=("\"$k\":${_HIST_AUTO[$k]}"); done
    for k in "${!_HIST_METRICS[@]}"; do kv+=("\"$k\":${_HIST_METRICS[$k]}"); done
    local mjson=""
    (( ${#kv[@]} > 0 )) && mjson=$(IFS=,; printf '%s' "${kv[*]}")

    local file="$HIST_DIR/$tool.jsonl"
    printf '{"ts":%s,"date":"%s","tool":"%s","boot":"%s","boot_start":"%s","host":"%s","kernel":"%s","uptime_s":%s,"m":{%s}}\n' \
        "$ts" \
        "$(_hist_str "$date_s")" \
        "$(_hist_str "$tool")" \
        "$(_hist_str "$boot")" \
        "$(_hist_str "$boot_start")" \
        "$(_hist_str "$host")" \
        "$(_hist_str "$kernel")" \
        "$up" \
        "$mjson" >> "$file" 2>/dev/null || return 0

    # keep the file bounded: one line per run, at most HIST_MAX_LINES of them
    local n tmp
    n=$(wc -l < "$file" 2>/dev/null || echo 0)
    if [[ "$n" =~ ^[0-9]+$ ]] && (( n > HIST_MAX_LINES )); then
        tmp=$(mktemp "$HIST_DIR/.hist.XXXXXX" 2>/dev/null) || return 0
        if tail -n "$HIST_MAX_LINES" "$file" > "$tmp" 2>/dev/null; then
            mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
        else
            rm -f "$tmp" 2>/dev/null
        fi
    fi

    # a second finalize must not double-register the same values
    _HIST_METRICS=()
    return 0
}
