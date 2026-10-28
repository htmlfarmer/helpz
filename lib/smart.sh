#!/usr/bin/env bash
# ============================================================================
# lib/smart.sh — Shared SMART drive-health collector & evaluator (NVMe + ATA)
# ----------------------------------------------------------------------------
# One parser for both tools:
#   • diskz  → full drive report (smart_collect + smart_table + smart_findings)
#   • crashz → crash-relevant signals only, with a hook (SMART_UNSAFE_HOOK)
#     that folds unsafe_shutdowns into its Unclean / freeze evidence.
#   • smart_parse_text_stream → reads PASTED `smartctl -A` output (e.g. from
#     another machine's terminal) and runs the same evaluation rules.
#
# The key crash signal: unsafe_shutdowns vs power_cycles — every unsafe entry
# is one session that ended WITHOUT a clean shutdown: i.e. your freeze.
#
# Provides:
#   smart_available            → 0 when smartctl + jq + lsblk exist
#   smart_collect              → fills SMART_ROWS (TSV per physical disk)
#   smart_table                → renders via common.sh table_* when available
#   smart_dump                 → plain-text rows (for evidence bundles)
#   smart_findings             → critf/warnf per drive (DiskIO/Unclean/Thermal)
#   smart_parse_text_stream L  → evaluate pasted smartctl text on stdin
#   smart_decode_critwarn N    → NVMe critical_warning bit text
#
# SMART_ROWS fields (\x1f-separated, 18 cols — non-whitespace delimiter so
#   empty fields survive bash read without collapsing):
#   0 dev  1 kind  2 model  3 health  4 tempC  5 used%  6 spare%  7 spare_thresh
#   8 unsafe_shut  9 media_err  10 realloc  11 pending  12 crc  13 uncorrectable
#   14 power_on_h  15 power_cycles  16 err_log_entries  17 critical_warning
# Empty string = not applicable for this drive kind; "?" = unknown/needs sudo.
#
# Requires: smartctl (smartmontools), jq, lsblk. All calls guarded.
# ============================================================================

declare -a SMART_ROWS=()
SMART_SCANNED=0
SMARTCTL_BIN=""
SMART_UNSAFE_HOOK="${SMART_UNSAFE_HOOK:-}"   # optional: fn dev count

_smart_find_bin() {
    [[ -n "$SMARTCTL_BIN" ]] && return 0
    local c
    for c in smartctl /usr/sbin/smartctl /sbin/smartctl; do
        if command -v "$c" >/dev/null 2>&1; then
            SMARTCTL_BIN=$(command -v "$c")
            return 0
        fi
    done
    return 1
}

smart_available() {
    _smart_find_bin && command -v jq >/dev/null 2>&1 && command -v lsblk >/dev/null 2>&1
}

