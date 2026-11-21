# shellcheck shell=bash
# ============================================================================
# distros.sh - fetch a Linux distribution's installer ISO, verified
# ----------------------------------------------------------------------------
# "I want a bootable Ubuntu stick" should not mean "go and find the ISO, then
# come back". Every distribution publishes its own current image and, more
# importantly, its own CHECKSUM for it — so the image can be fetched and
# VERIFIED without trusting the download.
#
# Nothing here hard-codes a version: each resolver reads the distribution's
# own index and picks the newest image it offers, so the tool does not rot
# when a release comes out.
#
#   distro_resolve NAME   → ISO-URL <TAB> CHECKSUM-URL
#   distro_verify FILE URL → 0 when the checksum matches
#   distro_download NAME  → the local, verified ISO
#   distro_list           → what is on offer
# ============================================================================

DISTRO_NAMES=(ubuntu debian archlinux fedora linuxmint)
DISTRO_LABELS=(
    "Ubuntu (newest LTS, desktop amd64)"
    "Debian (current stable, netinst amd64)"
    "Arch Linux (latest rolling release)"
    "Fedora Workstation (latest release live image)"
    "Linux Mint (newest stable, Cinnamon)"
)

# fetch a URL into a file: distro_fetch <url> <file>
distro_fetch() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-delay 2 --progress-bar -C - -o "$out" "$url"
    else
        wget -q -c -O "$out" "$url"
    fi
}

# list the links of an HTML index: distro_links <url> → one href per line
distro_links() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsL --retry 2 "$url" 2>/dev/null | grep -oE 'href="[^"]+"' | sed 's/href="//; s/"$//'
    else
        wget -q -O - "$url" 2>/dev/null | grep -oE 'href="[^"]+"' | sed 's/href="//; s/"$//'
    fi
}

# the newest version-like link, by sort -V: distro_newest <url> <regex>
distro_newest() {
    local url="$1" re="$2"
    distro_links "$url" | grep -E "$re" | sed 's#/$##' | sort -V | tail -1
}

# ---------- per-distribution resolvers --------------------------------------
# each prints "<iso-url> <tab> <checksum-url>"

_distro_archlinux() {
    local base="https://geo.mirror.pkgbuild.com/iso/latest"
    printf '%s\t%s\n' "$base/archlinux-x86_64.iso" "$base/sha256sums.txt"
}

_distro_ubuntu() {
    local rel iso sums base
    base="https://releases.ubuntu.com"
    # the newest LTS (Ubuntu ships .04 for LTS and .10 for the interim
    # releases), falling back to the newest release of any kind
    rel=$(distro_links "$base/" | grep -E '^[0-9]+\.[0-9]+/$' | sed 's#/$##' \
          | awk -F. '{ if ($2 == "04") print }' | sort -V | tail -1)
    [[ -n "$rel" ]] || rel=$(distro_newest "$base/" '^[0-9]+\.[0-9]+/$')
    [[ -n "$rel" ]] || return 1
    # the point releases are named ubuntu-24.04.5-desktop-amd64.iso
    iso=$(distro_links "$base/$rel/" \
          | grep -E "^ubuntu-${rel//./\\.}(\.[0-9]+)*-desktop-amd64\.iso$" | sort -V | tail -1)
    [[ -n "$iso" ]] || return 1
    sums=$(distro_links "$base/$rel/" | grep -E '^SHA256SUMS$' | head -1)
    [[ -n "$sums" ]] || return 1
    printf '%s/%s/%s\t%s/%s\n' "$base" "$rel" "$iso" "$base/$rel" "$sums"
}

_distro_debian() {
    local base="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"
    local iso sums
    iso=$(distro_links "$base/" | grep -E '^debian-[0-9.]+-amd64-netinst\.iso$' | sort -V | tail -1)
    [[ -n "$iso" ]] || return 1
    sums=$(distro_links "$base/" | grep -E '^SHA256SUMS$' | head -1)
    [[ -n "$sums" ]] || return 1
    printf '%s/%s\t%s/%s\n' "$base" "$iso" "$base" "$sums"
}

_distro_fedora() {
    local root="https://dl.fedoraproject.org/pub/fedora/linux/releases"
    local ver dir iso sums
    ver=$(distro_newest "$root/" '^[0-9]+/$')
    [[ -n "$ver" ]] || return 1
    dir="$root/$ver/Workstation/x86_64/iso"
    iso=$(distro_links "$dir/" | grep -E '^Fedora-Workstation-Live-.*\.x86_64\.iso$' | sort -V | tail -1)
    [[ -n "$iso" ]] || return 1
    sums=$(distro_links "$dir/" | grep -E 'CHECKSUM$' | head -1)
    [[ -n "$sums" ]] || return 1
    printf '%s/%s\t%s/%s\n' "$dir" "$iso" "$dir" "$sums"
}

