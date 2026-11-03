#!/usr/bin/env bash
# ============================================================================
# lib/kernelbest.sh — "latest best kernel" intelligence for kernelz
# ----------------------------------------------------------------------------
# Answers the question the tool never used to answer:
#
#     "do I have the best kernel I could be running?"
#
# The rule implemented here (and only here — kernelz stays thin):
#
#   • NOT the very latest      a release that landed days ago is untested
#   • the latest THAT IS tested  it must have had time to bake
#   • NOT the long-term branch  LTS is the safe fallback, not the goal
#
# How "tested" is judged, best effort, degrading gracefully when offline:
#
#   1. age of the exact upstream release the package carries
#      (kernel.org ChangeLog header date)
#   2. maturity of the upstream series it belongs to (X.Y.0 release date)
#   3. the stable tree's own "Tested-by:" roster — the number of people who
#      actually tested that release before it shipped (reported, not ranked)
#
# Everything network-derived is cached under ~/.kernelz/cache so a second run
# is instant and an offline run still works from the cache.
# ============================================================================

# How long a release must have existed before we call it settled/trusted.
# Override with --settle N on the command line or KERNELZ_SETTLE_DAYS=NN.
KB_SETTLE_DAYS="${KERNELZ_SETTLE_DAYS:-14}"

KB_JSON_URL="https://www.kernel.org/releases.json"
KB_CDN_BASE="https://cdn.kernel.org/pub/linux/kernel"

# Which package manager is this system using? The verdict has to work on
# every Linux, not just Debian/Ubuntu.
kb_pkg_mgr() {
    if   command -v apt-get >/dev/null 2>&1; then printf 'deb'
    elif command -v dnf     >/dev/null 2>&1; then printf 'rpm'
    elif command -v yum     >/dev/null 2>&1; then printf 'rpm'
    elif command -v rpm     >/dev/null 2>&1; then printf 'rpm'
    elif command -v pacman  >/dev/null 2>&1; then printf 'pacman'
    else printf 'none'; fi
}

KB_ONLINE=0            # 1 once kernel.org answered at least once
KB_UPSTREAM_OK=0       # releases.json parsed into the series tables

declare -A KB_SER_LATEST=()    # 6.1 -> 6.1.191     newest upstream release of the series
declare -A KB_SER_DATE=()      # 6.1 -> 1793...      epoch of that release
declare -A KB_SER_ISO=()       # 6.1 -> 2026-10-30
declare -A KB_SER_MONIKER=()   # 6.1 -> longterm
declare -A KB_SER_EOL=()       # 6.1 -> 0/1          series reached end-of-life
KB_STABLE_VER=""               # current upstream stable, e.g. 7.3.1
KB_STABLE_ISO=""
KB_STABLE_DATE=0
KB_STABLE_SER=""               # its series, e.g. 7.3
KB_LTS_LIST=""                 # "6.18.60 6.12.115 ..." newest of each LTS branch

# candidate kernel images the repositories offer
declare -a KB_C_PKG=() KB_C_VER=() KB_C_ABI=() KB_C_SERIES=() KB_C_UP=()
declare -a KB_C_DATE=() KB_C_TIER=() KB_C_SUITE=() KB_C_FLAV=() KB_C_NOTE=()

# the verdict
KB_BEST_PKG="" KB_BEST_VER="" KB_BEST_ABI="" KB_BEST_SERIES="" KB_BEST_UP=""
KB_BEST_DATE=0 KB_BEST_TIER=0 KB_BEST_NOTE=""
KB_NEW_PKG="" KB_NEW_VER="" KB_NEW_ABI="" KB_NEW_SERIES="" KB_NEW_UP="" KB_NEW_DATE=0

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------
kb_cache_dir() {
    local d="${STATE_USR:-$HOME/.kernelz}/cache"
    mkdir -p "$d" 2>/dev/null || true
    printf '%s' "$d"
}

kb_key() {   # url -> stable cache key
    local k
    k=$(printf '%s' "$1" | sha1sum 2>/dev/null | cut -d' ' -f1)
    [[ -z "$k" ]] && k=$(printf '%s' "$1" | cksum 2>/dev/null | tr -d ' \n')
    printf '%s' "$k"
}

