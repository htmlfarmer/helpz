#!/usr/bin/env bash
# ============================================================================
# lib/chart.sh - Text-mode chart & graph toolkit
# ============================================================================
# Every chart in the suite is drawn with these, so a bar in cpuz looks like a
# bar in diskz. Nothing here forks per-character: bars are built with
# printf string substitution, so a 60-row chart costs one fork, not sixty.
#
# Design rules:
#   * ANSI-aware — widths are measured with escapes stripped, so colour never
#     breaks alignment.
#   * Charts are TEXT. They are drawn whether or not stdout is a terminal;
#     only --json mode suppresses them entirely.
#   * Colour is emitted only when stdout is a tty (or CHART_FORCE_COLOR=1).
#   * Severity ramps are consistent everywhere: green → yellow → red.
#
# Sourced automatically by lib/common.sh. Safe to source standalone.
# ============================================================================

[[ -n "${_CHART_SH_LOADED:-}" ]] && return 0
_CHART_SH_LOADED=1

# ---------- capability detection ----------
chart_unicode() {   # 1 if we can print block glyphs
    [[ "${CHART_ASCII:-0}" == "1" ]] && return 1
    return 0
}

chart_width() {     # usable terminal width (capped, sane)
    local w="${COLUMNS:-}"
    [[ -z "$w" ]] && w=$(tput cols 2>/dev/null || echo 0)
    [[ "$w" =~ ^[0-9]+$ ]] || w=80
    (( w < 40 )) && w=40
    (( w > 120 )) && w=120
    printf '%s' "$w"
}

chart_suppressed() {  # 0 = draw charts; 1 = stay quiet (JSON mode)
    [[ "${JSON_OUT:-0}" -eq 1 ]] && return 0
    return 1
}

chart_color_ok() {
    [[ "${JSON_OUT:-0}" -eq 1 ]] && return 1
    [[ "${CHART_FORCE_COLOR:-0}" == "1" ]] && return 0
    [[ "${NO_COLOR:-0}" -eq 1 ]] && return 1
    [[ -t 1 ]] && return 0
    return 1
}

chart_c() {         # chart_c <color-name> — empty string when colour is off
    chart_color_ok || { printf ''; return 0; }
    case "$1" in
        red)     printf '\033[31m' ;;
        green)   printf '\033[32m' ;;
        yellow)  printf '\033[33m' ;;
        blue)    printf '\033[34m' ;;
        magenta) printf '\033[35m' ;;
        cyan)    printf '\033[36m' ;;
        white)   printf '\033[37m' ;;
        dim)     printf '\033[2m' ;;
        bold)    printf '\033[1m' ;;
        reset)   printf '\033[0m' ;;
        *)       printf '%s' "$1" ;;
    esac
}

# Visible width of a string (ANSI escapes removed).
chart_vlen() { awk -v s="${1-}" 'BEGIN{gsub(/\033\[[0-9;]*m/,"",s); print length(s)}'; }

# Severity ramp for a 0..100 "higher is worse" metric.
chart_sev() {       # chart_sev <pct>
    chart_color_ok || { printf ''; return 0; }
    local c
    c=$(awk -v x="${1:-0}" 'BEGIN{ if (x<60) print "green"; else if (x<85) print "yellow"; else print "red" }')
    chart_c "$c"
}

# Ramp for "lower is worse" metrics (free space %, free memory %).
chart_sev_low() {  # chart_sev_low <pct>
    chart_color_ok || { printf ''; return 0; }
    local c
    c=$(awk -v x="${1:-0}" 'BEGIN{ if (x>40) print "green"; else if (x>15) print "yellow"; else print "red" }')
    chart_c "$c"
}

# Fill / partial / empty glyphs — space separated so they can be read into
# three variables with a plain `read`.
chart_glyphs() {
    if chart_unicode; then printf '█ ▓ ░'; else printf '# - .'; fi
}

