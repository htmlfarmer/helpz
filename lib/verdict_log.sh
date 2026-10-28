#!/usr/bin/env bash
# ============================================================================
# lib/verdict_log.sh — Standalone verdict logging helper
# ----------------------------------------------------------------------------
# Lightweight helper for scripts that don't source lib/common.sh.
# Provides:
#   - LOG_DIR / ERROR_LOG / WARNING_LOG setup
#   - log_verdict_crit / log_verdict_warn to append to logs
#   - show_verdict_one_liners to display problem + fix one-liners
#   - A subset of the SUGGESTION_CATALOG for common categories
#
# Usage in standalone script (e.g. security.sh):
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/verdict_log.sh"
#   log_verdict_crit "ssh_root_login" "PermitRootLogin yes" "Set PermitRootLogin no"
#   ...
#   show_verdict_one_liners
# ============================================================================

# ---------- Logging paths ----------
LOG_DIR="${SECURITY_LOG_DIR:-$HOME/.security-logs}"
ERROR_LOG="$LOG_DIR/errors.txt"
WARNING_LOG="$LOG_DIR/warnings.txt"
LOG_NO_WRITE="${LOG_NO_WRITE:-0}"

mkdir -p "$LOG_DIR" 2>/dev/null || true

# Initialize on first source
_init_vlog_files() {
    [[ -f "$ERROR_LOG"  ]] || printf '# Security Suite Errors Log — appended, never overwritten\n# Format: [TIMESTAMP] [SCRIPT] [CATEGORY] message — FIX: one-liner\n\n' > "$ERROR_LOG"  2>/dev/null || true
    [[ -f "$WARNING_LOG" ]] || printf '# Security Suite Warnings Log — appended, never overwritten\n# Format: [TIMESTAMP] [SCRIPT] [CATEGORY] message — SUGGESTION: one-liner\n\n' > "$WARNING_LOG" 2>/dev/null || true
}
_init_vlog_files

# ---------- Stash arrays (caller populates) ----------
# VLOG_CRITICAL=("category|message|fix" ...)
# VLOG_WARNINGS=("category|message|suggestion" ...)
# Use unset to guarantee empty default — "${arr[@]-}" pattern always creates
# a single empty-string element which would falsely report count=1.
unset VLOG_CRITICAL VLOG_WARNINGS
declare -a VLOG_CRITICAL=()
declare -a VLOG_WARNINGS=()

_log_append() {
    local logfile="$1" category="$2" message="$3" suffix_label="$4" suggestion="$5"
    [[ "$LOG_NO_WRITE" -eq 1 ]] && return 0
    printf '[%s] [%s] [%s] %s — %s: %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S %Z')" "${0##*/}" "$category" "$message" "$suffix_label" "${suggestion:-N/A}" \
        >> "$logfile" 2>/dev/null || true
}

log_verdict_crit() {
    local category="${1:-General}" message="${2:-}" fix="${3:-}"
    VLOG_CRITICAL+=("$category|$message|$fix")
    _log_append "$ERROR_LOG" "$category" "$message" "FIX" "$fix"
}

log_verdict_warn() {
    local category="${1:-General}" message="${2:-}" suggestion="${3:-}"
    VLOG_WARNINGS+=("$category|$message|$suggestion")
    _log_append "$WARNING_LOG" "$category" "$message" "SUGGESTION" "$suggestion"
}