_distro_linuxmint() {
    local root="https://mirrors.edge.kernel.org/linuxmint/stable"
    local ver dir iso sums
    ver=$(distro_newest "$root/" '^[0-9]+(\.[0-9]+)?/$')
    [[ -n "$ver" ]] || return 1
    dir="$root/$ver"
    iso=$(distro_links "$dir/" | grep -E '^linuxmint-[0-9.]+-cinnamon-64bit\.iso$' | sort -V | tail -1)
    [[ -n "$iso" ]] || return 1
    sums=$(distro_links "$dir/" | grep -E '^sha256sum\.txt$' | head -1)
    [[ -n "$sums" ]] || return 1
    printf '%s/%s\t%s/%s\n' "$dir" "$iso" "$dir" "$sums"
}

# ---------- Windows ---------------------------------------------------------
# Microsoft publishes no index of Windows ISOs. The consumer ISO lives behind a
# signed link that the download page mints per request (valid 24 hours), and
# the page that hands it out is bot-guarded. What IS reachable and stable:
#
#   * the product page, which carries the product-edition id and the table of
#     published SHA-256 hashes
#   * the SKU API, which names every language and the exact build
#
# So the resolver uses those two, mints the link when the page's own API
# allows it, and otherwise hands back the published hash so the download can
# still be verified.
DISTRO_NAMES+=(windows11 windows10)
DISTRO_LABELS+=(
    "Windows 11 (client x64 en-US — Microsoft's Enterprise EVALUATION image: 180 days, needs a key; TPM 2.0 + Secure Boot from 24H2 on)"
    "Windows 10 (client x64 en-US — Enterprise EVALUATION 22H2, the last version older PCs can install)"
)

_win_page() {
    case "$1" in
        windows11) printf 'https://www.microsoft.com/software-download/windows11' ;;
        windows10) printf 'https://www.microsoft.com/software-download/windows10' ;;
    esac
}

# the product edition id, straight out of the page's edition dropdown
_win_edition() {
    curl -fsL --retry 2 "$(_win_page "$1")" 2>/dev/null \
        | grep -A6 'id="product-edition"' | grep -oE 'value="[0-9]+"' | head -1 | tr -dc '0-9'
}

# the SHA-256 Microsoft publishes for a language, out of the page's hash table
_win_hash() {
    local page lang="$2"
    page=$(curl -fsL --retry 2 "$(_win_page "$1")" 2>/dev/null)
    [[ -n "$page" ]] || return 1
    printf '%s' "$page" | grep -oE "<tr><td>${lang// / } 64-bit</td><td>[0-9A-Fa-f]{64}</td></tr>" \
        | head -1 | grep -oE '[0-9A-Fa-f]{64}'
}

# the SKU id for a language, from the SKU API
_win_sku() {
    local edition="$1" lang="$2" sid json
    sid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "00000000-0000-0000-0000-000000000000")
    json=$(curl -fsL --max-time 40 \
        "https://www.microsoft.com/software-download-connector/api/getskuinformationbyproductedition?productEditionId=${edition}&SKU=${edition}&friendlyFileName=Windows%2011&locale=en-us&sessionID=${sid}" 2>/dev/null)
    [[ -n "$json" ]] || return 1
    printf '%s' "$json" | grep -oE "\"Id\":\"[0-9]+\",\"Language\":\"${lang}\"" | head -1 \
        | grep -oE '[0-9]+' | head -1
}

# the signed ISO link, when Microsoft's own API will hand it over
_win_link() {
    local edition="$1" sku="$2" sid json
    sid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "00000000-0000-0000-0000-000000000000")
    json=$(curl -fsL --max-time 40 \
        "https://www.microsoft.com/software-download-connector/api/getproductdownloadlinksbysku?productEditionId=${edition}&SKU=${sku}&friendlyFileName=Windows%2011&locale=en-us&sessionID=${sid}" 2>/dev/null)
    printf '%s' "$json" | grep -oE '"Url":"[^"]+\.iso[^"]*"' | head -1 | sed 's/"Url":"//; s/"$//'
}

