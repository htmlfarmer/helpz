#!/usr/bin/env bash
# ============================================================================
# lib/common.sh - Shared utilities for Security & Diagnostic Suite
# ============================================================================

# ---------- Global Counters & State ----------
WARNINGS=0
CRITICAL=0
NO_COLOR=${NO_COLOR:-0}
JSON_OUT=${JSON_OUT:-0}     # respect a value set by the caller's arg parser
WATCH_INTERVAL=${WATCH_INTERVAL:-0}   # same: don't clobber a parsed --watch
START_TS=$(date +%s)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')
HOSTNAME_SHORT=$(hostname -s 2>/dev/null || echo "host")
declare -a JSON_FIELDS=()

# ---------- Logging (errors.txt / warnings.txt) ----------
# SECURITY_LOG_DIR can be overridden by env var. Defaults to ~/.security-logs.
LOG_DIR="${SECURITY_LOG_DIR:-$HOME/.security-logs}"
ERROR_LOG="$LOG_DIR/errors.txt"
WARNING_LOG="$LOG_DIR/warnings.txt"
LOG_NO_WRITE="${LOG_NO_WRITE:-0}"   # set to 1 to skip writing to logs

# Ensure log directory exists (silently)
[[ "$LOG_NO_WRITE" -ne 1 ]] && mkdir -p "$LOG_DIR" 2>/dev/null || true

# Initialize logs with a header on first creation
_init_log_files() {
    [[ -f "$ERROR_LOG"  ]] || printf '# Security Suite Errors Log — appended, never overwritten\n# Format: [TIMESTAMP] [SCRIPT] [CATEGORY] message — FIX: one-liner\n\n' > "$ERROR_LOG"  2>/dev/null || true
    [[ -f "$WARNING_LOG" ]] || printf '# Security Suite Warnings Log — appended, never overwritten\n# Format: [TIMESTAMP] [SCRIPT] [CATEGORY] message — SUGGESTION: one-liner\n\n' > "$WARNING_LOG" 2>/dev/null || true
}
[[ "$LOG_NO_WRITE" -ne 1 ]] && _init_log_files

# Arrays to track issues with category + fix details (for one-liner verdict output)
declare -a CRITICAL_ISSUES=()    # entries: "category|message|one_liner_fix"
declare -a WARN_ENTRIES=()       # entries: "category|message|one_liner_suggestion"
declare -A _CRIT_DEDUP=()
declare -A _WARN_DEDUP=()

# ---------- Color Initialization ----------
init_colors() {
    if [[ -t 1 ]] && [[ "${NO_COLOR:-0}" -eq 0 ]] && [[ "${JSON_OUT:-0}" -eq 0 ]]; then
        C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
        C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
        C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
        C_WHITE=$'\033[37m'
    else
        C_RESET=""; C_BOLD=""; C_DIM=""
        C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
        C_MAGENTA=""; C_CYAN=""; C_WHITE=""
    fi
}

# Run color initialization initially
init_colors

# ---------- duration parsing ----------
# Shared "1hr" / "5min" / "2h" → "N unit ago" translation (lib/duration.sh).
[[ -z "${SCRIPT_DIR:-}" ]] && SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/duration.sh
[[ -r "$SCRIPT_DIR/lib/duration.sh" ]] && source "$SCRIPT_DIR/lib/duration.sh"

# ---------- chart toolkit ----------
# Every tool that sources common.sh also gets the text-chart helpers.
[[ -z "${SCRIPT_DIR:-}" ]] && SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/chart.sh
[[ -r "$SCRIPT_DIR/lib/chart.sh" ]] && source "$SCRIPT_DIR/lib/chart.sh"

# ---------- live heartbeat for slow commands ----------
# with_spin "label" cmd args...   → runs cmd (stdout stays capturable),
# paints a braille spinner + elapsed seconds on /dev/tty while it runs.
with_spin() {
    local label="$1"; shift
    if [[ "${JSON_OUT:-0}" -eq 1 || "${NO_SPIN:-0}" -eq 1 ]]; then
        "$@"; return $?
    fi
    local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) i=0 t0 rc=0 spinpid=""
    t0=$(date +%s)
    if (exec 200<>/dev/tty) 2>/dev/null; then
        ( while :; do
            printf "\r\033[2m  %s %s … %ss\033[0m" "${frames[$((i%10))]}" "$label" "$(( $(date +%s) - t0 ))" > /dev/tty 2>/dev/null
            i=$((i+1)); sleep 0.4
          done ) & spinpid=$!
    fi
    "$@"; rc=$?
    if [[ -n "$spinpid" ]]; then
        kill "$spinpid" 2>/dev/null; wait "$spinpid" 2>/dev/null
        printf "\r\033[K" > /dev/tty 2>/dev/null
    fi
    return $rc
}

# ---------- Output Helpers (JSON-aware) ----------
emit() {
    [[ "${JSON_OUT:-0}" -eq 1 ]] && return 0
    # shellcheck disable=SC2059
    printf "$@"
}

section() {
    [[ "${JSON_OUT:-0}" -eq 1 ]] && return 0
    printf "\n  ${C_BOLD}${C_CYAN}━${C_RESET}${C_BOLD}${C_MAGENTA}━━ %s ━━${C_RESET}${C_BOLD}${C_CYAN}━${C_RESET}\n" "$1"
}

subsec() {
    [[ "${JSON_OUT:-0}" -eq 1 ]] && return 0
    printf "  ${C_DIM}╭─ %s${C_RESET}\n" "$1"
}

ok() {
    [[ "${JSON_OUT:-0}" -eq 1 ]] && return 0
    printf "  ${C_GREEN}✓${C_RESET} %s\n" "$1"
}