# ---------- Suggestion catalog (subset for standalone scripts) ----------
declare -A VLOG_SUGGESTIONS=(
    ["ssh_root_login"]="Set 'PermitRootLogin prohibit-password' in /etc/ssh/sshd_config and 'sudo systemctl reload sshd'."
    ["ssh_password_auth"]="Set 'PasswordAuthentication no' in sshd_config, distribute keys via ssh-copy-id, then reload sshd."
    ["ssh_empty_passwords"]="Set 'PermitEmptyPasswords no' in sshd_config and lock any passwordless accounts with 'sudo passwd -l <user>'."
    ["ssh_weak_cipher_3des"]="Remove 3des from 'Ciphers' in sshd_config and use ChaCha20-Poly1305/AES-GCM ciphers."
    ["ssh_weak_cipher_arcfour"]="Remove arcfour (RC4) from 'Ciphers' — RC4 is broken, use modern AEAD ciphers."
    ["ssh_weak_cipher_cbc"]="Remove *-cbc entries from 'Ciphers' and prefer AEAD ciphers."
    ["ssh_weak_mac_md5"]="Replace MD5/*-96 MACs with hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com."
    ["ssh_dir_perms"]="Run 'chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys ~/.ssh/id_*' for each user."
    ["ssh_private_key_perms"]="Run 'chmod 600 <key>' (or 400) on the private key file."
    ["ssh_authorized_keys_perms"]="Run 'chmod 600 ~/.ssh/authorized_keys'."
    ["ssh_weak_rsa_key"]="Generate Ed25519: 'ssh-keygen -t ed25519', append to authorized_keys, remove old RSA key."
    ["ssh_dsa_key"]="DSA is disabled in modern OpenSSH. Replace with Ed25519: 'ssh-keygen -t ed25519'."
    ["postgres_exposed"]="Bind to localhost in postgresql.conf ('listen_addresses = localhost'), restrict pg_hba.conf, restart PostgreSQL."
    ["mysql_exposed"]="Add 'bind-address = 127.0.0.1' to /etc/mysql/mysql.conf.d/mysqld.cnf and restart mysql."
    ["redis_exposed"]="Bind to 127.0.0.1 in /etc/redis/redis.conf, set requirepass, rename FLUSHALL, restart Redis."
    ["mongodb_exposed"]="Add 'bindIp: 127.0.0.1' to /etc/mongod.conf, enable auth, restart mongod."
    ["memcached_exposed"]="Bind to 127.0.0.1 ('-l 127.0.0.1') and disable UDP ('-U 0') in memcached.conf."
    ["telnet_exposed"]="Disable telnetd: 'sudo systemctl disable --now telnet.socket' — use SSH instead."
    ["dev_server_exposed"]="Bind to 127.0.0.1 in dev config or restrict with 'sudo ufw deny <port>'."
    ["docker_ufw_bypass"]="Bind to loopback in compose ('127.0.0.1:8080:80') or add DROP rule to DOCKER-USER iptables chain."
    ["docker_published_wildcard"]="Edit compose ports to '127.0.0.1:HOST:CONTAINER' or place behind reverse proxy with TLS auth."
    ["wildcard_listener_generic"]="Disable if unused ('sudo systemctl disable --now <svc>'), bind to localhost in its config, or restrict via firewall."
    ["shadow_perms"]="Run 'sudo chown root:shadow /etc/shadow /etc/gshadow && sudo chmod 640 /etc/shadow /etc/gshadow'."
    ["aslr_disabled"]="Enable: 'echo kernel.randomize_va_space=2 | sudo tee /etc/sysctl.d/99-aslr.conf && sudo sysctl -p'."
    ["syncookies_disabled"]="Enable SYN cookies: 'echo net.ipv4.tcp_syncookies=1 | sudo tee /etc/sysctl.d/99-syncookies.conf && sudo sysctl -p'."
    ["sysctl_unhardened"]="Run 'sudo ./harden.sh --apply' to apply CIS-aligned sysctl settings."
    ["empty_password_account"]="Lock or set a password: 'sudo passwd -l <user>' (lock) or 'sudo passwd <user>' (set)."
    ["extra_uid0_account"]="Demote the duplicate: 'sudo usermod -u 1001 -g 1001 extrauser' after fixing file ownerships."
    ["no_firewall"]="Install and enable UFW: 'sudo apt install ufw && sudo ufw default deny incoming && sudo ufw allow ssh && sudo ufw enable'."
    ["world_writable_file"]="Run 'sudo chmod o-w <path>' to remove world-writable bit. Inspect with 'find / -xdev -perm -0002 -type f'."
    ["world_writable_dir_no_sticky"]="Run 'sudo chmod +t <dir>' to set sticky bit, or restrict with 'sudo chmod 755 <dir>'."
    ["unowned_file"]="Run 'sudo find / -xdev \\( -nouser -o -nogroup \\) -exec chown root:root {} +'."
    ["unexpected_suid"]="Audit with 'find / -perm -4000 -type f'. Remove SUID if not needed: 'sudo chmod u-s <binary>'."
    ["failed_service"]="Investigate: 'systemctl status <service>' and 'journalctl -u <service> --since \"1 hour ago\"'. Restart if needed."
    ["promiscuous_interface"]="Disable: 'sudo ip link set <iface> promisc off'. Identify which process enabled it via /proc."
    ["high_cpu_process"]="Identify with 'ps aux --sort=-%cpu | head' or 'top -c'. If miner: kill PID, find persistence (cron, systemd)."
    ["excessive_login_failures"]="Install fail2ban: 'sudo apt install fail2ban && sudo systemctl enable --now fail2ban'. Check: 'sudo fail2ban-client status sshd'."
    ["invalid_user_login"]="Tighten 'PermitRootLogin no' and 'PasswordAuthentication no'. Install fail2ban with recidive jail."
    ["log_no_rotation"]="Configure /etc/logrotate.d/<service> with rotate, compress, maxage. Test: 'sudo logrotate -d /etc/logrotate.conf'."
    ["auth_log_unreadable"]="Fix perms: 'sudo chmod 640 /var/log/auth.log && sudo chown root:adm /var/log/auth.log && sudo usermod -aG adm <user>'."
    ["missing_tool"]="Install via your package manager: 'sudo apt install <pkg>' (Debian/Ubuntu) or 'sudo dnf install <pkg>' (RHEL/Fedora)."
    ["general"]="Review the issue and apply appropriate remediation based on the affected subsystem. Re-run the audit after changes."
)