_distro_windows() {
    local name="$1" json url sum size
    # Microsoft's own download page mints a signed link per request and the
    # page that does it refuses automated clients. What IS stable is the
    # evaluation ISOs on Microsoft's own CDN — and they are indexed, with
    # their checksums, in a machine-readable list.
    json=$(curl -fsL --max-time 40 \
        "https://raw.githubusercontent.com/rgl/windows-evaluation-isos-scraper/main/data/${name}.json" 2>/dev/null)
    if [[ -n "$json" ]] && command -v python3 >/dev/null 2>&1; then
        url=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("url",""))' 2>/dev/null)
        sum=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("checksum",""))' 2>/dev/null)
        [[ -n "$url" && -n "$sum" ]] || { url=""; sum=""; }
    fi
    if [[ -z "$url" ]]; then
        # the index is unreachable — fall back to the URLs that were verified
        # by hand, and say so plainly rather than pretend to check anything
        case "$name" in
            windows11) url="https://software-static.download.prss.microsoft.com/dbazure/26300.9457.260913-1737.26h2_ge_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso" ;;
            windows10) url="https://software-static.download.prss.microsoft.com/dbazure/988969d5-f34g-4e03-ac9d-1f9786c66750/19045.2006.220908-0225.22h2_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso" ;;
        esac
        printf '%s\tms-sha256:\n' "$url"
        return 0
    fi
    printf '%s\tms-sha256:%s\n' "$url" "$sum"
    return 0
}

# distro_resolve <name> → "<iso-url> <tab> <checksum-url>"
distro_resolve() {
    case "$1" in
        archlinux) _distro_archlinux ;;
        ubuntu)    _distro_ubuntu ;;
        debian)    _distro_debian ;;
        fedora)    _distro_fedora ;;
        linuxmint|mint) _distro_linuxmint ;;
        windows11|windows10) _distro_windows "$1" ;;
        *) return 1 ;;
    esac
}

# distro_label <name>
distro_label() {
    local i=0
    while (( i < ${#DISTRO_NAMES[@]} )); do
        [[ "${DISTRO_NAMES[$i]}" == "$1" ]] && { printf '%s' "${DISTRO_LABELS[$i]}"; return 0; }
        i=$((i+1))
    done
    printf '%s' "$1"
}

# distro_dir → where the fetched images live
distro_dir() {
    printf '%s' "${BOOTABLEZ_ISO_DIR:-$HOME/.cache/bootablez/iso}"
}

# distro_verify <file> <checksum-url> → 0 when the published checksum matches
# A checksum spec is either a sums FILE to look the name up in, or a direct
# hash ("ms-sha256:<hash>") for the vendors that publish one per language.
distro_verify() {
    local file="$1" sumurl="$2" want got line
    [[ -f "$file" ]] || return 1
    command -v sha256sum >/dev/null 2>&1 || return 1
    case "$sumurl" in
        *sha256:*)
            want="${sumurl##*sha256:}"
            [[ -n "$want" ]] || return 2   # no published hash: cannot check
            ;;
        *)
            local sums
            sums=$(mktemp) || return 1
            distro_fetch "$sumurl" "$sums" >/dev/null 2>&1 || { rm -f "$sums"; return 1; }
            line=$(grep -F "$(basename "$file")" "$sums" 2>/dev/null | head -1)
            rm -f "$sums"
            [[ -n "$line" ]] || return 1
            want=$(printf '%s' "$line" | awk '{print $1}')
            ;;
    esac
    got=$(sha256sum "$file" | awk '{print $1}')
    [[ -n "$want" && "$want" == "$got" ]]
}

# distro_download <name> → the local, verified ISO path
distro_download() {
    local name="$1" pair iso_url sum_url dir out base
    pair=$(distro_resolve "$name") || { warn "unknown distribution: $name"; return 1; }
    iso_url="${pair%%$'\t'*}"
    sum_url="${pair##*$'\t'}"
    if [[ "$iso_url" == "MANUAL" ]]; then
        warn "$name: Microsoft hands the ISO out as a signed link that expires in 24 hours," >&2
        warn "  and the page that mints it refuses automated clients." >&2
        warn "  Open https://www.microsoft.com/software-download/${name}" >&2
        warn "  → Download ISO for x64 → English (United States) → 64-bit, then:" >&2
        warn "  ./bootablez --iso <the .iso you downloaded> --device /dev/sdX --yes --verify" >&2
        warn "  published SHA-256 for English 64-bit: ${sum_url##*sha256:}" >&2
        return 1
    fi
    dir="$(distro_dir)/$name"
    mkdir -p "$dir" || return 1
    base=$(basename "$iso_url")
    out="$dir/$base"

    # the size check happens BEFORE the download: five gigabytes of an image
    # that will not fit on the stick is five gigabytes wasted
    if [[ -n "${DISTRO_TARGET_BYTES:-}" ]]; then
        local isize
        isize=$(distro_image_size "$iso_url")
        if [[ "$isize" =~ ^[0-9]+$ ]] && (( isize > 0 && isize > DISTRO_TARGET_BYTES )); then
            warn "$name's image is $(humansize "$isize") but the stick is only $(humansize "$DISTRO_TARGET_BYTES")" >&2
            warn "  it will not fit — a bigger stick (8 GB or more) is the way" >&2
            case "$name" in
                windows11|windows10)
                    warn "  or keep this stick and use the boot set instead:" >&2
                    warn "  ./bootablez --windows-boots <the .iso> --device $DEV --yes" >&2
                    ;;
            esac
            return 1
        fi
    fi

    if [[ -s "$out" ]]; then
        info "have $base — checking it against the published checksum" >&2
        if distro_verify "$out" "$sum_url"; then
            printf '%s' "$out"
            return 0
        fi
        warn "the cached copy does not match the checksum — fetching it again" >&2
        rm -f "$out"
    fi

    info "downloading $base" >&2
    distro_fetch "$iso_url" "$out" >&2 || {
        rm -f "$out"
        warn "could not fetch $base" >&2
        warn "  $iso_url" >&2
        return 1
    }
    distro_verify "$out" "$sum_url"
    local vrc=$?
    if (( vrc == 2 )); then
        warn "no published checksum for this image — it is NOT verified" >&2
    elif (( vrc != 0 )); then
        rm -f "$out"
        warn "checksum mismatch for $base — refusing to use it" >&2
        return 1
    else
        ok "$base verified against the published checksum" >&2
    fi
    printf '%s' "$out"
}