# Number formatting: integers stay integers.
chart_fmt_num() {
    local v="${1:-0}"
    case "$v" in
        ''|*[!0-9.eE+-]*) printf '%s' "$v" ;;
        *) awk -v x="$v" 'BEGIN{ if (x == int(x) && x < 1e15) printf "%d", x; else printf "%.2f", x }' ;;
    esac
}

# Build a run of one repeated character, without a fork.
chart_repeat() {   # chart_repeat <char> <count>
    local ch="$1" n="${2:-0}" out=""
    (( n <= 0 )) && { printf ''; return 0; }
    printf -v out '%*s' "$n" ''
    printf '%s' "${out// /$ch}"
}

# ---------- the workhorse: horizontal bar chart ----------
# Input:  "label<TAB>value" lines on stdin.
# Env:    CHART_WIDTH, CHART_LABEL_W, CHART_COLOR=auto|none|cycle
chart_hbars() {
    chart_suppressed && return 0
    local data; data=$(cat)
    [[ -z "$data" ]] && return 0

    local label_w=0 line max=0 val lbl
    while IFS=$'\t' read -r lbl val; do
        [[ -z "${val:-}" ]] && continue
        (( ${#lbl} > label_w )) && label_w=${#lbl}
        max=$(awk -v a="$max" -v b="$val" 'BEGIN{print (b+0>a+0)?b:a}')
    done <<< "$data"
    (( label_w > 28 )) && label_w=28

    local term_w; term_w=$(chart_width)
    local val_w=9
    local bar_w=$(( term_w - label_w - val_w - 6 ))
    (( bar_w < 8 )) && bar_w=8
    (( bar_w > 56 )) && bar_w=56

    local g_full g_part g_empty
    read -r g_full g_part g_empty <<< "$(chart_glyphs)"

    local idx=0
    while IFS=$'\t' read -r lbl val; do
        [[ -z "${val:-}" ]] && continue
        local filled
        filled=$(awk -v v="$val" -v m="$max" -v w="$bar_w" 'BEGIN{ if (m+0<=0) print 0; else { c=(v+0)/(m+0)*w; print (c<0)?0:((c>w)?w:int(c+0.5)) } }')
        local lbl_disp="$lbl"
        (( ${#lbl_disp} > label_w )) && lbl_disp="${lbl_disp:0:$((label_w-1))}…"
        local padsp; padsp=$(chart_repeat ' ' "$(( label_w - ${#lbl_disp} ))")
        local bar;   bar=$(chart_repeat "$g_full" "$filled")
        local emptysp; emptysp=$(chart_repeat "$g_empty" "$(( bar_w - filled ))")
        local valstr; valstr=$(chart_fmt_num "$val")
        local valpad=$(( val_w - ${#valstr} ))
        (( valpad < 0 )) && valpad=0
        local col=""
        case "${CHART_COLOR:-auto}" in
            none)  col="" ;;
            cycle) case $(( idx % 6 )) in
                        0) col=$(chart_c cyan) ;; 1) col=$(chart_c green) ;;
                        2) col=$(chart_c yellow) ;; 3) col=$(chart_c magenta) ;;
                        4) col=$(chart_c blue) ;; 5) col=$(chart_c cyan) ;;
                   esac ;;
            *)     col=$(chart_sev "$(awk -v v="$val" -v m="$max" 'BEGIN{print (m+0>0)? ((v+0)/(m+0))*100 : 0}')") ;;
        esac
        printf "  %s%s%s%s %s%s%s %s%s%s %s\n" \
            "$C_DIM" "$lbl_disp" "$C_RESET" "$padsp" \
            "$col" "$bar" "$C_RESET" \
            "$C_DIM" "$emptysp" "$C_RESET" \
            "$(chart_repeat ' ' "$valpad")$valstr"
        idx=$(( idx + 1 ))
    done <<< "$data"
}

