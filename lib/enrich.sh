# ============================================================================
# lib/enrich.sh — IP / hostname geographic enrichment
# ----------------------------------------------------------------------------
# Provides:
#   - enrich_ip <ip>      → "City, State, Country | Org | Hostname"
#   - enrich_log_entry    → append enriched entry to a log file
#
# Caches lookups to ~/.cache/security-enrich.json so we hit the rate limit
# at most once per IP per script run. Uses ip-api.com (free, no key, 45/min).
#
# Usage in any script:
#   source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/enrich.sh"
#   echo "$(enrich_ip 1.2.3.4)"
#   # → "Pullman, WA, United States | Ziply Fiber | moon.lan"
#
# The output is a single line, pipe-separated so callers can split with IFS='|'.
# ============================================================================

ENRICH_CACHE="${HOME}/.cache/security-enrich.json"
mkdir -p "$(dirname "$ENRICH_CACHE")" 2>/dev/null || true

# Cache file format (one line per IP, pipe-separated, 8 fields):
# ip|city|region|region_code|country|country_code|org|hostname
ENRICH_FIELDS=8

# ─── Internal: cache lookup ────────────────────────────────────────────────
_enrich_cache_lookup() {
    local ip="$1"
    [[ -f "$ENRICH_CACHE" ]] || return 1
    awk -F'|' -v ip="$ip" '$1==ip {found=1; print; exit} END {exit !found}' "$ENRICH_CACHE" 2>/dev/null
}

_enrich_cache_write() {
    local ip="$1" city="$2" region="$3" region_code="$4" country="$5" country_code="$6" org="$7" hostname="$8"
    # Append only if not present
    if [[ -f "$ENRICH_CACHE" ]]; then
        awk -F'|' -v ip="$ip" '$1==ip {found=1} END {exit !found}' "$ENRICH_CACHE" 2>/dev/null && return 0
    fi
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$ip" "$city" "$region" "$region_code" "$country" "$country_code" "$org" "$hostname" \
        >> "$ENRICH_CACHE" 2>/dev/null || true
}

# ─── Internal: live lookup ─────────────────────────────────────────────────
_enrich_live_lookup() {
    local ip="$1"
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || return 1

    local resp
    if command -v curl >/dev/null 2>&1; then
        resp=$(curl -s --max-time 6 "http://ip-api.com/json/$ip?fields=status,city,regionName,region,country,countryCode,org,query" 2>/dev/null)
    else
        resp=$(wget -qO- --timeout=6 "http://ip-api.com/json/$ip?fields=status,city,regionName,region,country,countryCode,org,query" 2>/dev/null)
    fi

    [[ -z "$resp" ]] && return 1
    command -v jq >/dev/null 2>&1 || return 1

    local status
    status=$(printf '%s' "$resp" | jq -r '.status // "fail"' 2>/dev/null)
    [[ "$status" != "success" ]] && return 1

    local city region region_code country country_code org
    city=$(printf '%s' "$resp" | jq -r '.city // "?"' 2>/dev/null)
    region=$(printf '%s' "$resp" | jq -r '.regionName // "?"' 2>/dev/null)
    region_code=$(printf '%s' "$resp" | jq -r '.region // "?"' 2>/dev/null)
    country=$(printf '%s' "$resp" | jq -r '.country // "?"' 2>/dev/null)
    country_code=$(printf '%s' "$resp" | jq -r '.countryCode // "?"' 2>/dev/null)
    org=$(printf '%s' "$resp" | jq -r '.org // "?"' 2>/dev/null)
    # Trim "AS20055 " style prefix
    org="${org#AS[0-9]* }"

    # Reverse DNS via getent
    local hostname="—"
    hostname=$(getent hosts "$ip" 2>/dev/null | awk '{print $2}' | head -1)
    [[ -z "$hostname" ]] && hostname="—"

    _enrich_cache_write "$ip" "$city" "$region" "$region_code" "$country" "$country_code" "$org" "$hostname"
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$ip" "$city" "$region" "$region_code" "$country" "$country_code" "$org" "$hostname"
    return 0
}