kb_dl() {   # url dest [range]
    local url="$1" dest="$2" range="${3:-}"
    local rc=1
    if command -v curl >/dev/null 2>&1; then
        if [[ -n "$range" ]]; then
            curl -fsSL --max-time 45 --range "$range" "$url" -o "$dest" 2>/dev/null && rc=0
        else
            curl -fsSL --max-time 90 "$url" -o "$dest" 2>/dev/null && rc=0
        fi
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 45 -O "$dest" "$url" 2>/dev/null && rc=0
    fi
    return $rc
}

kb_cache_file() {   # url ttl -> path on stdout (cached), non-zero on failure
    local url="$1" ttl="${2:-86400}"
    local dir key f age
    dir=$(kb_cache_dir)
    key=$(kb_key "$url")
    f="$dir/$key"
    if [[ -f "$f" ]]; then
        age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
        if (( age < ttl )); then printf '%s' "$f"; return 0; fi
    fi
    if kb_dl "$url" "$f.tmp.$$"; then
        mv -f "$f.tmp.$$" "$f" 2>/dev/null && { printf '%s' "$f"; return 0; }
    fi
    rm -f "$f.tmp.$$" 2>/dev/null
    # stale cache is better than nothing (offline runs)
    [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
    return 1
}

kb_cache_head() {   # url -> path with just the first few KB (cached)
    local url="$1" dir key f
    dir=$(kb_cache_dir)
    key=$(kb_key "$url")
    f="$dir/$key.head"
    if [[ ! -s "$f" ]]; then
        if ! kb_dl "$url" "$f.tmp.$$" "0-8191"; then
            rm -f "$f.tmp.$$" 2>/dev/null
            return 1
        fi
        mv -f "$f.tmp.$$" "$f" 2>/dev/null || { rm -f "$f.tmp.$$" 2>/dev/null; return 1; }
    fi
    printf '%s' "$f"
}

# ---------------------------------------------------------------------------
# upstream release table (kernel.org/releases.json)
# ---------------------------------------------------------------------------
kb_load_upstream() {
    [[ "$KB_UPSTREAM_OK" -eq 1 ]] && return 0
    local f rels line ver mon ts iso eol ser
    f=$(kb_cache_file "$KB_JSON_URL" 21600) || return 1
    [[ -s "$f" ]] || return 1

    if command -v jq >/dev/null 2>&1; then
        rels=$(jq -r '
            .releases[]
            | select((.version // "") | test("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$"))
            | "\(.version)|\(.moniker // "")|\(.released.timestamp // 0)|\(.released.isodate // "")|\(.iseol // false)"
        ' "$f" 2>/dev/null)
    elif command -v python3 >/dev/null 2>&1; then
        rels=$(python3 - "$f" 2>/dev/null <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for r in d.get("releases", []):
    v = str(r.get("version") or "")
    p = v.split(".")
    if len(p) < 2 or not p[0].isdigit() or not p[1].isdigit():
        continue
    rel = r.get("released") or {}
    print("%s|%s|%s|%s|%s" % (
        v, r.get("moniker") or "", rel.get("timestamp") or 0,
        rel.get("isodate") or "", "1" if r.get("iseol") else "0"))
PY
)
    fi
    [[ -z "$rels" ]] && return 1

    while IFS='|' read -r ver mon ts iso eol; do
        [[ -z "$ver" ]] && continue
        # jq hands back true/false, the python fallback 1/0 — normalise
        [[ "$eol" == "true" ]] && eol=1
        [[ "$eol" == "false" || -z "$eol" ]] && eol=0
        ser=$(printf '%s' "$ver" | cut -d. -f1,2)
        # keep the newest release of each series
        if [[ -n "${KB_SER_LATEST[$ser]:-}" ]] \
           && [[ "$(printf '%s\n%s\n' "${KB_SER_LATEST[$ser]}" "$ver" | sort -V | tail -1)" != "$ver" ]]; then
            continue
        fi
        KB_SER_LATEST[$ser]="$ver"
        KB_SER_DATE[$ser]="${ts:-0}"
        KB_SER_ISO[$ser]="$iso"
        KB_SER_MONIKER[$ser]="$mon"
        KB_SER_EOL[$ser]="${eol:-0}"
    done <<< "$rels"

    # current stable = newest "stable" moniker release that is not EOL
    local best="" bver="" bmon=""
    for ser in "${!KB_SER_LATEST[@]}"; do
        bver="${KB_SER_LATEST[$ser]}"; bmon="${KB_SER_MONIKER[$ser]}"
        [[ "$bmon" == "stable" && "${KB_SER_EOL[$ser]}" != "1" ]] || continue
        if [[ -z "$best" ]] || [[ "$(printf '%s\n%s\n' "$best" "$bver" | sort -V | tail -1)" == "$bver" ]]; then
            best="$bver"
            KB_STABLE_ISO="${KB_SER_ISO[$ser]}"
            KB_STABLE_DATE="${KB_SER_DATE[$ser]}"
            KB_STABLE_SER="$ser"
        fi
    done
    KB_STABLE_VER="$best"

    # LTS branches, newest first
    KB_LTS_LIST=""
    local ltsv
    for ser in "${!KB_SER_LATEST[@]}"; do
        [[ "${KB_SER_MONIKER[$ser]}" == "longterm" || "${KB_SER_MONIKER[$ser]}" == "lts" ]] || continue
        ltsv="${KB_SER_LATEST[$ser]}"
        KB_LTS_LIST="${KB_LTS_LIST}${ltsv} "
    done
    KB_LTS_LIST=$(printf '%s\n' $KB_LTS_LIST | sort -Vr | paste -sd' ' -)

    KB_UPSTREAM_OK=1
    KB_ONLINE=1
    return 0
}

kb_series_is_lts() {   # series -> 0/1
    local m="${KB_SER_MONIKER[$1]:-}"
    [[ "$m" == "longterm" || "$m" == "lts" ]] && { printf '1'; return 0; }
    # Fallback for offline runs: the well-known upstream long-term branches.
    # Used only when the release table could not be fetched at all.
    if [[ "$KB_UPSTREAM_OK" -eq 0 ]]; then
        case "$1" in
            3.2|3.4|4.4|4.9|4.14|4.19|5.4|5.10|5.15|6.1|6.6|6.12|6.18|6.24|7.6)
                printf '1'; return 0 ;;
        esac
    fi
    printf '0'
}

# When was this branch OPENED? The first entry of the branch's changelog is
# the X.Y.0 release commit, so its Date is the branch's birth date — the
# honest measure of "how long has this branch been out and tested".
kb_series_birth() {   # series -> epoch
    local ser="${1:-}" maj base f d e
    [[ -z "$ser" ]] && return 1
    maj="${ser%%.*}"
    for base in "v${maj}.x" "v${ser}"; do
        f=$(kb_cache_head "$KB_CDN_BASE/$base/ChangeLog-$ser") || continue
        [[ -s "$f" ]] || continue
        d=$(grep -m1 -E '^Date:' "$f" 2>/dev/null | sed 's/^Date:[[:space:]]*//')
        [[ -z "$d" ]] && continue
        e=$(kb_parse_date "$d") || continue
        [[ -n "$e" ]] && { printf '%s' "$e"; return 0; }
    done
    return 1
}

# Is this branch finished upstream?
#
# kernel.org's feed lists every branch that is still maintained (the current
# stable plus all long-term branches) and flags the ones that just went
# end-of-life. A branch that has dropped out of the feed altogether is
# finished — that is how the 7.0 branch looks today, and it MUST be
# excluded or it would outrank the current stable simply by being older.
kb_series_is_eol() {   # series [release epoch] -> 0/1
    local ser="$1" date="${2:-}" age
    [[ "${KB_SER_EOL[$ser]:-0}" == "1" ]] && { printf '1'; return 0; }
    if [[ "$KB_UPSTREAM_OK" -eq 1 ]]; then
        # not in the feed = upstream no longer maintains it
        [[ -z "${KB_SER_LATEST[$ser]:-}" ]] && { printf '1'; return 0; }
        printf '0'; return 0
    fi
    # offline: fall back to the age of the release we have
    if [[ "$date" =~ ^[0-9]+$ ]] && (( date > 0 )); then
        age=$(( ( $(date +%s) - date ) / 86400 ))
        (( age >= KB_EOL_DAYS )) && { printf '1'; return 0; }
    fi
    printf '0'
}

# ---------------------------------------------------------------------------
# version helpers
# ---------------------------------------------------------------------------
kb_pkg_upstream() {   # package version -> upstream release (best effort)
    local v="${1:-}"
    [[ -z "$v" ]] && return 1
    v="${v#*:}"                  # drop epoch
    v="${v%%-*}"                 # drop packaging revision
    if [[ "$v" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then printf '%s' "$v"; return 0; fi
    # distribution tag glued onto the version: 6.10.1.arch1 / 6.11.4.fc41
    if [[ "$v" =~ ^([0-9]+(\.[0-9]+)+)\.[a-z]+[0-9]+$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"; return 0
    fi
    return 1
}

kb_series_of() {     # "6.1.176" -> "6.1"
    local v="${1:-}"
    [[ "$v" =~ ^[0-9]+\.[0-9]+ ]] || return 1
    printf '%s' "$(printf '%s' "$v" | cut -d. -f1,2)"
}

kb_patch_level() {   # "6.1.176" -> 176 ; "6.8.0" -> 0
    local v="${1:-}"
    printf '%s' "$(printf '%s' "$v" | cut -d. -f3)"
}

kb_age_days() {      # epoch -> whole days (negative = in the future)
    local e="${1:-0}" now
    [[ "$e" =~ ^[0-9]+$ ]] || { printf '99999'; return 0; }
    now=$(date +%s)
    printf '%s' "$(( (now - e) / 86400 ))"
}

kb_tz_off() {        # "+0200" -> 7200 ; "-0500" -> -18000
    local o="$1" sign=1 h m
    case "$o" in
        -*) sign=-1; o="${o#-}" ;;
        +*) o="${o#+}" ;;
    esac
    o="${o:0:4}"
    [[ "$o" =~ ^[0-9]{4}$ ]] || { printf '0'; return 0; }
    h=$((10#${o:0:2})); m=$((10#${o:2:2}))
    printf '%s' "$(( sign * (h * 3600 + m * 60) ))"
}

# The kernel ChangeLog date looks like:
#   Date:   Fri Jun 19 13:37:33 2026 +0200
# GNU date refuses the trailing "+0200", so peel it off and do the offset
# arithmetic by hand.
kb_parse_date() {    # "Fri Jun 19 13:37:33 2026 +0200" -> epoch
    local s="${1:-}" off="" naive loc g=0
    [[ -z "$s" ]] && return 1
    if [[ "$s" =~ ([+-][0-9]{4})[[:space:]]*$ ]]; then
        off="${BASH_REMATCH[1]}"
        s="${s% $off}"
    fi
    s="${s%"${s##*[![:space:]]}"}"
    naive=$(date -d "$s" +%s 2>/dev/null) || return 1
    loc=$(kb_tz_off "$(date +%z)")
    [[ -n "$off" ]] && g=$(kb_tz_off "$off")
    printf '%s' "$(( naive - loc - g ))"
}

kb_upstream_date() {  # upstream release (or series) -> epoch of its release date
    local up="${1:-}" maj ser base f d e
    [[ -z "$up" ]] && return 1
    maj="${up%%.*}"
    ser=$(kb_series_of "$up") || return 1
    # The exact release first.
    for base in "v${maj}.x" "v${ser}"; do
        f=$(kb_cache_head "$KB_CDN_BASE/$base/ChangeLog-$up") || continue
        [[ -s "$f" ]] || continue
        d=$(grep -m1 -E '^Date:' "$f" 2>/dev/null | sed 's/^Date:[[:space:]]*//')
        [[ -z "$d" ]] && continue
        e=$(kb_parse_date "$d") || continue
        [[ -n "$e" ]] && { printf '%s' "$e"; return 0; }
    done
    # Fall back to the SERIES changelog. This matters on Ubuntu-style
    # packaging: the ABI is X.Y.0 (7.0.0-42-generic), and X.Y.0 is not an
    # upstream release — the branch changelog is what exists. Its date is
    # when the branch was born, which is exactly the maturity signal we want.
    for base in "v${maj}.x" "v${ser}"; do
        f=$(kb_cache_head "$KB_CDN_BASE/$base/ChangeLog-$ser") || continue
        [[ -s "$f" ]] || continue
        d=$(grep -m1 -E '^Date:' "$f" 2>/dev/null | sed 's/^Date:[[:space:]]*//')
        [[ -z "$d" ]] && continue
        e=$(kb_parse_date "$d") || continue
        [[ -n "$e" ]] && { printf '%s' "$e"; return 0; }
    done
    return 1
}

# ---------------------------------------------------------------------------
# repository candidates
# ---------------------------------------------------------------------------
kb_repo_candidates() {
    KB_C_PKG=(); KB_C_VER=(); KB_C_ABI=(); KB_C_SERIES=(); KB_C_UP=()
    KB_C_DATE=(); KB_C_TIER=(); KB_C_SUITE=(); KB_C_FLAV=(); KB_C_NOTE=()
    local mgr; mgr=$(kb_pkg_mgr)
    case "$mgr" in
        deb)    kb_candidates_deb ;;
        rpm)    kb_candidates_rpm ;;
        pacman) kb_candidates_pacman ;;
        *) return 0 ;;
    esac

    # rank every candidate into a tier
    local i
    for ((i = 0; i < ${#KB_C_PKG[@]}; i++)); do
        KB_C_TIER[i]=$(kb_tier "${KB_C_SERIES[i]}" "${KB_C_DATE[i]}")
        KB_C_NOTE[i]=$(kb_tier_note "${KB_C_SERIES[i]}" "${KB_C_DATE[i]}" "${KB_C_TIER[i]}")
    done
}

# ---------- Debian / Ubuntu ----------
kb_candidates_deb() {
    local listing
    listing=$(apt list -a 'linux-image-*' 2>/dev/null | awk 'NR>1 && NF>=2 {print $1" "$2}')
    [[ -z "$listing" ]] && return 0

    local name ver suite rest abi flavour key
    local -A chosen=() flavour_of=()
    while read -r name ver; do
        [[ -z "$name" || -z "$ver" ]] && continue
        suite="${name#*/}"; name="${name%%/*}"
        [[ "$name" == linux-image-* ]] || continue
        rest="${name#linux-image-}"
        # strip the architecture suffix so "6.1.0-50-cloud-amd64" -> "6.1.0-50-cloud"
        case "$rest" in
            *-amd64)   rest="${rest%-amd64}" ;;
            *-arm64)   rest="${rest%-arm64}" ;;
            *-armhf)   rest="${rest%-armhf}" ;;
            *-i386)    rest="${rest%-i386}" ;;
            *-ppc64el) rest="${rest%-ppc64el}" ;;
            *-s390x)   rest="${rest%-s390x}" ;;
            *-riscv64) rest="${rest%-riscv64}" ;;
            *-loong64) rest="${rest%-loong64}" ;;
        esac
        [[ "$rest" =~ ^[0-9] ]] || continue
        if [[ "$rest" =~ ^([0-9]+(\.[0-9]+)*-[0-9]+)(-([a-zA-Z0-9-]+))?$ ]]; then
            abi="${BASH_REMATCH[1]}"
            flavour="${BASH_REMATCH[4]}"
        else
            continue
        fi
        key="$abi|$ver"
        # one representative per ABI+version: prefer the un-flavoured image
        if [[ -z "${chosen[$key]:-}" ]]; then
            chosen[$key]="$name"; flavour_of[$key]="$flavour"
        elif [[ -z "${flavour_of[$key]}" && -n "$flavour" ]]; then
            continue
        elif [[ -n "${flavour_of[$key]}" && -z "$flavour" ]]; then
            chosen[$key]="$name"; flavour_of[$key]="$flavour"
        fi
    done <<< "$listing"

    local n=0 ver
    for key in "${!chosen[@]}"; do
        abi="${key%%|*}"
        ver="${key#*|}"
        kb_add_candidate "${chosen[$key]}" "$ver" "$abi" "" "${flavour_of[$key]}" "stable" "$n"
        n=$((n + 1))
    done
}