# ---------- single labelled bar ----------
# chart_bar <label> <value> <max> [width]
chart_bar() {
    chart_suppressed && return 0
    local lbl="$1" val="$2" max="$3" w="${4:-24}"
    local filled
    filled=$(awk -v v="$val" -v m="$max" -v w="$w" 'BEGIN{ if (m+0<=0) print 0; else { c=(v+0)/(m+0)*w; print (c<0)?0:((c>w)?w:int(c+0.5)) } }')
    local g_full g_part g_empty
    read -r g_full g_part g_empty <<< "$(chart_glyphs)"
    printf "  %s %s%s%s\n" "$lbl" "$(chart_repeat "$g_full" "$filled")" \
        "$C_DIM" "$(chart_repeat "$g_empty" "$(( w - filled ))")" "$C_RESET"
}

# ---------- gauge / meter ----------
# chart_gauge <pct> [label] [width]
chart_gauge() {
    chart_suppressed && return 0
    local pct="${1:-0}" lbl="${2:-}" w="${3:-28}"
    [[ "$pct" =~ ^[0-9.]+$ ]] || pct=0
    local filled
    filled=$(awk -v p="$pct" -v w="$w" 'BEGIN{ c=(p/100)*w; print (c<0)?0:((c>w)?w:int(c+0.5)) }')
    local g_full g_part g_empty
    read -r g_full g_part g_empty <<< "$(chart_glyphs)"
    local col; col=$(chart_sev "$pct")
    if [[ -n "$lbl" ]]; then
        printf "  %s%-18s%s %s%s%s %s%s%s %s%5.1f%%%s\n" \
            "$C_DIM" "$lbl" "$C_RESET" \
            "$col" "$(chart_repeat "$g_full" "$filled")" "$C_RESET" \
            "$C_DIM" "$(chart_repeat "$g_empty" "$(( w - filled ))")" "$C_RESET" \
            "$C_BOLD" "$pct" "$C_RESET"
    else
        printf "  %s%s%s %s%s%s %s%5.1f%%%s\n" \
            "$col" "$(chart_repeat "$g_full" "$filled")" "$C_RESET" \
            "$C_DIM" "$(chart_repeat "$g_empty" "$(( w - filled ))")" "$C_RESET" \
            "$C_BOLD" "$pct" "$C_RESET"
    fi
}

