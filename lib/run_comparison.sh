#!/usr/bin/env bash
# ============================================================================
# lib/run_comparison.sh - Run comparison utility for script diffs
# ============================================================================
# Source this library in your script to enable automatic comparison of the
# current run against the previous run. On the first run, it saves the output.
# On subsequent runs, it compares and saves a diff to <scriptname>.txt.
#
# Usage in your script:
#   source "$SCRIPT_DIR/lib/run_comparison.sh"
#   run_comparison_init "scriptname"   # pass the base name of your script
#   # ... your script output ...
#   run_comparison_finalize             # call at the end to save/comparison
#
# Output files:
#   ~/.security-runs/<scriptname>.last    - stores last run output
#   <suite-dir>/<scriptname>.txt - diff comparison report
# ============================================================================

COMPARISON_DIR="${COMPARISON_DIR:-$HOME/.security-runs}"
COMPARISON_SCRIPT_NAME=""
COMPARISON_TEMP_FILE=""
COMPARISON_ENABLED="${COMPARISON_ENABLED:-1}"

run_comparison_init() {
    COMPARISON_SCRIPT_NAME="$1"
    [[ -z "$COMPARISON_SCRIPT_NAME" ]] && return 1
    mkdir -p "$COMPARISON_DIR" 2>/dev/null

    COMPARISON_TEMP_FILE=$(mktemp)

    # write-through capture: output goes to the terminal LIVE *and* to the
    # temp file for the diff. (Old behaviour redirected stdout into a file
    # with no replay until finalize — slow tools looked frozen.)
    exec 3>&1
    exec 1> >(tee "$COMPARISON_TEMP_FILE")
}