# ---------- Fedora / RHEL / openSUSE (rpm) ----------
kb_candidates_rpm() {
    local q; q=$(command -v dnf >/dev/null 2>&1 && echo dnf || echo yum)
    local out
    out=$(timeout 90 "$q" -q repoquery --available --qf '%{name} %{epoch}:%{version}-%{release}' \
           'kernel*' 2>/dev/null | grep -vE '^kernel-(devel|modules|headers|tools|docs|debuginfo|perf|src|mlk5|pa|scsi|selinux|signing|debug|extra|firmware|abi|config|dtb|cmake|libpfm|ntfs|tools-devel|unstable)' )
    [[ -z "$out" ]] && out=$(timeout 90 "$q" -q list available 'kernel*' 2>/dev/null | awk 'NF>2{print $1" "$2}')
    [[ -z "$out" ]] && return 0

    local name ver abi n=0
    while read -r name ver; do
        [[ -z "$name" || -z "$ver" ]] && continue
        case "$name" in
            kernel|kernel-core|kernel-default|kernel-desktop|kernel-latest|linux) ;;
            *) continue ;;
        esac
        ver="${ver#*:}"                     # drop the epoch
        abi="$ver"
        kb_add_candidate "$name" "$ver" "$abi" "" "" "rpm" "$n"
        n=$((n + 1))
    done <<< "$out"
}