# ─── Public: enrich_ip <ip> ─────────────────────────────────────────────────
# Prints "City, State, Country | Org | Hostname" for any IP, or "?" for
# private/unresolvable addresses.
enrich_ip() {
    local ip="$1"
    [[ -z "$ip" ]] && { printf "—|—|—\n"; return; }

    # Skip private / loopback / link-local / multicast
    case "$ip" in
        127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|169.254.*|0.*|255.*|::*) \
            printf "local network|—|—\n"; return ;;
        fe80:*|fc00:*|fd00:*) printf "local network|—|—\n"; return ;;
    esac

    # Cache hit?
    local cached
    cached=$(_enrich_cache_lookup "$ip")
    if [[ -n "$cached" ]]; then
        printf '%s\n' "$cached"
        return
    fi

    # Live lookup
    local result
    result=$(_enrich_live_lookup "$ip")
    if [[ -n "$result" ]]; then
        printf '%s\n' "$result"
        sleep 1.4  # respect ip-api.com rate limit
        return
    fi

    printf "—|—|—\n"
}

# ─── Public: enrich_ip_short <ip> ───────────────────────────────────────────
# Prints just "City, Country | Org" — terse form for tables.
enrich_ip_short() {
    local ip="$1"
    local full
    full=$(enrich_ip "$ip")
    local city region country org hostname
    IFS='|' read -r _ city region _ country _ org hostname <<< "$full"
    printf "%s, %s | %s\n" "$city" "$country" "$org"
}

# ─── Public: enrich_ip_full <ip> ────────────────────────────────────────────
# Prints a multi-line "rich" form: town/state/country, IP, hostname, org.
# Useful for one-line "incident location" summaries.
enrich_ip_full() {
    local ip="$1"
    local full
    full=$(enrich_ip "$ip")
    local ip2 city region region_code country country_code org hostname
    IFS='|' read -r ip2 city region region_code country country_code org hostname <<< "$full"

    if [[ "$city" == "local network" || "$city" == "—" ]]; then
        printf "  Location: local network\n"
        printf "  IP:       %s\n" "$ip"
        [[ "$hostname" != "—" ]] && printf "  Hostname: %s\n" "$hostname"
        return
    fi

    # Compose a clean location string
    local location=""
    if [[ "$city" != "—" && "$city" != "?" ]]; then
        location="$city"
        [[ "$region_code" != "—" && "$region_code" != "?" ]] && location="$location, $region_code"
    fi
    [[ "$country" != "—" && "$country" != "?" ]] && location="$location, $country"
    [[ -z "$location" ]] && location="Unknown"

    printf "  Location: %s\n" "$location"
    printf "  IP:       %s\n" "$ip"
    [[ "$hostname" != "—" ]] && printf "  Hostname: %s\n" "$hostname"
    [[ "$org" != "—" ]] && printf "  Network:  %s\n" "$org"
}

# ─── Public: enrich_log_entry <ip> <reason> ────────────────────────────────
# Logs a structured "incident" line to ~/.security-logs/incidents.txt with
# the enriched location.
ENRICH_LOG="${SECURITY_LOG_DIR:-$HOME/.security-logs}/incidents.txt"
mkdir -p "$(dirname "$ENRICH_LOG")" 2>/dev/null || true
# Initialize on first source
[[ -f "$ENRICH_LOG" ]] || printf '# Security Incidents — appended, never overwritten\n# Format: [TIMESTAMP] [SCRIPT] IP — City, State, Country | Org | Hostname — Reason\n\n' > "$ENRICH_LOG" 2>/dev/null || true

enrich_log_entry() {
    local ip="$1" reason="$2"
    local full
    full=$(enrich_ip "$ip")
    local ip2 city region region_code country country_code org hostname
    IFS='|' read -r ip2 city region region_code country country_code org hostname <<< "$full"

    local location="Unknown"
    if [[ "$city" == "local network" ]]; then
        location="local network"
    else
        location="$city"
        [[ "$region_code" != "—" && "$region_code" != "?" ]] && location="$location, $region_code"
        [[ "$country" != "—" && "$country" != "?" ]] && location="$location, $country"
    fi

    printf '[%s] [%s] %s — %s | %s | %s — %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S %Z')" "${0##*/}" "$ip" "$location" "$org" "$hostname" "$reason" \
        >> "$ENRICH_LOG" 2>/dev/null || true
}