run_comparison_finalize() {
    [[ "${COMPARISON_FINALIZED:-}" == "1" ]] && return 0
    COMPARISON_FINALIZED=1
    [[ "${COMPARISON_ENABLED:-1}" != "1" ]] && return 0
    [[ -z "$COMPARISON_SCRIPT_NAME" ]] && return 1
    [[ -z "$COMPARISON_TEMP_FILE" ]] && return 1

    # let the tee coprocess drain after we stop writing through it
    exec 1>&3 3>&- 2>/dev/null || true
    sleep 0.2

    local last_file="${COMPARISON_DIR}/${COMPARISON_SCRIPT_NAME}.last"
    local diff_file="${SCRIPT_DIR}/${COMPARISON_SCRIPT_NAME}.txt"
    local current_output

    current_output=$(cat "$COMPARISON_TEMP_FILE" 2>/dev/null || echo "")
    local temp_output_file="$COMPARISON_TEMP_FILE"

    if [[ -n "$current_output" ]]; then
        if [[ -f "$last_file" ]]; then
            local prev_content
            prev_content=$(cat "$last_file" 2>/dev/null || echo "")

            if [[ "$prev_content" != "$current_output" ]]; then
                local timestamp prev_file curr_file
                timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
                prev_file=$(mktemp)
                curr_file=$(mktemp)

                printf "%s" "$prev_content" > "$prev_file"
                printf "%s" "$current_output" > "$curr_file"

                local diff_output
                diff_output=$(diff "$prev_file" "$curr_file" 2>&1)

                local added_lines=0 removed_lines=0 changed_lines=0
                if [[ -n "$diff_output" ]]; then
                    added_lines=$(printf "%s" "$diff_output" | grep -c "^>" || true)
                    removed_lines=$(printf "%s" "$diff_output" | grep -c "^<" || true)
                    changed_lines=$(printf "%s" "$diff_output" | grep -c "^!" || true)
                fi

                local total_changes=$((added_lines + removed_lines + changed_lines))

                local prev_lines=0 curr_lines=0 line_diff=0
                prev_lines=$(printf "%s" "$prev_content" | wc -l)
                curr_lines=$(printf "%s" "$current_output" | wc -l)
                if [[ $prev_lines -gt $curr_lines ]]; then
                    line_diff=$((prev_lines - curr_lines))
                else
                    line_diff=$((curr_lines - prev_lines))
                fi

                local health_pct=100
                if [[ "$total_changes" -gt 0 ]]; then
                    local deduction=0
                    deduction=$((line_diff * 2))
                    [[ $deduction -gt 50 ]] && deduction=50
                    health_pct=$((100 - deduction))

                    if [[ "$added_lines" -gt 5 ]]; then
                        deduction=$((added_lines / 2))
                        [[ $deduction -gt 20 ]] && deduction=20
                        health_pct=$((health_pct - deduction))
                    fi
                    if [[ "$removed_lines" -gt 5 ]]; then
                        deduction=$((removed_lines / 2))
                        [[ $deduction -gt 20 ]] && deduction=20
                        health_pct=$((health_pct - deduction))
                    fi
                    if printf "%s" "$diff_output" | grep -qi "CRITICAL\|ERROR\|FAIL\|FATAL"; then
                        health_pct=$((health_pct > 30 ? health_pct - 30 : 0))
                    elif printf "%s" "$diff_output" | grep -qi "WARNING\|WARN"; then
                        health_pct=$((health_pct > 15 ? health_pct - 15 : health_pct))
                    fi
                fi
                [[ $health_pct -lt 0 ]] && health_pct=0
                [[ $health_pct -gt 100 ]] && health_pct=100

                local health_bar="" filled=0 empty=0 i=0
                filled=$((health_pct / 5))
                empty=$((20 - filled))
                for ((i=0; i<filled; i++)); do health_bar+="█"; done
                for ((i=0; i<empty; i++)); do health_bar+="░"; done

                local health_color="32"
                [[ $health_pct -lt 70 ]] && health_color="33"
                [[ $health_pct -lt 40 ]] && health_color="31"

                {
                    printf "%s\n" "==============================================================================="
                    printf "  COMPARISON REPORT: %s\n" "$COMPARISON_SCRIPT_NAME"
                    printf "  Generated: %s\n" "$timestamp"
                    printf "%s\n\n" "==============================================================================="

                    printf "%s\n" "--- PREVIOUS RUN ---"
                    cat "$prev_file"
                    printf "\n%s\n" "--- CURRENT RUN ---"
                    cat "$curr_file"
                    printf "\n%s\n" "--- DIFF (Previous vs Current) ---"

                    if [[ -s "$prev_file" && -s "$curr_file" ]]; then
                        printf "%s\n" "$diff_output" || true
                    else
                        printf "%s\n" "(One of the runs was empty)"
                    fi

                    printf "\n%s\n" "==============================================================================="
                    printf "  HEALTH SCORE\n"
                    printf "%s\n" "==============================================================================="
                    printf "  \033[%sm%s\033[0m [%s] %d%%\n" "$health_color" "$COMPARISON_SCRIPT_NAME" "$health_bar" "$health_pct"
                    printf "  \n"
                    printf "  Changes: +%d lines, -%d lines, ~%d changed\n" "$added_lines" "$removed_lines" "$changed_lines"
                    if [[ $health_pct -ge 80 ]]; then
                        printf "  Status: \033[32mHEALTHY\033[0m - System stable, minimal changes\n"
                    elif [[ $health_pct -ge 50 ]]; then
                        printf "  Status: \033[33mCAUTION\033[0m - Moderate changes detected\n"
                    else
                        printf "  Status: \033[31mCRITICAL\033[0m - Significant changes, review recommended\n"
                    fi
                    printf "\n%s\n" "==============================================================================="
                    printf "  END OF COMPARISON REPORT\n"
                    printf "%s\n" "==============================================================================="
                } > "$diff_file"

                rm -f "$prev_file" "$curr_file" 2>/dev/null || true
            fi
        fi

        printf "%s" "$current_output" > "$last_file"
        # NO replay to stdout: run_comparison_init writes through via tee, so the
        # terminal has already seen every byte. Replaying here (old redirect-era
        # behavior) duplicated all output AND swallowed the trailing newline
        # ($() strips it), leaving the shell prompt glued to the last line.
    fi

    rm -f "$COMPARISON_TEMP_FILE" 2>/dev/null || true
}

run_comparison_cleanup() {
    [[ -z "$COMPARISON_SCRIPT_NAME" ]] && return 1
    local last_file="${COMPARISON_DIR}/${COMPARISON_SCRIPT_NAME}.last"
    rm -f "$last_file" 2>/dev/null
}