# ---------- Arch / Manjaro ----------
kb_candidates_pacman() {
    local out
    out=$(timeout 60 pacman -Si linux 2>/dev/null | awk -F': *' '/^Version/{print $2}')
    [[ -z "$out" ]] && return 0
    kb_add_candidate "linux" "$out" "$out" "" "" "arch" 0
}

# Register one candidate and resolve its upstream release + date.
kb_add_candidate() {   # pkg ver abi upstream-hint flavour suite index
    local pkg="$1" ver="$2" abi="$3" up="$4" flavour="$5" suite="$6" n="$7"
    local ser date
    if [[ -z "$up" ]]; then
        up=$(kb_pkg_upstream "$ver") || up=""
    fi
    if [[ -n "$up" ]]; then
        ser=$(kb_series_of "$up") || ser=""
    else
        ser=$(printf '%s' "${abi%%-*}" | cut -d. -f1,2)
    fi
    [[ -n "$ser" ]] || return 0
    date=$(kb_upstream_date "$up") || date=""
    KB_C_PKG[n]="$pkg"; KB_C_VER[n]="$ver"; KB_C_ABI[n]="$abi"
    KB_C_SERIES[n]="$ser"; KB_C_UP[n]="$up"; KB_C_DATE[n]="$date"
    KB_C_SUITE[n]="$suite"; KB_C_FLAV[n]="$flavour"
    return 0
}