smart_collect() {
    SMART_ROWS=(); SMART_SCANNED=0
    smart_available || return 1
    local dev out
    while IFS= read -r dev; do
        [[ -z "$dev" ]] && continue
        out=$(timeout 15 "$SMARTCTL_BIN" -j "$dev" 2>/dev/null | jq -r --arg dev "$dev" '
            [ (.device_name // $dev),
              (if .nvme_smart_health_information_log then "NVMe"
               elif .ata_smart_attributes then "ATA" else "?" end),
              ((.model_name // .serial_number // "?") | gsub("[\t\n]";" ")),
              (.smart_status.passed | if . == null then "?" elif . then "PASSED" else "FAILED" end),
              ((.temperature.current // .nvme_smart_health_information_log.temperature // "?") | tostring),
              ((.nvme_smart_health_information_log.percentage_used // "") | tostring),
              ((.nvme_smart_health_information_log.available_spare // "") | tostring),
              ((.nvme_smart_health_information_log.available_spare_threshold // "") | tostring),
              ((.nvme_smart_health_information_log.unsafe_shutdowns // "") | tostring),
              ((.nvme_smart_health_information_log.media_errors // "") | tostring),
              ([(.ata_smart_attributes.table[]? | select(.id==5)  | .raw.value)] | (.[0] // 0) | tostring),
              ([(.ata_smart_attributes.table[]? | select(.id==197) | .raw.value)] | (.[0] // 0) | tostring),
              ([(.ata_smart_attributes.table[]? | select(.id==199) | .raw.value)] | (.[0] // 0) | tostring),
              ([(.ata_smart_attributes.table[]? | select(.id==198) | .raw.value)] | (.[0] // 0) | tostring),
              ((.power_on_time.hours // "") | tostring),
              ((.power_cycle_count // "") | tostring),
              ((.nvme_smart_health_information_log.num_err_log_entries // "") | tostring),
              ((.nvme_smart_health_information_log.critical_warning // 0) | tostring)
            ] | join("\u001f")
        ' 2>/dev/null) || out=""
        # smartctl failed outright (usually permissions): placeholder row
        if [[ -z "$out" ]]; then
            out=$(printf '%s\u001f?\u001funreadable (needs sudo?)\u001f?\u001f?\u001f\u001f\u001f\u001f\u001f\u001f\u001f\u001f\u001f\u001f\u001f\u001f\u001f0' "$dev")
        fi
        SMART_ROWS+=("$out")
    done < <(lsblk -dnrpo NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 ~ /\/(nvme[0-9]+n[0-9]+|sd[a-z]+|vd[a-z]+|mmcblk[0-9]+)$/ {print $1}')
    (( ${#SMART_ROWS[@]} > 0 )) && SMART_SCANNED=1
    (( SMART_SCANNED ))
}

smart_decode_critwarn() {
    local n="${1:-0}" out=""
    (( n & 1 )) && out+="spare below threshold, "
    (( n & 2 )) && out+="reliability degraded, "
    (( n & 4 )) && out+="read-only mode, "
    (( n & 8 )) && out+="volatile memory backup failed, "
    (( n & 16 )) && out+="runtime-bad-PMU, "
    printf '%s' "${out%, }"
}

smart_num() { [[ "$1" =~ ^[0-9]+$ ]] && printf '%s' "$1" || printf '%s' "-"; }

smart_table() {
    [[ "${JSON_OUT:-0}" -eq 1 ]] && return 0
    declare -F table_begin >/dev/null 2>&1 || return 0
    local row dev kind model health temp used spare spareth unsafe merr realloc pending crc uncorr poh pc errlog critwarn
    local wear spare_disp unsafe_s merr_s note_r temp_disp
    table_begin "DEVICE" "KIND" "MODEL" "HEALTH" "TEMP" "WEAR" "SPARE" "UNSAFE-SHUT" "MEDIA-ERR" "REALLOC/PEND/CRC" "POWER-ON h"
    for row in "${SMART_ROWS[@]}"; do
        IFS=$'\x1f' read -r dev kind model health temp used spare spareth unsafe merr realloc pending crc uncorr poh pc errlog critwarn <<< "$row"
        if [[ "$used" =~ ^[0-9]+$ ]]; then wear="${used}%"; else wear="-"; fi
        if [[ "$spare" =~ ^[0-9]+$ ]]; then spare_disp="${spare}%"; else spare_disp="-"; fi
        unsafe_s="$(smart_num "$unsafe")"
        merr_s="$(smart_num "$merr")"
        if [[ "$kind" == "ATA" ]]; then note_r="${realloc:-0}/${pending:-0}/${crc:-0}"; else note_r="-"; fi
        if [[ "$temp" =~ ^[0-9]+$ ]]; then temp_disp="${temp}°C"; else temp_disp="?"; fi
        [[ "$health" == "FAILED" ]] && health="${C_RED:-}FAILED${C_RESET:-}"
        table_row "$dev" "${kind:-?}" "$(printf '%.24s' "${model:-?}")" "${health:-?}" "$temp_disp" \
            "$wear" "$spare_disp" "$unsafe_s" "$merr_s" "$note_r" "$(smart_num "$poh")"
    done
    table_end
}

smart_dump() {
    local row
    for row in "${SMART_ROWS[@]}"; do
        printf '%s\n' "$row" | awk -F'\037' '{printf "%s [%s] %s health=%s temp=%s used=%s spare=%s unsafe_shut=%s media_err=%s realloc/pending/crc=%s/%s/%s power_on_h=%s crit_warn=%s\n", $1,$2,$3,$4,$5,$6,$7,$9,$10,$11,$12,$13,$15,$18}'
    done
}

# _smart_eval — one evaluation engine, rows AND pasted text feed into it
# args: dev kind model health temp used spare spareth unsafe merr realloc
#       pending crc uncorr poh pc errlog critwarn
_smart_eval() {
    local dev="$1" kind="$2" model="$3" health="$4" temp="$5" used="$6" spare="$7" spareth="$8" \
          unsafe="$9" merr="${10}" realloc="${11}" pending="${12}" crc="${13}" uncorr="${14}" \
          poh="${15}" pc="${16}" errlog="${17}" critwarn="${18}"
    [[ "$kind" == "?" ]] && return 0

    if [[ "$health" == "FAILED" ]]; then
        _sf_crit "DiskIO" "$dev ($model) SMART overall-health self-assessment: FAILED — the drive predicts its own death" \
            "Back up today, replace the drive. Evidence: sudo ${SMARTCTL_BIN:-smartctl} -a $dev"
    fi
    if [[ "$kind" == "NVMe" && "$critwarn" =~ ^[0-9]+$ && "$critwarn" != "0" ]]; then
        _sf_crit "DiskIO" "$dev NVMe critical_warning=${critwarn} — $(smart_decode_critwarn "$critwarn")" \
            "Drive-internal emergency flag. Back up NOW; check warranty: sudo ${SMARTCTL_BIN:-smartctl} -a $dev"
    fi
    if { [[ "$merr" =~ ^[0-9]+$ ]] && (( merr > 0 )); } \
       || { [[ "$uncorr" =~ ^[0-9]+$ ]] && (( uncorr > 0 )); } \
       || { [[ "$kind" == "ATA" && "$pending" =~ ^[0-9]+$ ]] && (( pending > 0 )); }; then
        _sf_crit "DiskIO" "$dev has real media errors (media=${merr:-0} pending=${pending:-0} uncorrectable=${uncorr:-0})" \
            "Journal I/O errors + these counters = the drive is your crash cause. Backup + RMA/replace."
    fi
    if [[ "$kind" == "ATA" && "$realloc" =~ ^[1-9] ]]; then
        _sf_warn "DiskIO" "$dev Reallocated_Sector_Ct=${realloc} — sectors already failed and were remapped" \
            "Watch the trend; plan replacement. Back up first."
    fi
    if [[ "$kind" == "ATA" && "$crc" =~ ^[1-9] ]]; then
        _sf_warn "DiskIO" "$dev UDMA_CRC_Error_Count=${crc} — SATA cable/backplane link corruption (not the platters)" \
            "Reseat or replace the SATA cable and port before blaming the disk."
    fi
    if [[ "$kind" == "NVMe" && "$spare" =~ ^[0-9]+$ && "$spareth" =~ ^[0-9]+$ ]] && (( spare <= spareth )); then
        _sf_crit "DiskIO" "$dev available_spare ${spare}% ≤ threshold ${spareth}% — spare blocks exhausted" \
            "Endurance reached. Replace the drive before it locks read-only."
    fi
    if [[ "$used" =~ ^[0-9]+$ ]] && (( used >= 90 )); then
        _sf_warn "DiskIO" "$dev endurance used ${used}% — near rated lifetime" \
            "Budget a replacement; keep backups fresh."
    fi
    if [[ "$unsafe" =~ ^[0-9]+$ ]] && (( unsafe >= 10 )); then
        local ratio=""
        [[ "$pc" =~ ^[0-9]+$ && "$pc" -gt 0 ]] && ratio=" ($(( unsafe * 100 / pc ))% of ${pc} power cycles ended abruptly)"
        _sf_warn "Unclean" "$dev logged ${unsafe} unsafe_shutdowns${ratio} — the drive keeps its own count of abrupt power losses (clean shutdown never increments it)" \
            "Every entry = one death without shutdown. Compare with ./crashz LAST WORDS and ./powerz (PSU/UPS)."
        if [[ -n "$SMART_UNSAFE_HOOK" ]] && declare -F "$SMART_UNSAFE_HOOK" >/dev/null 2>&1; then
            "$SMART_UNSAFE_HOOK" "$dev" "$unsafe"
        fi
    fi
    if [[ "$temp" =~ ^[0-9]+$ ]] && (( temp >= 60 )); then
        _sf_warn "Thermal" "$dev at ${temp}°C — hot for storage (NVMe throttles ~70-85°C, can wedge the box under load)" \
            "Add airflow/M.2 heatsink — cheap insurance against thermal freeze."
    fi
    if [[ "$errlog" =~ ^[1-9] ]] && [[ "$kind" == "NVMe" ]]; then
        _sf_warn "DiskIO" "$dev num_err_log_entries=${errlog} — controller logged device errors: sudo ${SMARTCTL_BIN:-smartctl} -l error $dev" \
            "Decode the error log; correlate timestamps with freeze episodes."
    fi
    return 0
}

smart_findings() {
    smart_available || return 1
    [[ $SMART_SCANNED -eq 1 ]] || smart_collect || return 1
    local row
    for row in "${SMART_ROWS[@]}"; do
        IFS=$'\x1f' read -r -a _fields <<< "$row"
        _smart_eval "${_fields[0]}" "${_fields[1]}" "${_fields[2]}" "${_fields[3]}" "${_fields[4]}" \
            "${_fields[5]}" "${_fields[6]}" "${_fields[7]}" "${_fields[8]}" "${_fields[9]}" \
            "${_fields[10]}" "${_fields[11]}" "${_fields[12]}" "${_fields[13]}" "${_fields[14]}" \
            "${_fields[15]}" "${_fields[16]}" "${_fields[17]}"
    done
    return 0
}

# smart_parse_text_stream <label> — evaluate PASTED smartctl -A / NVMe log text
smart_parse_text_stream() {
    local label="${1:-pasted-log}"
    local cw="" temp="" spare="" thresh="" pct="" unsafe="" cycles="" media="" errl="" poh="" devname=""
    local line key val
    while IFS= read -r line; do
        [[ -z "$devname" && "$line" == *"device:"* && "$line" == *"Smart Log"* ]] \
            && devname=$(printf '%s' "$line" | sed -E 's/.*device:([A-Za-z0-9_.-]+).*/\1/')
        key=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*:.*/\1/')
        val=$(printf '%s' "$line" | grep -oE ':[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
        [[ -z "$val" ]] && continue
        case "$key" in
            critical_warning) cw="$val" ;;
            temperature) [[ -z "$temp" ]] && temp="$val" ;;
            available_spare) [[ -z "$spare" ]] && spare="$val" ;;
            available_spare_threshold) thresh="$val" ;;
            percentage_used) pct="$val" ;;
            unsafe_shutdowns) unsafe="$val" ;;
            power_cycles) cycles="$val" ;;
            media_errors) media="$val" ;;
            num_err_log_entries) errl="$val" ;;
            power_on_hours) poh="$val" ;;
        esac
    done
    if [[ -z "$cw$unsafe$spare$pct$media" ]]; then
        printf '  · %s: no SMART health fields recognized in the pasted text\n' "$label"
        return 1
    fi
    [[ -z "$devname" ]] && label="$label (pasted)" || label="$devname (pasted)"
    printf '  · %s: cw=%s temp=%s°C spare=%s%% used=%s%% unsafe_shut=%s cycles=%s media_err=%s errlog=%s poh=%s\n' \
        "$label" "${cw:-?}" "${temp:-?}" "${spare:-?}" "${pct:-?}" "${unsafe:-?}" "${cycles:-?}" "${media:-?}" "${errl:-?}" "${poh:-?}"
    _smart_eval "${devname:-$label}" NVMe "as pasted" PASSED "$temp" "$pct" "$spare" "$thresh" \
        "$unsafe" "$media" "" "" "" "" "$poh" "$cycles" "$errl" "$cw"
}

_sf_crit() {
    if declare -F critf >/dev/null 2>&1; then
        critf "$1" "$2" "$3"
    else
        printf '  ✗ [%s] %s — FIX: %s\n' "$1" "$2" "$3"
    fi
}
_sf_warn() {
    if declare -F warnf >/dev/null 2>&1; then
        warnf "$1" "$2" "$3"
    else
        printf '  ! [%s] %s — SUGGESTION: %s\n' "$1" "$2" "$3"
    fi
}