# ---------- sparkline ----------
# chart_spark <v1> <v2> ...  — with a min/max/avg/last summary
chart_spark() {
    chart_suppressed && return 0
    local data="$*"
    [[ -z "$data" ]] && return 0
    local out
    out=$(printf '%s\n' $data | awk '
        BEGIN{ split("▁▂▃▄▅▆▇█", g, " "); n=0; mn=""; mx=""; sum=0 }
        $1 !~ /^-?[0-9.]+$/ { next }
        { n++; v[n]=$1+0; sum+=$1+0; if (mn=="" || v[n]<mn) mn=v[n]; if (mx=="" || v[n]>mx) mx=v[n] }
        END{
            if (n==0) { print "(no data)"; exit }
            s=""; for (i=1;i<=n;i++) { lvl = (mx==mn) ? 5 : int((v[i]-mn)/(mx-mn)*7)+1; s = s g[lvl] }
            printf "%s\n", s
            printf "min %g   max %g   avg %g   last %g\n", mn, mx, sum/n, v[n]
        }')
    printf "  %s%s%s\n" "$C_CYAN" "$(printf '%s\n' "$out" | head -1)" "$C_RESET"
    printf "  %s%s%s\n" "$C_DIM" "$(printf '%s\n' "$out" | tail -1)" "$C_RESET"
}

# ---------- histogram (vertical columns) ----------
# chart_hist <label> <count> [<label> <count> ...]
chart_hist() {
    chart_suppressed && return 0
    local args=("$@")
    (( ${#args[@]} == 0 )) && return 0
    local -a labels=() counts=()
    local i=0
    while (( i < ${#args[@]} )); do
        labels+=("${args[$i]}"); counts+=("${args[$((i+1))]:-0}"); i=$(( i + 2 ))
    done
    local max=0 n
    for n in "${counts[@]}"; do
        max=$(awk -v a="$max" -v b="$n" 'BEGIN{print (b+0>a+0)?b:a}')
    done
    (( max == 0 )) && return 0

    local h=8 w=22 label_w=0
    for n in "${labels[@]}"; do (( ${#n} > label_w )) && label_w=${#n}; done
    (( label_w > 24 )) && label_w=24

    local g_full g_part g_empty
    read -r g_full g_part g_empty <<< "$(chart_glyphs)"

    local row
    for (( row = h; row >= 1; row-- )); do
        local line=""
        for (( i = 0; i < ${#counts[@]}; i++ )); do
            local cells filled=0
            cells=$(awk -v c="${counts[$i]}" -v m="$max" -v hh="$h" 'BEGIN{print int(((c+0)/(m+0))*hh + 0.5)}')
            if (( row <= cells )); then
                filled=$(( cells >= h ? w : w * cells / h ))
            fi
            (( filled < 0 )) && filled=0
            (( filled > w )) && filled=$w
            line+="$(chart_repeat "$g_full" "$filled")$(chart_repeat "$g_empty" "$(( w - filled ))") "
        done
        printf "  %s%s%s\n" "$C_DIM" "$line" "$C_RESET"
    done
    for (( i = 0; i < ${#labels[@]}; i++ )); do
        local l="${labels[$i]}"
        (( ${#l} > label_w )) && l="${l:0:$((label_w-1))}…"
        printf "  %s%-*s%s %s%*s%s\n" "$C_DIM" "$label_w" "$l" "$C_RESET" \
            "$C_BOLD" "$w" "${counts[$i]}" "$C_RESET"
    done
}

# ---------- donut / ring ----------
# chart_donut <pct> [label]
# A 4-quadrant ring: the fill sweeps clockwise from 12 o'clock, each quadrant
# growing outward from its own corner, so 0% is empty, 50% is a half ring
# and 100% closes the circle.
chart_donut() {
    chart_suppressed && return 0
    local pct="${1:-0}" lbl="${2:-}"
    [[ "$pct" =~ ^[0-9.]+$ ]] || pct=0
    local col; col=$(chart_sev "$pct")

    # 28 eighths total, clockwise from 12 o'clock:
    #   q1 top-right · q2 bottom-right · q3 bottom-left · q4 top-left
    local q1 q2 q3 q4
    read -r q1 q2 q3 q4 <<< "$(awk -v p="$pct" 'BEGIN{
        u = p/100*28
        q1 = (u<7)?u:7;  u -= q1
        q2 = (u<7)?u:7;  u -= q2
        q3 = (u<7)?u:7;  u -= q3
        q4 = (u<0)?0:u
        printf "%.4f %.4f %.4f %.4f", q1, q2, q3, q4 }')"

    # A 4-row ring, 14 columns wide.
    local h_tl h_tr h_bl h_br v_tl v_tr v_bl v_br
    h_tr=$(chart_quad_right "$q1" 7)   # top-right horizontal, grows leftward
    h_br=$(chart_quad_right "$q2" 7)   # bottom-right horizontal
    h_bl=$(chart_quad_left  "$q3" 7)   # bottom-left horizontal, grows rightward
    h_tl=$(chart_quad_left  "$q4" 7)   # top-left horizontal
    v_tr=$(chart_quad_edge  "$q1")     # right edge, upper half
    v_br=$(chart_quad_edge  "$q2")     # right edge, lower half
    v_bl=$(chart_quad_edge  "$q3")     # left edge, lower half
    v_tl=$(chart_quad_edge  "$q4")     # left edge, upper half

    local gap; gap=$(chart_repeat ' ' 12)
    printf "  %s%s%s%s%s%s\n" "$col" "$h_tl" "$h_tr" "$C_RESET" "$C_DIM" "$C_RESET"
    printf "  %s%s%s%s%s%s\n" "$col" "$v_tl" "$gap" "$v_tr" "$C_RESET" "$C_DIM" "$C_RESET"
    printf "  %s%s%s%s%s%s\n" "$col" "$v_bl" "$gap" "$v_br" "$C_RESET" "$C_DIM" "$C_RESET"
    printf "  %s%s%s%s%s%s\n" "$col" "$h_bl" "$h_br" "$C_RESET" "$C_DIM" "$C_RESET"
    [[ -n "$lbl" ]] && printf "  %s%s%s %s%5.1f%%%s\n" "$C_BOLD" "$lbl" "$C_RESET" "$C_DIM" "$pct" "$C_RESET"
    return 0
}

# The partial-block glyph for a fractional eighth.
chart_partial_glyph() {
    case "$1" in
        0.1|0.2|0.3) printf '▏' ;;
        0.4)         printf '▎' ;;
        0.5|0.6)     printf '▌' ;;
        0.7)         printf '▋' ;;
        0.8|0.9)     printf '▊' ;;
        *)           printf '' ;;
    esac
}

# Left-aligned quadrant fill: full blocks, then a partial block, then spaces.
chart_quad_left() {   # chart_quad_left <eighths> <width>
    local units="${1:-0}" w="${2:-7}"
    local full=${units%%.*} frac=${units#*.}
    [[ "$frac" == "$units" ]] && frac=0
    local out="" i=0
    while (( i < full && i < w )); do out+="█"; i=$(( i + 1 )); done
    local pg; pg=$(chart_partial_glyph "$frac")
    if [[ -n "$pg" && $i -lt $w ]]; then out+="$pg"; i=$(( i + 1 )); fi
    while (( i < w )); do out+=" "; i=$(( i + 1 )); done
    printf '%s' "$out"
}

# Right-aligned quadrant fill: spaces, then a partial block, then full blocks.
chart_quad_right() {  # chart_quad_right <eighths> <width>
    local units="${1:-0}" w="${2:-7}"
    local full=${units%%.*} frac=${units#*.}
    [[ "$frac" == "$units" ]] && frac=0
    local out="" i=0
    while (( i < full && i < w )); do out+="█"; i=$(( i + 1 )); done
    local pg; pg=$(chart_partial_glyph "$frac")
    if [[ -n "$pg" && $i -lt $w ]]; then out+="$pg"; i=$(( i + 1 )); fi
    local pad=$(( w - i ))
    while (( pad > 0 )); do out+=" "; pad=$(( pad - 1 )); done
    printf '%s' "$out"
}

# One vertical edge segment: a block when the quadrant has a full eighth,
# a partial block while it is still filling, otherwise blank.
chart_quad_edge() {  # chart_quad_edge <eighths>
    local units="${1:-0}"
    local full=${units%%.*} frac=${units#*.}
    [[ "$frac" == "$units" ]] && frac=0
    if (( full >= 1 )); then printf '█'; return 0; fi
    local pg; pg=$(chart_partial_glyph "$frac")
    [[ -n "$pg" ]] && printf '%s' "$pg" || printf ' '
}

# ---------- heatmap grid ----------
# chart_heat <label> <v1> <v2> ... — block grid with a 4-step ramp
chart_heat() {
    chart_suppressed && return 0
    local lbl="${1:-}"; shift
    local vals=("$@")
    (( ${#vals[@]} == 0 )) && return 0
    local min="" max="" v
    for v in "${vals[@]}"; do
        [[ "$v" =~ ^-?[0-9.]+$ ]] || continue
        if [[ -z "$min" ]]; then min=$v; max=$v; continue; fi
        min=$(awk -v a="$min" -v b="$v" 'BEGIN{print (b+0<a+0)?b:a}')
        max=$(awk -v a="$max" -v b="$v" 'BEGIN{print (b+0>a+0)?b:a}')
    done
    [[ -z "$min" ]] && return 0
    local line=""
    for v in "${vals[@]}"; do
        local lvl=1
        if [[ "$v" =~ ^-?[0-9.]+$ ]]; then
            lvl=$(awk -v x="$v" -v a="$min" -v b="$max" 'BEGIN{ if (b+0==a+0) print 4; else print int(((x+0-a+0)/(b+0-a+0))*3)+1 }')
        fi
        case "$lvl" in
            1) line+="░" ;; 2) line+="▒" ;; 3) line+="▓" ;; *) line+="█" ;;
        esac
    done
    printf "  %s%-12s%s %s%s%s\n" "$C_DIM" "$lbl" "$C_RESET" "$C_CYAN" "$line" "$C_RESET"
}

# ---------- KPI cards in a grid (3 per row) ----------
# chart_kpi_grid <<< "label<TAB>value<TAB>color"
chart_kpi_grid() {
    chart_suppressed && return 0
    local data; data=$(cat)
    [[ -z "$data" ]] && return 0
    local lbl val col line="" n=0
    while IFS=$'\t' read -r lbl val col; do
        [[ -z "${lbl:-}" ]] && continue
        local c
        case "$col" in
            red|green|yellow|blue|magenta|cyan|white) c=$(chart_c "$col") ;;
            *) c=$(chart_c cyan) ;;
        esac
        line+="$(printf '%s%-13s%s %s%-9s%s  ' "$C_DIM" "$lbl" "$C_RESET" "$c" "${val:-—}" "$C_RESET")"
        n=$(( n + 1 ))
        (( n % 3 == 0 )) && { printf "  %s\n" "$line"; line=""; }
    done <<< "$data"
    [[ -n "$line" ]] && printf "  %s\n" "$line"
    return 0
}

# ---------- ranked top-N ----------
# chart_rank <n> <<< "label<TAB>value"
chart_rank() {
    chart_suppressed && return 0
    local n="${1:-10}"
    local data; data=$(cat)
    [[ -z "$data" ]] && return 0
    printf '%s\n' "$data" | sort -t$'\t' -k2 -gr | head -n "$n" | \
    while IFS=$'\t' read -r lbl val; do
        [[ -z "${lbl:-}" ]] && continue
        local medal="  "
        case "$val" in
            1) medal="🥇" ;; 2) medal="🥈" ;; 3) medal="🥉" ;;
        esac
        printf "  %s%s%-24s%s %s%10s%s\n" "$medal" "$C_BOLD" "$lbl" "$C_RESET" "$C_CYAN" "$val" "$C_RESET"
    done
}

# ---------- timeline ----------
# chart_timeline <<< "label<TAB>timestamp"
chart_timeline() {
    chart_suppressed && return 0
    local data; data=$(cat)
    [[ -z "$data" ]] && return 0
    local lbl ts
    while IFS=$'\t' read -r lbl ts; do
        [[ -z "${lbl:-}" ]] && continue
        printf "  %s│%s %s●%s %s%s%s %s%s%s\n" \
            "$C_DIM" "$C_RESET" "$C_CYAN" "$C_RESET" \
            "$C_BOLD" "$lbl" "$C_RESET" "$C_DIM" "${ts:-}" "$C_RESET"
        printf "  %s│%s\n" "$C_DIM" "$C_RESET"
    done <<< "$data"
}

# ---------- legend ----------
chart_legend() {   # chart_legend <<< "color<TAB>label"
    chart_suppressed && return 0
    local col lbl line=""
    while IFS=$'\t' read -r col lbl; do
        [[ -z "${lbl:-}" ]] && continue
        line+="$(chart_c "$col")●${C_RESET} ${lbl}   "
    done
    printf "  %s\n" "$line"
}

# ---------- progress line ----------
chart_progress() {  # chart_progress <pct> [label]
    chart_suppressed && return 0
    chart_gauge "${1:-0}" "${2:-}" 30
}