# tier 1 = the goal: a live, non-LTS (regular stable) branch that has been
#          out long enough to be trusted
# tier 2 = a live, non-LTS branch that is still fresh
# tier 3 = a long-term branch — the safe fallback, explicitly not the goal
# tier 4 = finished upstream (end-of-life) — never recommended
#
# The settle window is measured against the BRANCH's birth date (the X.Y.0
# release), not against the newest patch: a branch that opened 3 months ago
# and got a patch 2 days ago is a mature branch, and the newest regular
# stable branch is exactly what we want to move to.
KB_EOL_DAYS=90          # a release this old means the branch is finished
kb_tier() {   # series release_date -> tier
    local series="$1" date="$2" age lts eol
    lts=$(kb_series_is_lts "$series")
    eol=$(kb_series_is_eol "$series" "$date")
    (( eol == 1 )) && { printf '4'; return 0; }
    (( lts == 1 )) && { printf '3'; return 0; }
    age=$(kb_series_age_days "$series") || age=0
    if (( age >= KB_SETTLE_DAYS )); then printf '1'; return 0; fi
    printf '2'; return 0
}

kb_series_age_days() {   # series -> days since the branch opened
    local b
    b=$(kb_series_birth "${1:-}") || return 1
    printf '%s' "$(( ( $(date +%s) - b ) / 86400 ))"
}