_vlog_get_suggestion() {
    local category="$1"
    local key="${category,,}"
    if [[ -n "${VLOG_SUGGESTIONS[$key]:-}" ]]; then
        printf "%s\n" "${VLOG_SUGGESTIONS[$key]}"
    else
        printf "Review and remediate based on the affected subsystem.\n"
    fi
}

# ---------- One-liner explanations ----------
show_verdict_one_liners() {
    local no_color="${NO_COLOR:-0}"
    local C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_YELLOW="" C_GREEN="" C_CYAN="" C_BLUE=""
    if [[ -t 1 ]] && [[ "$no_color" -eq 0 ]]; then
        C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
        C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_GREEN=$'\033[32m'
        C_CYAN=$'\033[36m'; C_BLUE=$'\033[34m'
    fi

    if [[ ${#VLOG_CRITICAL[@]} -gt 0 ]]; then
        printf "\n${C_BOLD}${C_BLUE}━━━ CRITICAL ISSUES — ONE-LINER EXPLANATIONS ━━━${C_RESET}\n"
        printf "${C_DIM}Each critical finding below explains the problem and the immediate fix.${C_RESET}\n"
        local i=0
        for entry in "${VLOG_CRITICAL[@]}"; do
            i=$((i + 1))
            IFS='|' read -r cat msg fix <<< "$entry"
            printf "\n  ${C_RED}${C_BOLD}[%d]${C_RESET} ${C_BOLD}[%-22s]${C_RESET} %s\n" "$i" "$cat" "$msg"
            if [[ -n "$fix" ]]; then
                printf "      ${C_GREEN}↳ Fix:${C_RESET} %s\n" "$fix"
            fi
        done

        printf "\n${C_DIM}── Detailed remediation by category ──${C_RESET}\n"
        local seen=""
        for entry in "${VLOG_CRITICAL[@]}"; do
            IFS='|' read -r cat msg fix <<< "$entry"
            [[ "$cat" == "General" || -z "$cat" ]] && continue
            [[ " $seen " == *" $cat "* ]] && continue
            seen="$seen $cat"
            local detailed
            detailed=$(_vlog_get_suggestion "$cat")
            printf "\n  ${C_CYAN}${C_BOLD}[%s]${C_RESET}\n" "$cat"
            while IFS= read -r line; do
                printf "    ${C_DIM}•${C_RESET} %s\n" "$line"
            done <<< "$detailed"
        done
    fi

    if [[ ${#VLOG_WARNINGS[@]} -gt 0 ]]; then
        printf "\n${C_BOLD}${C_BLUE}━━━ WARNING DETAILS — SUGGESTIONS ━━━${C_RESET}\n"
        printf "${C_DIM}Review each warning below; the suggestion column describes next steps.${C_RESET}\n"
        local i=0
        for entry in "${VLOG_WARNINGS[@]}"; do
            i=$((i + 1))
            IFS='|' read -r cat msg sug <<< "$entry"
            printf "\n  ${C_YELLOW}${C_BOLD}[%d]${C_RESET} ${C_BOLD}[%-22s]${C_RESET} %s\n" "$i" "$cat" "$msg"
            if [[ -n "$sug" ]]; then
                printf "      ${C_GREEN}↳ Suggestion:${C_RESET} %s\n" "$sug"
            fi
        done
    fi

    if [[ ${#VLOG_CRITICAL[@]} -gt 0 || ${#VLOG_WARNINGS[@]} -gt 0 ]]; then
        printf "\n  ${C_DIM}Full logs (append-only): ${C_RESET}${C_CYAN}%s${C_RESET}\n" "$ERROR_LOG"
        printf "  ${C_DIM}Warnings log:            ${C_RESET}${C_CYAN}%s${C_RESET}\n" "$WARNING_LOG"
    fi
}