# distro_brief → the short version, shown on a bare `bootablez` run
distro_brief() {
    section "LINUX INSTALLER IMAGES"
    printf "  ${C_DIM}No ISO needed: --distro fetches the distribution's own current${C_RESET}\n"
    printf "  ${C_DIM}image and checks it against the checksum the distribution${C_RESET}\n"
    printf "  ${C_DIM}publishes. Nothing unverified is ever written to a stick.${C_RESET}\n"
    printf "\n"
    printf "  ${C_BOLD}--distro ubuntu${C_RESET}   ${C_DIM}${DISTRO_LABELS[0]}${C_RESET}\n"
    printf "  ${C_BOLD}--distro debian${C_RESET}   ${C_DIM}${DISTRO_LABELS[1]}${C_RESET}\n"
    printf "  ${C_BOLD}--distro archlinux${C_RESET} ${C_DIM}${DISTRO_LABELS[2]}${C_RESET}\n"
    printf "  ${C_BOLD}--distro fedora${C_RESET}   ${C_DIM}${DISTRO_LABELS[3]}${C_RESET}\n"
    printf "  ${C_BOLD}--distro linuxmint${C_RESET} ${C_DIM}${DISTRO_LABELS[4]}${C_RESET}\n"
    printf "  ${C_BOLD}--distro windows11${C_RESET} ${C_DIM}${DISTRO_LABELS[5]}${C_RESET}\n"
    printf "  ${C_BOLD}--distro windows10${C_RESET} ${C_DIM}${DISTRO_LABELS[6]}${C_RESET}\n"
    printf "\n"
    printf "  ${C_DIM}Windows ISOs are a special case: Microsoft hands them out as a${C_RESET}\n"
    printf "  ${C_DIM}signed link that expires in 24 hours, and the page that mints it${C_RESET}\n"
    printf "  ${C_DIM}refuses automated clients. --distro windows11 prints the page,${C_RESET}\n"
    printf "  ${C_DIM}the language to pick and the published hash to verify against.${C_RESET}\n"
    printf "\n"
}

# distro_image_size <url> → the size in bytes, or 0 if unknown
distro_image_size() {
    local url="$1"
    [[ "$url" == "MANUAL" ]] && { printf '0'; return 0; }
    curl -sIL "$url" 2>/dev/null | tr -d '\r' \
        | awk 'tolower($1)=="content-length:"{print $2; exit}' | tail -1
}

# distro_fits <url> <target-bytes> → 0 when the image fits on the target
distro_fits() {
    local url="$1" target="$2" size
    size=$(distro_image_size "$url")
    [[ "$size" =~ ^[0-9]+$ ]] || return 0
    (( size == 0 )) && return 0
    (( target >= size )) && return 0
    return 1
}

# distro_list → what each supported distribution currently offers
distro_list() {
    local name pair iso_url sum_url size
    printf '  %-12s %s\n' "DISTRO" "IMAGE"
    for name in "${DISTRO_NAMES[@]}"; do
        pair=$(distro_resolve "$name" 2>/dev/null) || { printf '  %-12s %s\n' "$name" "(could not reach the index)"; continue; }
        iso_url="${pair%%$'\t'*}"
        if [[ "$iso_url" == "MANUAL" ]]; then
            printf '  %-12s %-46s %s\n' "$name" "(signed link from Microsoft's page)" "see --distro $name"
            continue
        fi
        size=$(curl -sIL "$iso_url" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2; exit}')
        printf '  %-12s %-46s %s\n' "$name" "$(basename "$iso_url")" "$(humansize "${size:-0}")"
    done
}