kb_tier_note() {   # series date tier -> short label
    local series="$1" date="$2" tier="$3" age
    case "$tier" in
        4) printf 'finished upstream (end-of-life)'; return 0 ;;
        3)
            age=$(kb_series_age_days "$series") || age=0
            printf 'LTS branch, out %dd' "$age"; return 0 ;;
    esac
    age=$(kb_series_age_days "$series") || age=0
    case "$tier" in
        1) printf 'regular stable, branch out %dd' "$age" ;;
        2) printf 'regular stable but branch only %dd old — fresh' "$age" ;;
        *) printf 'unknown' ;;
    esac
}

kb_tier_label() {  # tier -> headline word
    case "$1" in
        1) printf 'LATEST STABLE (tested)' ;;
        2) printf 'LATEST STABLE (still fresh)' ;;
        3) printf 'LONG-TERM (safe, not the goal)' ;;
        4) printf 'END-OF-LIFE' ;;
        *) printf 'UNKNOWN' ;;
    esac
}

# ---------------------------------------------------------------------------
# the verdict
# ---------------------------------------------------------------------------
kb_recommend() {
    kb_load_upstream || true
    kb_repo_candidates

    KB_BEST_PKG=""; KB_BEST_VER=""; KB_BEST_ABI=""; KB_BEST_SERIES=""
    KB_BEST_UP=""; KB_BEST_DATE=0; KB_BEST_TIER=0; KB_BEST_NOTE=""
    KB_NEW_PKG=""; KB_NEW_VER=""; KB_NEW_ABI=""; KB_NEW_SERIES=""
    KB_NEW_UP=""; KB_NEW_DATE=0

    local i best_i=-1 new_i=-1
    local best_tier=99
    local best_date=-1 best_ver=""

    for ((i = 0; i < ${#KB_C_PKG[@]}; i++)); do
        local t="${KB_C_TIER[i]}" d="${KB_C_DATE[i]:-0}" v="${KB_C_VER[i]}"
        # newest available (ignores the tier rules) — for the "very latest" line
        if [[ "$new_i" -lt 0 ]] || kb_better "$d" "$v" "${KB_C_DATE[new_i]:-0}" "${KB_C_VER[new_i]}"; then
            new_i=$i
        fi
        # best = lowest tier, then newest within the tier
        if (( t < best_tier )) || { (( t == best_tier )) && kb_better "$d" "$v" "$best_date" "$best_ver"; }; then
            best_tier=$t; best_i=$i; best_date="$d"; best_ver="$v"
        fi
    done

    if (( best_i >= 0 )); then
        KB_BEST_PKG="${KB_C_PKG[best_i]}"
        KB_BEST_VER="${KB_C_VER[best_i]}"
        KB_BEST_ABI="${KB_C_ABI[best_i]}"
        KB_BEST_SERIES="${KB_C_SERIES[best_i]}"
        KB_BEST_UP="${KB_C_UP[best_i]}"
        KB_BEST_DATE="${KB_C_DATE[best_i]:-0}"
        KB_BEST_TIER="${KB_C_TIER[best_i]}"
        KB_BEST_NOTE="${KB_C_NOTE[best_i]}"
    fi
    if (( new_i >= 0 )); then
        KB_NEW_PKG="${KB_C_PKG[new_i]}"
        KB_NEW_VER="${KB_C_VER[new_i]}"
        KB_NEW_ABI="${KB_C_ABI[new_i]}"
        KB_NEW_SERIES="${KB_C_SERIES[new_i]}"
        KB_NEW_UP="${KB_C_UP[new_i]}"
        KB_NEW_DATE="${KB_C_DATE[new_i]:-0}"
    fi
    return 0
}

# is candidate A "newer" than candidate B? (by date, then by version)
kb_better() {   # dateA verA dateB verB -> 0 when A is newer
    local da="${1:-0}" va="${2:-}" db="${3:-0}" vb="${4:-}"
    [[ "$da" =~ ^[0-9]+$ ]] || da=0
    [[ "$db" =~ ^[0-9]+$ ]] || db=0
    if (( da > db )); then return 0; fi
    if (( da < db )); then return 1; fi
    if [[ -z "$va" ]]; then return 1; fi
    if [[ -z "$vb" ]]; then return 0; fi
    [[ "$(printf '%s\n%s\n' "$va" "$vb" | sort -V | tail -1)" == "$va" && "$va" != "$vb" ]]
}

# ---------------------------------------------------------------------------
# release facts for "what is fixed in that kernel"
# ---------------------------------------------------------------------------
kb_release_changelog() {   # upstream release (or series) -> path to its ChangeLog
    local up="${1:-}" maj ser base f
    [[ -z "$up" ]] && return 1
    maj="${up%%.*}"
    ser=$(kb_series_of "$up") || return 1
    # exact release
    for base in "v${maj}.x" "v${ser}"; do
        f=$(kb_cache_file "$KB_CDN_BASE/$base/ChangeLog-$up" 604800) || continue
        [[ -s "$f" ]] && { printf '%s' "$f"; return 0; }
    done
    # series-wide changelog (Ubuntu-style X.Y.0 ABIs land here)
    for base in "v${maj}.x" "v${ser}"; do
        f=$(kb_cache_file "$KB_CDN_BASE/$base/ChangeLog-$ser" 604800) || continue
        [[ -s "$f" ]] && { printf '%s' "$f"; return 0; }
    done
    return 1
}

# Is the changelog we found the whole branch rather than one release?
kb_changelog_is_series() {   # upstream release -> 0/1
    local up="${1:-}" ser
    ser=$(kb_series_of "$up") || return 1
    [[ "$up" == "$ser" ]] && { printf '1'; return 0; }
    # the exact release exists only if its own changelog was published
    local maj="${up%%.*}" base
    for base in "v${maj}.x" "v${ser}"; do
        local f; f=$(kb_cache_file "$KB_CDN_BASE/$base/ChangeLog-$up" 604800) || continue
        [[ -s "$f" ]] && { printf '0'; return 0; }
    done
    printf '1'
    return 0
}

kb_commit_subjects() {   # changelog -> "sha<TAB>subject" per commit
    awk '
        /^commit /{sha=$2}
        /^Date:[ \t]*/{getline; while ($0 == "") getline; sub(/^[ \t]+/,""); print sha"\t"$0}
    ' "$1" 2>/dev/null
}

kb_release_facts() {   # upstream release -> "commits|testers|cve1,cve2"
    local up="$1" f commits testers cves
    f=$(kb_release_changelog "$up") || { printf '0|0|'; return 1; }
    commits=$(grep -c '^commit ' "$f" 2>/dev/null || echo 0)
    testers=$(grep -c 'Tested-by:' "$f" 2>/dev/null || echo 0)
    cves=$(grep -Eo 'CVE-[0-9]{4}-[0-9]{4,7}' "$f" 2>/dev/null | sort -u | paste -sd, -)
    printf '%s|%s|%s' "$commits" "$testers" "$cves"
}

kb_highlights() {   # changelog -> notable security-relevant commit subjects
    local f="$1" kw='CVE|use-after-free|use after free|double free|out-of-bounds|out of bounds|overflow|underflow|privilege escalation|authentication bypass|bypass|refcount|null pointer|null-ptr|NULL pointer|memory leak|information leak|data leak|security|vulnerab|exploit|arbitrary|spectre|meltdown|TOCTOU|race condition|denial of service|hardening|unprivileged|stack corruption|heap corruption'
    kb_commit_subjects "$f" \
        | grep -Ei "$kw" \
        | cut -f2- \
        | sed 's/^[ \t]*//' \
        | awk 'length($0) > 12 && length($0) < 200' \
        | awk '!seen[$0]++' \
        | head -12
}

# ---------------------------------------------------------------------------
# reporting helpers
# ---------------------------------------------------------------------------
kb_running_series() {
    local up; up=$(kb_pkg_upstream "$REL") || up=""
    if [[ -n "$up" ]]; then kb_series_of "$up"; return 0; fi
    printf '%s' "$(printf '%s' "$REL" | grep -oE '^[0-9]+\.[0-9]+' | head -1)"
}

kb_running_upstream() {
    local up; up=$(kb_pkg_upstream "$REL") || up=""
    printf '%s' "$up"
}

kb_fmt_date() {   # epoch -> "2026-06-19"
    [[ "${1:-0}" =~ ^[0-9]+$ ]] || { printf 'unknown'; return 0; }
    (( "$1" > 0 )) || { printf 'unknown'; return 0; }
    date -d "@$1" '+%Y-%m-%d' 2>/dev/null || printf 'unknown'
}

kb_fmt_age() {    # epoch -> "136 days" / "unknown"
    local e="${1:-0}"
    if [[ ! "$e" =~ ^[0-9]+$ ]] || (( e <= 0 )); then printf 'unknown'; return 0; fi
    printf '%s days' "$(( ( $(date +%s) - e ) / 86400 ))"
}

kb_fmt_age_old() {   # epoch -> "136 days old" / "age unknown"
    local e="${1:-0}"
    if [[ ! "$e" =~ ^[0-9]+$ ]] || (( e <= 0 )); then printf 'age unknown'; return 0; fi
    printf '%s days old' "$(( ( $(date +%s) - e ) / 86400 ))"
}