info() {
    [[ "${JSON_OUT:-0}" -eq 1 ]] && return 0
    printf "  ${C_DIM}·${C_RESET} %s\n" "$1"
}

warn() {
    # Backward compatible: warn "message" [optional "suggestion"]
    # New form: warn "category" "message" "suggestion" via warnf (preferred)
    local category="${1:-General}" message="${2:-}" suggestion="${3:-}"
    if [[ $# -eq 1 ]]; then
        message="$1"
        category="General"
        suggestion=""
    fi
    _log_warn "$category" "$message" "$suggestion"
}

crit() {
    # Backward compatible: crit "message" [optional "one-line fix"]
    # New form: critf "category" "message" "one-line fix" (preferred — tracks category)
    local category="${1:-General}" message="${2:-}" fix="${3:-}"
    if [[ $# -eq 1 ]]; then
        message="$1"
        category="General"
        fix=""
    elif [[ $# -eq 2 ]]; then
        message="$1"
        fix="$2"
        category="General"
    fi
    _log_crit "$category" "$message" "$fix"
}

# Preferred variants — explicit category + message + fix
critf() { _log_crit  "${1:-General}" "${2:-}" "${3:-}"; }
warnf() { _log_warn  "${1:-General}" "${2:-}" "${3:-}"; }

# Internal loggers — do the actual work
_log_crit() {
    local category="$1" message="$2" fix="$3"
    CRITICAL=$((CRITICAL + 1))

    # De-duplicate identical issues per run
    local key="${category}::${message}"
    if [[ -z "${_CRIT_DEDUP[$key]:-}" ]]; then
        _CRIT_DEDUP[$key]=1
        CRITICAL_ISSUES+=("$category|$message|$fix")
        [[ "$LOG_NO_WRITE" -ne 1 ]] && {
            printf '[%s] [%s] [%s] %s — FIX: %s\n' \
                "$(date '+%Y-%m-%d %H:%M:%S %Z')" "${0##*/}" "$category" "$message" "${fix:-N/A}" \
                >> "$ERROR_LOG" 2>/dev/null || true
        }
    fi

    [[ "${JSON_OUT:-0}" -eq 1 ]] && return 0
    printf "  ${C_RED}✗${C_RESET} %s\n" "$message"
}

_log_warn() {
    local category="$1" message="$2" suggestion="$3"
    WARNINGS=$((WARNINGS + 1))

    local key="${category}::${message}"
    if [[ -z "${_WARN_DEDUP[$key]:-}" ]]; then
        _WARN_DEDUP[$key]=1
        WARN_ENTRIES+=("$category|$message|$suggestion")
        [[ "$LOG_NO_WRITE" -ne 1 ]] && {
            printf '[%s] [%s] [%s] %s — SUGGESTION: %s\n' \
                "$(date '+%Y-%m-%d %H:%M:%S %Z')" "${0##*/}" "$category" "$message" "${suggestion:-N/A}" \
                >> "$WARNING_LOG" 2>/dev/null || true
        }
    fi

    [[ "${JSON_OUT:-0}" -eq 1 ]] && return 0
    printf "  ${C_YELLOW}!${C_RESET} %s\n" "$message"
}

heading() {
    [[ "${JSON_OUT:-0}" -eq 1 ]] && return 0
    printf "\n  ${C_BOLD}${C_MAGENTA}%s${C_RESET}\n" "$1"
}

# ---------- Comparison Helpers ----------
is_gt() {
    [[ -n "$1" && -n "$2" ]] || return 1
    [[ $(echo "$1 > $2" | bc -l 2>/dev/null) == "1" ]]
}

is_lt() {
    [[ -n "$1" && -n "$2" ]] || return 1
    [[ $(echo "$1 < $2" | bc -l 2>/dev/null) == "1" ]]
}

is_eq() {
    [[ -n "$1" && -n "$2" ]] || return 1
    [[ $(echo "$1 == $2" | bc -l 2>/dev/null) == "1" ]]
}

# Integer-only fast variants (no bc fork). Use these for pct/byte/count comparisons.
is_gt_int() { (( ${1:-0} > ${2:-0} )); }
is_lt_int() { (( ${1:-0} < ${2:-0} )); }
is_eq_int() { (( ${1:-0} == ${2:-0} )); }

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# ---------- Formatting Helpers ----------
humansize() {
    local val="$1"
    numfmt --to=iec --suffix=B "$val" 2>/dev/null || echo "${val}B"
}

trunc() {
    local str="$1" len="$2"
    if (( ${#str} > len )); then
        printf "%s…" "${str:0:$((len - 1))}"
    else
        printf "%s" "$str"
    fi
}

temp_color() {
    local t=$1
    if [[ -z "$t" ]] || ! [[ "$t" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        echo "$C_DIM"
    elif is_gt "$t" 80 2>/dev/null; then
        echo "$C_RED"
    elif is_gt "$t" 60 2>/dev/null; then
        echo "$C_YELLOW"
    else
        echo "$C_GREEN"
    fi
}

dur_color() {
    local s=$1
    if (( s < 60 )); then
        emit "${C_GREEN}%ds${C_RESET}" "$s"
    elif (( s < 300 )); then
        emit "${C_YELLOW}%dm%02ds${C_RESET}" $((s / 60)) $((s % 60))
    elif (( s < 3600 )); then
        emit "${C_MAGENTA}%dm%02ds${C_RESET}" $((s / 60)) $((s % 60))
    else
        emit "${C_RED}%dh%02dm${C_RESET}" $((s / 3600)) $((s / 60 % 60))
    fi
}

# ---------- table renderer (ANSI-width aware) ----------
_TBL_COLS=(); _TBL_ROWS=(); _TBL_ON=0
_vlen() { awk -v s="$1" 'BEGIN{gsub(/\033\[[0-9;]*m/,"",s); print length(s)}'; }
table_begin() { [[ "${JSON_OUT:-0}" -eq 1 ]] && return 0; _TBL_COLS=("$@"); _TBL_ROWS=(); _TBL_ON=1; }
table_row()   { [[ "${JSON_OUT:-0}" -eq 1 || ${_TBL_ON:-0} -eq 0 ]] && return 0
    local r="" f
    for f in "$@"; do r+="${f}"$'\t'; done
    _TBL_ROWS+=("${r%$'\t'}"); }
table_end() {
    [[ "${JSON_OUT:-0}" -eq 1 || ${_TBL_ON:-0} -eq 0 ]] && { _TBL_ON=0; return 0; }
    local i j row cell pad c
    local -a W=() cells
    for ((i=0;i<${#_TBL_COLS[@]};i++)); do W[i]=$(_vlen "${_TBL_COLS[i]}"); done
    for row in "${_TBL_ROWS[@]}"; do
        IFS=$'\t' read -r -a cells <<< "$row"
        for ((i=0;i<${#cells[@]};i++)); do
            c=$(_vlen "${cells[i]}")
            (( c > ${W[i]:-0} )) && W[i]=$c
        done
    done
    local sep dash padstr line
    line="  ╔"
    for ((i=0;i<${#W[@]};i++)); do
        printf -v dash '%*s' "$(( W[i] + 2 ))" ''; dash=${dash// /─}
        line+="$dash"; (( i < ${#W[@]} - 1 )) && line+="╦"
    done
    printf "%s\n" "${C_DIM}${line}╗${C_RESET}"
    line="  ║"
    for ((i=0;i<${#_TBL_COLS[@]};i++)); do
        pad=$(( W[i] - $(_vlen "${_TBL_COLS[i]}") )); printf -v padstr '%*s' "$pad" ''
        line+=" ${C_BOLD}${_TBL_COLS[i]}${C_RESET}${padstr} │"
    done
    printf "%b\n" "${line%?}║"
    for row in "${_TBL_ROWS[@]}"; do
        IFS=$'\t' read -r -a cells <<< "$row"
        line="  ║"
        for ((i=0;i<${#W[@]};i++)); do
            cell="${cells[i]:-}"
            pad=$(( W[i] - $(_vlen "$cell") )); printf -v padstr '%*s' "$pad" ''
            line+=" $cell${padstr} │"
        done
        printf "%b\n" "${line%?}║"
    done
    line="  ╚"
    for ((i=0;i<${#W[@]};i++)); do
        printf -v dash '%*s' "$(( W[i] + 2 ))" ''; dash=${dash// /─}
        line+="$dash"; (( i < ${#W[@]} - 1 )) && line+="╩"
    done
    printf "%s\n" "${C_DIM}${line}╝${C_RESET}"
    _TBL_ON=0
}

# ---------- visual primitives ----------
bar() {
    local pct=$1 width=${2:-20}
    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    # green → lime → amber → orange → red ramp
    local color="$C_GREEN"
    (( pct >= 85 )) && color="$C_RED"
    (( pct >= 70 )) && color="$C_YELLOW"
    (( pct >= 55 && pct < 70 )) && color="$C_YELLOW"
    local filled_str="" empty_str=""
    if (( filled > 0 )); then
        printf -v filled_str '%*s' "$filled" ''
        filled_str=${filled_str// /█}
    fi
    if (( empty > 0 )); then
        printf -v empty_str '%*s' "$empty" ''
        empty_str=${empty_str// /░}
    fi
    emit "%s%s%s%s%s %3d%%" "$color" "$filled_str" "$C_DIM" "$empty_str" "$C_RESET" "$pct"
}

# spark <n1> <n2> ...  → unicode sparkline (auto-scaled, with min/max labels)
spark() {
    local data
    data=$(printf '%s\n' "$@")
    awk '
        BEGIN{ split("▁ ▂ ▃ ▄ ▅ ▆ ▇ █", g, " "); n=0; mn=""; mx="" }
        NF==0 { next }
        $1 !~ /^-?[0-9.]+$/ { next }
        {
            n++; v[n]=$1+0
            if (mn=="" || v[n]<mn) mn=v[n]
            if (mx=="" || v[n]>mx) mx=v[n]
        }
        END{
            if (n==0) { print "(no data)"; exit }
            out=""
            for (i=1;i<=n;i++) {
                lvl = (mx==mn) ? 5 : int((v[i]-mn)/(mx-mn)*7)+1
                out = out g[lvl]
            }
            printf "%s  %g→%g\n", out, v[1], v[n]
        }' <<< "$data"
}

# kpi <label> <value> <color>   — one-line stat card
kpi() {
    local lbl="$1" val="$2" col="${3:-$C_GREEN}"
    emit "  ${C_DIM}▏${C_RESET} ${C_DIM}%-14s${C_RESET} ${C_BOLD}%b%s${C_RESET}\n" "$lbl" "$col" "$val"
}

# hr — thin divider
hr() { emit "  ${C_DIM}┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈${C_RESET}\n"; }

# ---------- Suggestion Catalog (extensive) ----------
# Each key is a category; value is a multi-line detailed remediation.
# Use get_suggestion() to retrieve by category.
declare -A SUGGESTION_CATALOG=(
    # --- Network / Ports ---
    ["postgres_exposed"]="Bind PostgreSQL to localhost: set 'listen_addresses = localhost' in /etc/postgresql/*/main/postgresql.conf, restrict 'host all all 0.0.0.0/0 md5' in pg_hba.conf to your subnet, then 'sudo systemctl restart postgresql'. Better: place behind firewall/SSH tunnel."
    ["mysql_exposed"]="Bind MySQL to 127.0.0.1: add 'bind-address = 127.0.0.1' to /etc/mysql/mysql.conf.d/mysqld.cnf and 'sudo systemctl restart mysql'. Use SSH tunnel or firewall for remote access."
    ["redis_exposed"]="Redis without auth on wildcard is remote-root. Bind to 127.0.0.1 in /etc/redis/redis.conf ('bind 127.0.0.1 ::1'), set 'requirepass' and 'rename-command FLUSHALL \"\"', then restart. Better: use a private network and TLS."
    ["mongodb_exposed"]="MongoDB on 0.0.0.0 has been mass-exploited (ransomware). Add 'bindIp: 127.0.0.1' to /etc/mongod.conf, enable authorization ('security.authorization: enabled'), and restart mongod."
    ["memcached_exposed"]="Memcached on wildcard is a UDP amplification vector. Bind to 127.0.0.1 in /etc/memcached.conf ('-l 127.0.0.1') and disable UDP ('-U 0'). Restart the service."
    ["telnet_exposed"]="Telnet sends credentials in plaintext. Disable: 'sudo systemctl disable --now telnet.socket' (or xinetd). Use SSH instead. Remove the package if unused: 'sudo apt remove telnetd'."
    ["dev_server_exposed"]="Dev servers (Node/Flask/etc.) on 0.0.0.0 leak source code and debug info. Bind to 127.0.0.1 in your dev config or use 'ssh -L 8080:localhost:8080 user@host' for remote work. Restrict with UFW: 'sudo ufw deny 8080'."
    ["docker_ufw_bypass"]="Docker publishes ports directly via iptables PREROUTING, bypassing UFW. Fix: bind to loopback in compose ('127.0.0.1:8080:80'), or add explicit rules to the DOCKER-USER chain: 'sudo iptables -I DOCKER-USER -i ext_if -j DROP' (replace ext_if)."
    ["docker_published_wildcard"]="Container publishing to 0.0.0.0 may bypass host firewall. Edit docker-compose.yml ports to '127.0.0.1:HOST:CONTAINER' or rely on an external reverse proxy with TLS auth."
    ["wildcard_listener_generic"]="Anonymous service on all interfaces. Disable if unused ('sudo systemctl disable --now <svc>'), bind to localhost in its config, or restrict via firewall: 'sudo ufw deny <port>'."

    # --- SSH ---
    ["ssh_root_login"]="Set 'PermitRootLogin prohibit-password' (or 'no') in /etc/ssh/sshd_config, then 'sudo sshd -t && sudo systemctl reload sshd'. Use a sudo user with key for admin tasks."
    ["ssh_password_auth"]="Set 'PasswordAuthentication no' in /etc/ssh/sshd_config. Distribute public keys first: 'ssh-copy-id user@host'. Reload sshd. Optional: install fail2ban."
    ["ssh_empty_passwords"]="Set 'PermitEmptyPasswords no' in /etc/ssh/sshd_config and 'sudo passwd -l <account>' for any account with no password. Reload sshd."
    ["ssh_weak_cipher_3des"]="Remove 3des from 'Ciphers' in /etc/ssh/sshd_config. Use: chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr."
    ["ssh_weak_cipher_arcfour"]="Remove arcfour (RC4) from 'Ciphers' and 'Ciphers +' lines in /etc/ssh/sshd_config — it is broken."
    ["ssh_weak_cipher_cbc"]="Prefer AEAD ciphers (ChaCha20-Poly1305, AES-GCM) over CBC. Edit sshd_config 'Ciphers' line and remove any *-cbc entries."
    ["ssh_weak_mac_md5"]="Remove MD5 and *-96 MACs from 'MACs' in /etc/ssh/sshd_config. Use: hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com."
    ["ssh_dir_perms"]="Run 'chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys ~/.ssh/id_* && chmod 644 ~/.ssh/*.pub' for each user. sshd refuses keys with loose perms."
    ["ssh_private_key_perms"]="Run 'chmod 600 <key>' (or 400) on the private key file. Group/world-readable private keys are treated as compromised by sshd."
    ["ssh_authorized_keys_perms"]="Run 'chmod 600 ~/.ssh/authorized_keys'. sshd will ignore authorized_keys with looser permissions."
    ["ssh_weak_rsa_key"]="RSA < 2048 bits is broken. Replace: 'ssh-keygen -t ed25519 -C \"user@host\"', append the new pubkey to authorized_keys, remove the old RSA key, reload sshd."
    ["ssh_dsa_key"]="DSA keys are deprecated and disabled in modern OpenSSH. Generate Ed25519: 'ssh-keygen -t ed25519', distribute, and remove DSA entries from authorized_keys."
    ["ssh_pubkey_auth_disabled"]="Set 'PubkeyAuthentication yes' in /etc/ssh/sshd_config and reload. Useful for keys-only deployments."

    # --- Hardening / Sysctl ---
    ["shadow_perms"]="Run 'sudo chown root:shadow /etc/shadow /etc/gshadow && sudo chmod 640 /etc/shadow /etc/gshadow'. World-readable shadow enables offline cracking."
    ["aslr_disabled"]="ASLR = 0 disables exploit mitigations. 'echo kernel.randomize_va_space=2 | sudo tee /etc/sysctl.d/99-aslr.conf && sudo sysctl -p'. Reboot recommended for full coverage."
    ["syncookies_disabled"]="Enable SYN cookies to resist SYN floods: 'echo net.ipv4.tcp_syncookies=1 | sudo tee /etc/sysctl.d/99-syncookies.conf && sudo sysctl -p'."
    ["sysctl_unhardened"]="Run 'sudo ./harden.sh --apply' to apply CIS-aligned sysctl settings (ASLR, SYN cookies, dmesg restrict, kptr restrict, rp_filter, martian logging)."
    ["dmesg_restricted"]="Set 'kernel.dmesg_restrict=1' to prevent unprivileged users from reading kernel logs (info leaks). 'sudo sysctl -w kernel.dmesg_restrict=1' and persist via /etc/sysctl.d/."
    ["kptr_restricted"]="Set 'kernel.kptr_restrict=2' to hide kernel pointers from non-root users (mitigates KASLR bypass)."
    ["suid_dumpable"]="Set 'fs.suid_dumpable=0' so setuid programs cannot dump core (prevents leak of privileged memory)."
    ["rp_filter_disabled"]="Enable reverse-path filtering: 'net.ipv4.conf.all.rp_filter=1' and 'net.ipv4.conf.default.rp_filter=1'. Helps defeat IP spoofing."
    ["accept_redirects_enabled"]="Disable ICMP redirects: 'net.ipv4.conf.all.accept_redirects=0' and 'send_redirects=0'. Prevents MITM via redirect injection."
    ["source_route_enabled"]="Disable source routing: 'net.ipv4.conf.all.accept_source_route=0'. Source routing has been abused for spoofing since the 90s."
    ["log_martians_disabled"]="Enable martian logging: 'net.ipv4.conf.all.log_martians=1' to surface spoofed/bogus packets in kernel logs."

    # --- Account / User ---
    ["empty_password_account"]="Lock or set a password: 'sudo passwd -l <user>' (lock) or 'sudo passwd <user>' (set). Empty-password accounts can be SSH'd into with no credentials on some configs."
    ["extra_uid0_account"]="Multiple UID-0 accounts increase attack surface. Demote the duplicate: 'sudo usermod -u 1001 -g 1001 extrauser' after fixing ownership of their files, OR remove if not needed."
    ["no_firewall"]="Install and enable a firewall: 'sudo apt install ufw && sudo ufw default deny incoming && sudo ufw allow ssh && sudo ufw enable'. For richer rules use nftables."
    ["world_writable_file"]="Files with mode 0002 are writable by anyone. 'sudo chmod o-w <path>' or remove the file. Review with 'find / -xdev -perm -0002 -type f'."
    ["world_writable_dir_no_sticky"]="World-writable directory without sticky bit allows any user to delete others' files. 'sudo chmod +t <dir>' or restrict with 'sudo chmod 755 <dir>'."
    ["unowned_file"]="Files with no user/group break permission checks. 'sudo find / -xdev \\( -nouser -o -nogroup \\) -exec chown root:root {} +'."
    ["unexpected_suid"]="SUID binaries grant root to anyone who runs them. Audit with 'find / -perm -4000 -type f'. Remove SUID if not needed: 'sudo chmod u-s <binary>'."
    ["rootkit_signature"]="Run 'sudo rkhunter --check' and 'sudo chkrootkit -q'. Inspect any matches manually. Keep system patched and avoid untrusted binary downloads."

    # --- Service / Process ---
    ["failed_service"]="Investigate: 'systemctl status <service>' and 'journalctl -u <service> --since \"1 hour ago\"'. Restart if needed: 'sudo systemctl restart <service>'."
    ["promiscuous_interface"]="Interface in promiscuous mode is packet sniffing. Run 'sudo ip link set <iface> promisc off' and investigate which process enabled it (check /proc)."
    ["high_cpu_process"]="Identify with 'ps aux --sort=-%cpu | head' or 'top -c'. If miner: kill PID, find persistence (cron, systemd), patch entry point."
    ["excessive_login_failures"]="Brute force in progress. Install fail2ban: 'sudo apt install fail2ban && sudo systemctl enable --now fail2ban'. Inspect banned IPs: 'sudo fail2ban-client status sshd'."
    ["invalid_user_login"]="Credential-stuffing scan. Tighten 'PermitRootLogin no' and 'PasswordAuthentication no'. Install fail2ban with recidive jail."

    # --- Logging ---
    ["log_no_rotation"]="Logs without rotation will fill the disk. Configure /etc/logrotate.d/<service> with rotate, compress, maxage. Test: 'sudo logrotate -d /etc/logrotate.conf'."
    ["auth_log_unreadable"]="auth.log is unreadable — auditing is blind. 'sudo chmod 640 /var/log/auth.log && sudo chown root:adm /var/log/auth.log && sudo usermod -aG adm <user>'."

    # --- Generic ---
    ["general"]="Review the issue and apply appropriate remediation. See script documentation and man pages for the affected subsystem. Re-run the audit after applying changes."
)

get_suggestion() {
    local category="$1"
    local key="${category,,}"   # case-insensitive lookup
    if [[ -n "${SUGGESTION_CATALOG[$key]:-}" ]]; then
        printf "%s\n" "${SUGGESTION_CATALOG[$key]}"
    else
        printf "Review and remediate based on the affected subsystem. Consult upstream docs and CIS benchmarks.\n"
    fi
}

# Print all known suggestion keys (for --help)
suggestion_keys() {
    printf '%s\n' "${!SUGGESTION_CATALOG[@]}" | sort
}


# ---------- "what to run next" prescription router ----------
# category → "tool|reason". When a scan logs findings, emit_next_steps()
# recommends the exact follow-up tools so the user always knows what's next.
declare -A NEXT_TOOL_MAP=(
    ["BootSpace"]="kernelz|disk space is blocking kernel installs — kernelz fix audits the toolchain"
    ["Pending"]="kernelz|a kernel update is half-applied — finish it with: kernelz verify"
    ["GrubEntry"]="kernelz|GRUB entries are inconsistent — kernelz (status) to inspect, kernelz recover if booting"
    ["GrubDefault"]="kernelz|GRUB default not on a known-good kernel — kernelz recover pins it"
    ["GrubCfg"]="kernelz|grub config unreadable — run with sudo or kernelz recover"
    ["KernelMeta"]="kernelz|kernel meta-package missing — kernelz protect fixes apt tracking"
    ["HoldMissing"]="kernelz|running kernel unprotected from apt — kernelz protect"
    ["PkgMissing"]="kernelz fix|a required package is absent — kernelz fix names and installs them"
    ["BuildToolchain"]="kernelz build|compiler toolchain incomplete for source builds — kernelz build lists every missing package + install line"
    ["AptDeps"]="kernelz fix|apt has unmet dependencies blocking upgrades — kernelz fix --apply"
    ["DpkgBroken"]="kernelz fix|dpkg database unfinished — kernelz fix --apply repairs it"
    ["Dkms"]="driverz|dkms modules out of sync with the running kernel — driverz cross-checks"
    ["Firmware"]="driverz|firmware failed to load — driverz --events names the exact apt package"
    ["DriverMissing"]="driverz|hardware has no driver — driverz gives per-chip install playbooks"
    ["DriverUnbound"]="driverz|kernel module idle, not bound — driverz shows the modprobe fix"
    ["NetFirmware"]="driverz --net|network card missing firmware — driverz --net has the playbook"
    ["NetDriver"]="driverz --net|interface has no driver — driverz --net to diagnose the NIC"
    ["GPU"]="driverz --net|GPU/driver stack issue — driverz video section covers nvidia/nouveau"
    ["CpuVuln"]="kernelz|CPU mitigations missing — a newer kernel usually fixes this (kernelz)"
    ["no_firewall"]="firewallz|no active firewall — firewallz audits all backdoors"
    ["wildcard_db_exposed"]="portz|database exposed on all interfaces — portz to see who can reach it"
    ["wildcard_listener_generic"]="portz|service bound to 0.0.0.0 — portz maps exposure, firewallz blocks"
    ["dev_server_exposed"]="portz|dev server exposed publicly — portz to confirm, firewallz to bind"
    ["docker_published_wildcard"]="portz|docker published ports bypass firewall — portz lists mappings"
    ["ssh_root_login"]="sshauditz|SSH hardening gaps — sshauditz gives the config diff"
    ["ssh_password_auth"]="sshauditz|SSH allows passwords — sshauditz for key-only migration"
    ["ssh_empty_passwords"]="sshauditz|empty-password SSH logins — sshauditz + abusez"
    ["failed_service"]="logz|services failing — logz shows the recent error stream"
    ["FailedUnit"]="logz|failed systemd units — logz (or bootz) for cause and journal"
    ["PriorBoot"]="bootz|previous boot had errors — bootz --boot -1 for the full story"
    ["promiscuous_interface"]="networkz|NIC in promiscuous mode — networkz to trace why"
    ["high_cpu_process"]="topz|a process is eating CPU — topz shows it at a glance"
    ["zombie_threads"]="topz|thread/process buildup — topz + threadz to see who leaks"
    ["browser_cred_perms"]="browserz|browser credential exposure — browserz audit + privacy score"
    ["browser_cookie_perms"]="browserz|cookie store perms — browserz flags credential risks"
    ["shadow_perms"]="securityz|account file perms — full re-scan with securityz"
    ["sysctl_unhardened"]="hardenz|kernel sysctls unhardened — hardenz --dry-run shows fixes"
    ["world_writable_file"]="securityz|world-writable files — securityz full audit"
    ["unexpected_suid"]="securityz|unexpected SUID binaries — securityz (and rkhunter)"
    ["rootkit_signature"]="securityz|possible rootkit indicators — securityz + rkhunter NOW"
    ["excessive_login_failures"]="abusez|brute-force pattern — abusez builds the evidence dossier"
    ["invalid_user_login"]="abusez|login probing — abusez aggregates attacker history"
    ["log_no_rotation"]="logz|logs growing unbounded — logz shows what to rotate"
    ["KernelPanic"]="kernelz|kernel panic/oops captured — kernelz studies the kernel; crashz bundle exports the evidence"
    ["MCE"]="kernelz|machine-check hardware errors — crashz bundle + bootz --boot -1 for the record"
    ["GpuHang"]="driverz|GPU hang/reset in the journal — driverz covers the video stack"
    ["Thermal"]="cpuz|thermal criticals — cpuz shows live temps and throttling"
    ["OOM"]="memoryz|process killed by OOM — memoryz finds the eaters"
    ["HungTask"]="slowz|tasks blocked for minutes — slowz ranks what waits on I/O"
    ["DiskIO"]="diskz|disk I/O errors — diskz checks SMART health"
    ["Unclean"]="bootz|previous boot ended abruptly — bootz --boot -1 for the final minutes"
    ["Segfault"]="debugz|segfault/core dumps — debugz inspects crashing binaries"
    ["DesktopCrash"]="logz|desktop/display crashed — logz shows the app error stream"
    ["PkgChange"]="crashz|package updates correlate with crashes — crashz ranks the evidence"
)

# manual push from any tool: suggest_tool firewallz "no firewall rules found"
declare -a _SUGGEST_EXTRA=()
suggest_tool() { [[ $# -ge 1 ]] && _SUGGEST_EXTRA+=("$1|$2"); return 0; }

emit_next_steps() {
    [[ "${JSON_OUT:-0}" -eq 1 ]] && return 0
    local -A want=()          # tool|reason → score
    local entry cat tool reason key
    for entry in "${CRITICAL_ISSUES[@]:-}"; do
        [[ -z "$entry" ]] && continue
        cat="${entry%%|*}"
        if [[ -n "${NEXT_TOOL_MAP[$cat]:-}" ]]; then
            tool="${NEXT_TOOL_MAP[$cat]%%|*}"; reason="${NEXT_TOOL_MAP[$cat]#*|}"
            want["$tool|$reason"]=1
        fi
    done
    for entry in "${WARN_ENTRIES[@]:-}"; do
        [[ -z "$entry" ]] && continue
        cat="${entry%%|*}"
        if [[ -n "${NEXT_TOOL_MAP[$cat]:-}" ]]; then
            tool="${NEXT_TOOL_MAP[$cat]%%|*}"; reason="${NEXT_TOOL_MAP[$cat]#*|}"
            key="$tool|$reason"; [[ -z "${want[$key]:-}" ]] && want["$key"]=0
        fi
    done
    for entry in "${_SUGGEST_EXTRA[@]:-}"; do
        [[ -z "$entry" ]] && continue
        want["$entry"]=${want["$entry"]:-0}
    done
    (( ${#want[@]} == 0 )) && return 0
    printf "\n  ${C_BOLD}${C_BLUE}━━━ WHAT TO DO NEXT ━━━${C_RESET}\n"
    local shown=0
    for key in "${!want[@]}"; do
        [[ $shown -ge 6 ]] && break
        tool="${key%%|*}"; reason="${key#*|}"
        printf "    ${C_GREEN}→${C_RESET} ${C_BOLD}./%s${C_RESET} ${C_DIM}— %s${C_RESET}\n" "$tool" "$reason"
        shown=$((shown+1))
    done
    printf "  ${C_DIM}deep history: tail -40 ~/.security-logs/errors.txt · or run ./nextz anytime${C_RESET}\n"
}

# ---------- JSON & Verdict Output ----------
add_json_field() {
    local key="$1" val="$2" is_raw="${3:-0}"
    if [[ "$is_raw" -eq 1 ]]; then
        JSON_FIELDS+=("\"$key\":$val")
    else
        local escaped="${val//\\/\\\\}"
        escaped="${escaped//\"/\\\"}"
        escaped="${escaped//$'\n'/\\n}"
        JSON_FIELDS+=("\"$key\":\"$escaped\"")
    fi
}

# Emit a one-liner explanation block before the verdict
emit_critical_one_liners() {
    [[ ${#CRITICAL_ISSUES[@]} -eq 0 ]] && return 0
    [[ "${JSON_OUT:-0}" -eq 1 ]] && return 0

    section "CRITICAL ISSUES — ONE-LINER EXPLANATIONS"
    printf "${C_DIM}Each critical finding below explains the problem and the immediate fix.${C_RESET}\n"
    local i=0
    for entry in "${CRITICAL_ISSUES[@]}"; do
        i=$((i + 1))
        IFS='|' read -r cat msg fix <<< "$entry"
        printf "\n  ${C_RED}${C_BOLD}[%d]${C_RESET} ${C_BOLD}[%-22s]${C_RESET} %s\n" "$i" "$cat" "$msg"
        if [[ -n "$fix" ]]; then
            printf "      ${C_GREEN}↳ Fix:${C_RESET} %s\n" "$fix"
        fi
    done

    # Group by category and show detailed remediation once per category
    printf "\n${C_DIM}── Detailed remediation by category ──${C_RESET}\n"
    local seen_categories=""
    for entry in "${CRITICAL_ISSUES[@]}"; do
        IFS='|' read -r cat msg fix <<< "$entry"
        # Skip category "General" — no specific guidance
        [[ "$cat" == "General" || -z "$cat" ]] && continue
        # Skip duplicates
        [[ " $seen_categories " == *" $cat "* ]] && continue
        seen_categories="$seen_categories $cat"

        local detailed
        detailed=$(get_suggestion "$cat")
        printf "\n  ${C_CYAN}${C_BOLD}[%s]${C_RESET}\n" "$cat"
        while IFS= read -r line; do
            printf "    ${C_DIM}•${C_RESET} %s\n" "$line"
        done <<< "$detailed"
    done
}

# Emit one-liner explanations for warnings (less verbose than critical)
emit_warning_one_liners() {
    [[ ${#WARN_ENTRIES[@]} -eq 0 ]] && return 0
    [[ "${JSON_OUT:-0}" -eq 1 ]] && return 0

    section "WARNING DETAILS — SUGGESTIONS"
    printf "${C_DIM}Review each warning below; the suggestion column describes next steps.${C_RESET}\n"
    local i=0
    for entry in "${WARN_ENTRIES[@]}"; do
        i=$((i + 1))
        IFS='|' read -r cat msg sug <<< "$entry"
        printf "\n  ${C_YELLOW}${C_BOLD}[%d]${C_RESET} ${C_BOLD}[%-22s]${C_RESET} %s\n" "$i" "$cat" "$msg"
        if [[ -n "$sug" ]]; then
            printf "      ${C_GREEN}↳ Suggestion:${C_RESET} %s\n" "$sug"
        fi
    done
}

# ---------- findings chart ----------
# Every tool that logs findings through critf/warnf ends up with the same
# two arrays. Drawing the breakdown here means all 20+ tools get a chart of
# their own results for free, and they all look identical.
chart_findings() {
    chart_suppressed && return 0
    local n_crit=0 n_warn=0
    (( ${#CRITICAL_ISSUES[@]} )) && n_crit=${#CRITICAL_ISSUES[@]}
    (( ${#WARN_ENTRIES[@]} )) && n_warn=${#WARN_ENTRIES[@]}
    (( n_crit + n_warn == 0 )) && return 0

    # Group by category.
    local -A cats=()
    local e cat
    for e in "${CRITICAL_ISSUES[@]:-}"; do
        [[ -z "$e" ]] && continue
        cat="${e%%|*}"
        cats["$cat"]=$(( ${cats[$cat]:-0} + 1 ))
    done
    for e in "${WARN_ENTRIES[@]:-}"; do
        [[ -z "$e" ]] && continue
        cat="${e%%|*}"
        cats["$cat"]=$(( ${cats[$cat]:-0} + 1 ))
    done
    (( ${#cats[@]} == 0 )) && return 0

    section "FINDINGS BREAKDOWN"
    local -a pairs=()
    for cat in "${!cats[@]}"; do pairs+=("$cat"$'\t'"${cats[$cat]}"); done
    printf '%s\n' "${pairs[@]}" | sort -t$'\t' -k2 -gr | chart_hbars

    # A severity split ring — but only when there is a critical share to show.
    # An empty ring at 0% is just four blank lines, so say it in words instead.
    local total=$(( n_crit + n_warn ))
    if (( n_crit > 0 )); then
        local pct=$(( n_crit * 100 / total ))
        printf "\n"
        chart_donut "$pct" "critical share"
        printf "  %s%d critical%s  ·  %s%d warning%s  ·  %s%d total%s\n" \
            "$C_RED" "$n_crit" "$C_RESET" "$C_YELLOW" "$n_warn" "$C_RESET" \
            "$C_DIM" "$total" "$C_RESET"
    else
        printf "\n  %s%d warning%s  ·  %s%d total%s  ·  %sno critical findings%s\n" \
            "$C_YELLOW" "$n_warn" "$C_RESET" "$C_DIM" "$total" "$C_RESET" \
            "$C_GREEN" "$C_RESET"
    fi
}

emit_verdict() {
    # if a run-comparison capture is still open, drain it NOW so the tee
    # coprocess can never paint bytes after the shell prompt (fd-order race)
    if declare -F run_comparison_finalize >/dev/null 2>&1 && [[ -n "${COMPARISON_TEMP_FILE:-}" && -z "${COMPARISON_FINALIZED:-}" ]]; then
        COMPARISON_FINALIZED=1
        exec 1>&3 3>&- 2>/dev/null || true
        sleep 0.15
    fi
    local end_ts elapsed exit_code=0
    end_ts=$(date +%s)
    elapsed=$((end_ts - START_TS))

    # Append JSON fields for logged issues (so JSON consumers can see what was found)
    if [[ ${#CRITICAL_ISSUES[@]} -gt 0 ]]; then
        local crit_json
        crit_json=$(printf '%s\n' "${CRITICAL_ISSUES[@]}" | jq -R . | jq -s . 2>/dev/null) || crit_json='[]'
        add_json_field "critical_issues" "$crit_json" 1
    else
        add_json_field "critical_issues" "[]" 1
    fi
    if [[ ${#WARN_ENTRIES[@]} -gt 0 ]]; then
        local warn_json
        warn_json=$(printf '%s\n' "${WARN_ENTRIES[@]}" | jq -R . | jq -s . 2>/dev/null) || warn_json='[]'
        add_json_field "warning_entries" "$warn_json" 1
    else
        add_json_field "warning_entries" "[]" 1
    fi
    add_json_field "error_log" "$ERROR_LOG" 0
    add_json_field "warning_log" "$WARNING_LOG" 0

    if [[ "${JSON_OUT:-0}" -eq 1 ]]; then
        printf '{"timestamp":"%s","hostname":"%s"' "$TIMESTAMP" "$HOSTNAME_SHORT"
        for f in "${JSON_FIELDS[@]}"; do
            printf ',%s' "$f"
        done
        printf ',"warnings":%d,"critical":%d,"duration_s":%d}\n' "$WARNINGS" "$CRITICAL" "$elapsed"
    else
        section "VERDICT"
        if (( CRITICAL > 0 )); then
            printf "  ${C_RED}${C_BOLD}CRITICAL${C_RESET}: %d critical, %d warnings\n" "$CRITICAL" "$WARNINGS"
            exit_code=2
        elif (( WARNINGS > 0 )); then
            printf "  ${C_YELLOW}${C_BOLD}WARNING${C_RESET}: %d warnings, no critical issues\n" "$WARNINGS"
            exit_code=1
        else
            printf "  ${C_GREEN}${C_BOLD}HEALTHY${C_RESET}: no issues detected\n"
            exit_code=0
        fi
        printf "  ${C_DIM}Scan completed in %ds at %s${C_RESET}\n\n" "$elapsed" "$(date '+%H:%M:%S')"

        # Findings chart — every tool that logs findings gets one.
        chart_findings

        # Pointer to logs
        if (( CRITICAL > 0 )) || (( WARNINGS > 0 )); then
            printf "  ${C_DIM}Full logs (append-only): ${C_RESET}${C_CYAN}%s${C_RESET}\n" "$ERROR_LOG"
            printf "  ${C_DIM}Warnings log:            ${C_RESET}${C_CYAN}%s${C_RESET}\n\n" "$WARNING_LOG"
        fi

        # Detailed one-liner explanations BEFORE the verdict
        emit_critical_one_liners
        emit_warning_one_liners
        emit_next_steps
        printf "\n"
    fi

    if [[ "${WATCH_INTERVAL:-0}" -gt 0 ]] && [[ "${JSON_OUT:-0}" -eq 0 ]]; then
        trap 'exit 0' INT TERM
        while true; do
            sleep "$WATCH_INTERVAL"
            printf "\n${C_DIM}── refresh ──${C_RESET}\n"
            START_TS=$(date +%s)
            exec "$0" "${ARGS[@]}"
        done
    fi

    exit "$exit_code"
}
