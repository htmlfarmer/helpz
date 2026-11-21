# shellcheck shell=bash
# ============================================================================
# macos.sh - macOS installer media support for bootablez
# ----------------------------------------------------------------------------
# Apple's macOS installers are not ISO files and not plain disk images:
#
#   * a .dmg is a UDIF container wrapping a disk image. Writing the .dmg to a
#     stick with dd gives a stick that will NOT boot - the payload inside is
#     compressed. It has to be unwrapped first (lib/macimg.py dmg2raw).
#   * the unwrapped image holds a GPT with an Apple HFS+ volume, and the volume
#     carries /System/Library/CoreServices/boot.efi - the startup file the Mac
#     firmware loads. That is what makes the stick bootable.
#   * the full offline installer also needs the OS payload (InstallESD.dmg)
#     INSIDE the HFS+ volume, at
#     "Install macOS X.app/Contents/SharedSupport/". No dd can put a file
#     inside a filesystem, so that step needs a mounted HFS+ volume.
#
# So there are three things this file knows how to do:
#
#   macos_catalog        fetch Apple's software-update catalog
#   macos_products       list the macOS installer media it offers (version, size)
#   macos_download VER   download the media for a macOS version
#   macos_build VER OUT  assemble a bootable macOS disk image (offline)
#   macos_boot_help      the boot keys, for Mac and PC keyboards alike
#
# The catalog is the source of truth: Apple's own index lists every macOS
# installer still on the CDN with its exact build, so no URL is ever hard
# coded here and a version that Apple drops simply stops being offered.
# ============================================================================

MACOS_CATALOG_URLS=(
    "https://swscan.apple.com/content/catalogs/others/index-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog.gz"
    "https://swscan.apple.com/content/catalogs/others/index-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog.gz"
    "https://swscan.apple.com/content/catalogs/others/index-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog.gz"
)

# macimg_script → path to the helper that unwraps Apple's .dmg files
#
# The helper is Python, but this suite publishes lib/*.sh only, so it travels
# inside this file and is written out on first use.
macimg_script() {
    local dir out
    dir=$(macos_dir 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}")
    mkdir -p "$dir" 2>/dev/null || dir="${TMPDIR:-/tmp}"
    out="$dir/macimg.py"
    if ! grep -q 'macimg version: 2' "$out" 2>/dev/null; then
        cat > "$out" <<'MACIMG_PY_EOF'
# macimg version: 2
"""macimg — helper for Apple's macOS installer media, used by bootablez.

Three jobs, all pure stdlib (no dmg2img, no 7-Zip needed):

  probe <file>            what is this file?  iso9660 | udif | macos | raw
  dmg2raw <in.dmg> <out>   Apple UDIF (.dmg) -> raw disk image
  pkgextract <pkg> <name> <out>
                          pull one file out of an Apple flat package (.pkg)

The .dmg support matters because Apple's own installers are UDIF containers
wrapping a disk image, and a UDIF is NOT a disk image: writing it to a stick
with dd produces a stick that will not boot. It has to be unwrapped first.

Two UDIF block layouts exist and both are handled:

  * "container" (current) — one `mish` container per partition, each with its
    own header; descriptor sector_start values are RELATIVE to the container's
    first_sector.
  * "classic" (older)     — one `mish` blob holding every chunk of one blkx
    entry; descriptor sector_start values are ABSOLUTE.

They are told apart by validating the descriptors against the header rather
than by trusting a magic number.
"""
import base64
import gzip
import io
import os
import plistlib
import re
import struct
import sys
import tarfile
import xml.etree.ElementTree as ET
import zlib

# UDIF block types
ZERO, RAW, IGNORE = 0x00000000, 0x00000001, 0x00000002
ZLIB, BZIP2, LZFSE, LZMA, COMMENT = 0x80000005, 0x80000006, 0x80000007, 0x80000008, 0xFFFFFFFF
MISH_HEADER = 84      # bytes of mish header before the descriptor table
DESC_LEN = 40         # bytes per descriptor


# --------------------------------------------------------------------------- #
# UDIF reading
# --------------------------------------------------------------------------- #
def read_udif(path):
    """→ (data_fork_offset, blocks) where blocks is a list of dicts."""
    size = os.path.getsize(path)
    with open(path, 'rb') as f:
        f.seek(-512, 2)
        koly = f.read(512)
        if koly[:4] != b'koly':
            raise ValueError('not a UDIF image (no koly trailer)')
        data_off, data_len = struct.unpack('>QQ', koly[24:40])
        xml_off, xml_len = struct.unpack('>QQ', koly[216:232])
        f.seek(xml_off)
        plist = plistlib.loads(f.read(xml_len))

    blocks = []
    rsrc = plist.get('resource-fork', {})
    for entry in rsrc.get('blkx', []):
        for name, blob in entry.items():
            if not isinstance(blob, bytes):
                continue
            blocks.extend(parse_blkx(blob, name))
    blocks.sort(key=lambda b: b['sector'])
    return data_off, blocks


def parse_blkx(blob, name):
    """A blkx entry is either a mish container (bytes) or classic XML."""
    out = []
    if blob[:4] == b'mish':
        out.extend(parse_mish_container(blob, name))
    else:
        # classic: XML plist holding <blkx><data>…base64 mish…</data></blkx>
        try:
            inner = plistlib.loads(blob)
        except Exception:
            return out
        for chunk in inner.get('blkx', []):
            data = chunk.get('Data')
            if not data:
                continue
            if isinstance(data, str):
                data = base64.b64decode(data)
            if data[:4] == b'mish':
                out.extend(parse_mish_classic(data, chunk.get('Name', name)))
    return out


def mish_header(blob):
    """→ (first_sector, sector_count, desc_start)."""
    first_sector, sector_count = struct.unpack('>QQ', blob[8:24])
    return first_sector, sector_count


def parse_mish_container(blob, name):
    """One container = one partition; descriptors are relative to first_sector."""
    first_sector, sector_count = mish_header(blob)
    out = []
    for i in range((len(blob) - MISH_HEADER) // DESC_LEN):
        p = MISH_HEADER + DESC_LEN * i
        t, _cmt = struct.unpack('>II', blob[p:p + 8])
        ss, sc, co, cl = struct.unpack('>QQQQ', blob[p + 8:p + 40])
        out.append(dict(type=t, sector=first_sector + ss, sectors=sc,
                        coff=co, clen=cl, name=name))
    return out


def parse_mish_classic(blob, name):
    """Classic layout: one blob, many chunks, absolute sector numbers."""
    first_sector, sector_count = mish_header(blob)
    out = []
    for i in range((len(blob) - MISH_HEADER) // DESC_LEN):
        p = MISH_HEADER + DESC_LEN * i
        t, _cmt = struct.unpack('>II', blob[p:p + 8])
        ss, sc, co, cl = struct.unpack('>QQQQ', blob[p + 8:p + 40])
        # classic descriptors are absolute; if they look relative, add the base
        if ss < first_sector:
            ss += first_sector
        out.append(dict(type=t, sector=ss, sectors=sc, coff=co, clen=cl, name=name))
    return out


def udif_to_raw(dmg, out):
    data_off, blocks = read_udif(dmg)
    total = sum(b['sectors'] for b in blocks if b['type'] != COMMENT)
    total_bytes = total * 512
    print(f'{os.path.basename(dmg)}: {len(blocks)} blocks, {total} sectors, '
          f'{total_bytes:,} bytes ({total_bytes / 1e9:.2f} GB)')
    with open(dmg, 'rb') as f, open(out, 'wb') as o:
        o.truncate(total_bytes)
        for b in blocks:
            t = b['type']
            if t == COMMENT:
                continue
            start = b['sector'] * 512
            length = b['sectors'] * 512
            if t == ZERO:
                continue
            if t == IGNORE:
                continue
            if t == RAW:
                f.seek(data_off + b['coff'])
                o.seek(start)
                left = b['clen']
                while left > 0:
                    chunk = f.read(min(1 << 20, left))
                    if not chunk:
                        raise ValueError('unexpected EOF in the data fork')
                    o.write(chunk)
                    left -= len(chunk)
            elif t == ZLIB:
                f.seek(data_off + b['coff'])
                raw = zlib.decompress(f.read(b['clen']))
                if len(raw) != length:
                    raise ValueError(f'block mismatch at sector {b["sector"]}: '
                                     f'{len(raw)} != {length}')
                o.seek(start)
                o.write(raw)
            else:
                raise ValueError(f'unsupported block type 0x{t:08x}')
    print(f'wrote {out}: {total_bytes:,} bytes')


# --------------------------------------------------------------------------- #
# Flat package (.pkg / XAR)
# --------------------------------------------------------------------------- #
def xar_toc(path):
    """→ (toc_xml, heap_base)."""
    with open(path, 'rb') as f:
        head = f.read(64)
        if head[:4] != b'xar!':
            raise ValueError('not a XAR archive')
        start = head.find(b'\x78\xda')
        if start < 0:
            start = head.find(b'\x78\x9c')
        if start < 0:
            raise ValueError('no zlib TOC in the header')
        f.seek(start)
        d = zlib.decompressobj()
        out = bytearray()
        consumed = 0
        while not d.eof:
            chunk = f.read(1 << 20)
            if not chunk:
                break
            out += d.decompress(chunk)
            consumed += len(chunk)
        consumed -= len(d.unused_data)
        return bytes(out), start + consumed


def xar_entries(toc_xml):
    root = ET.fromstring(toc_xml)
    toc = root.find('toc')
    if toc is None:
        toc = root
    out = {}

    def walk(node, prefix):
        for child in node.findall('file'):
            name = child.findtext('name')
            data = child.find('data')
            if data is None:
                continue
            out[prefix + name] = dict(
                enc=data.findtext('encoding'),
                size=int(data.findtext('size') or 0),
                offset=int(data.findtext('offset') or 0),
                length=int(data.findtext('length') or 0))
            walk(child, prefix + name + '/')
    walk(toc, '')
    return out


def pkg_extract(pkg, wanted, out):
    toc_xml, heap_base = xar_toc(pkg)
    entries = xar_entries(toc_xml)
    if wanted not in entries:
        raise ValueError(f'{wanted} not in the package; it holds: {list(entries)[:10]}')
    e = entries[wanted]
    with open(pkg, 'rb') as f:
        f.seek(heap_base + e['offset'])
        blob = f.read(e['length'])
    if e['enc'] in ('application/x-gzip', 'application/gzip'):
        blob = gzip.decompress(blob)
    if len(blob) > 262 and blob[257:262] == b'ustar':
        with tarfile.open(fileobj=io.BytesIO(blob)) as tf:
            for nm in tf.getnames():
                if os.path.basename(nm) == wanted:
                    data = tf.extractfile(nm).read()
                    with open(out, 'wb') as o:
                        o.write(data)
                    print(f'wrote {out}: {len(data):,} bytes')
                    return
        raise ValueError(f'{wanted} not inside the payload tar')
    with open(out, 'wb') as o:
        o.write(blob)
    print(f'wrote {out}: {len(blob):,} bytes')


# --------------------------------------------------------------------------- #
# probe
# --------------------------------------------------------------------------- #
def is_iso(path):
    try:
        with open(path, 'rb') as f:
            f.seek(32769)
            return f.read(5) == b'CD001'
    except OSError:
        return False


def is_udif(path):
    try:
        size = os.path.getsize(path)
        if size < 512:
            return False
        with open(path, 'rb') as f:
            f.seek(-512, 2)
            return f.read(4) == b'koly'
    except OSError:
        return False


def gpt_map(path):
    """→ list of (start_lba, end_lba, type_guid, name) for a GPT image."""
    out = []
    try:
        with open(path, 'rb') as f:
            f.seek(512)
            hdr = f.read(512)
        if hdr[:8] != b'EFI PART':
            return out
        entry_lba, = struct.unpack('<Q', hdr[72:80])
        num, esz = struct.unpack('<II', hdr[80:88])
        with open(path, 'rb') as f:
            f.seek(entry_lba * 512)
            table = f.read(num * esz)
        for i in range(num):
            e = table[i * esz:(i + 1) * esz]
            if e[:16] == b'\x00' * 16:
                continue
            first, last = struct.unpack('<QQ', e[32:48])
            name = e[56:128].decode('utf-16-le', errors='replace').rstrip('\x00')
            out.append((first, last, guid_str(e[:16]), name))
    except OSError:
        pass
    return out


def guid_str(raw):
    """GPT stores type GUIDs mixed-endian; render them the canonical way."""
    if len(raw) != 16:
        return ''
    a, = struct.unpack('<I', raw[0:4])
    b, = struct.unpack('<H', raw[4:6])
    c, = struct.unpack('<H', raw[6:8])
    d = raw[8:16].hex().upper()
    return f'{a:08X}-{b:04X}-{c:04X}-{d[0:4]}-{d[4:16]}'


APPLE_HFS_GUID = '48465300-0000-11AA-AA11-00306543ECAC'
APPLE_HFS_PLUS = APPLE_HFS_GUID
APPLE_EFI_GUID = 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B'


def probe(path):
    size = os.path.getsize(path)
    kind = 'raw'
    detail = ''
    if is_iso(path):
        kind = 'iso9660'
    elif is_udif(path):
        kind = 'udif'
        try:
            _off, blocks = read_udif(path)
            total = sum(b['sectors'] for b in blocks if b['type'] != COMMENT)
            detail = f'udif {total * 512:,} bytes uncompressed'
        except Exception as exc:
            detail = f'udif (unreadable: {exc})'
    else:
        parts = gpt_map(path)
        apple = [p for p in parts if p[2] == APPLE_HFS_GUID]
        if apple:
            kind = 'macos'
            first, last, _g, name = apple[0]
            detail = (f'macOS volume at LBA {first}..{last} '
                       f'({(last - first + 1) * 512 / 1e9:.2f} GB)')
            for pat, label in ((b'Install macOS', 'installer app'),
                               (b'boot.efi', 'boot.efi'),
                               (b'com.apple.recovery.boot', 'recovery folder')):
                if find_bytes(path, pat) >= 0:
                    detail += f', has {label}'
            # will it BOOT a Mac? two ways: an EFI system partition carrying
            # a loader, or the HFS+ volume carrying the startup file
            # (/System/Library/CoreServices/boot.efi). Apple's own installer
            # disk images have an EMPTY EFI partition — writing one of those
            # to a stick gives a stick that does not boot.
            bootable = 0
            for p0, p1, guid, _pn in parts:
                if guid == APPLE_EFI_GUID:
                    if find_bytes(path, b'.efi', limit=(p1 + 1) * 512) >= 0:
                        bootable = 1
            if not bootable and find_bytes(path, b'boot.efi') >= 0:
                bootable = 1
            print(f'boot={bootable}')
    print(f'kind={kind}')
    print(f'size={size}')
    print(f'detail={detail}')
    for first, last, guid, name in gpt_map(path):
        print(f'part={first},{last},{guid},{name}')


def find_bytes(path, needle, limit=None):
    """First offset of `needle` in the file, or -1."""
    try:
        with open(path, 'rb') as f:
            while True:
                chunk = f.read(1 << 22)
                if not chunk:
                    return -1
                i = chunk.find(needle)
                if i >= 0:
                    return f.tell() - len(chunk) + i
                if limit and f.tell() > limit:
                    return -1
    except OSError:
        return -1


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    cmd = sys.argv[1]
    if cmd == 'dmg2raw' and len(sys.argv) == 4:
        udif_to_raw(sys.argv[2], sys.argv[3])
    elif cmd == 'pkgextract' and len(sys.argv) == 5:
        pkg_extract(sys.argv[2], sys.argv[3], sys.argv[4])
    elif cmd == 'probe' and len(sys.argv) == 3:
        probe(sys.argv[2])
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
MACIMG_PY_EOF
    fi
    printf '%s' "$out"
}

# macos_dir → where media is cached
macos_dir() {
    printf '%s' "${BOOTABLEZ_MACOS_DIR:-$HOME/.cache/bootablez/macos}"
}

macos_have_python() {
    command -v python3 >/dev/null 2>&1
}

macos_have_curl() {
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1
}

# fetch a URL into a file: macos_fetch <url> <file>
macos_fetch() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 2 -C - -o "$out" "$url" 2>/dev/null
    else
        wget -q -c -O "$out" "$url" 2>/dev/null
    fi
}

# macos_fetch_catalog → cache the catalog(s), echo the paths
# Every era of macOS lives in its own merged catalog, and the newer ones do
# not list the older versions — so all of them are fetched and the product
# lists are merged.
macos_fetch_catalog() {
    local dir url cache n=0
    dir=$(macos_dir)
    mkdir -p "$dir" 2>/dev/null || return 1
    for url in "${MACOS_CATALOG_URLS[@]}"; do
        n=$((n+1))
        cache="$dir/catalog-$n.sucatalog.gz"
        if [[ ! -s "$cache" ]]; then
            macos_fetch "$url" "$cache" || { rm -f "$cache"; continue; }
        fi
        [[ -s "$cache" ]] && printf '%s\n' "$cache"
    done
    return 0
}

# macos_products <catalog>... → TSV: id, installinfo-url, basesystem-url, esd-url
# macos_products uses python3 to read Apple's plist catalog
macos_products() {
    macos_have_python || return 1
    python3 - "$@" <<'PY' 2>/dev/null
import gzip, plistlib, re, sys

seen = set()
for path in sys.argv[1:]:
    try:
        with gzip.open(path, 'rb') as f:
            cat = plistlib.loads(f.read())
    except Exception:
        continue
    for pid, prod in cat.get('Products', {}).items():
        if not isinstance(prod, dict):
            continue
        if pid in seen:
            continue
        pkgs = prod.get('Packages') or []
        urls = {}
        for p in pkgs:
            if not isinstance(p, dict):
                continue
            u = p.get('URL', '')
            if not u:
                continue
            name = u.rsplit('/', 1)[-1]
            if name in ('BaseSystem.dmg', 'InstallESDDmg.pkg', 'InstallESD.dmg',
                        'InstallInfo.plist', 'BaseSystem.chunklist',
                        'AppleDiagnostics.dmg', 'AppleDiagnostics.chunklist'):
                urls[name] = u
        if 'BaseSystem.dmg' not in urls or 'InstallInfo.plist' not in urls:
            continue
        esd = urls.get('InstallESDDmg.pkg') or urls.get('InstallESD.dmg')
        if not esd:
            continue
        seen.add(pid)
        print('\t'.join([pid, urls['InstallInfo.plist'], urls['BaseSystem.dmg'], esd]))
PY
}

# macos_version <installinfo.plist> → the marketing version, e.g. 10.13
macos_version() {
    macos_have_python || return 1
    python3 - "$1" <<'PY' 2>/dev/null
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    p = plistlib.loads(f.read())
v = (p.get('System Image Info') or {}).get('version', '')
parts = v.split('.')
print('.'.join(parts[:2]) if len(parts) >= 2 else v)
PY
}

# macos_list → the macOS versions Apple's catalog offers, with sizes
macos_list() {
    local row id info_url base_url esd_url dir tmp ver
    local -a catalogs
    macos_have_python || { warn "macos: needs python3 to read Apple's catalog"; return 1; }
    macos_have_curl || { warn "macos: needs curl or wget"; return 1; }
    mapfile -t catalogs < <(macos_fetch_catalog) || true
    [[ ${#catalogs[@]} -gt 0 ]] || { warn "macos: cannot reach Apple's catalog"; return 1; }
    dir=$(macos_dir); mkdir -p "$dir"
    printf '  %-9s %-9s %s\n' "VERSION" "SIZE" "BUILD"
    while IFS=$'\t' read -r id info_url base_url esd_url; do
        [[ -n "$info_url" ]] || continue
        tmp="$dir/.info-$id.plist"
        macos_fetch "$info_url" "$tmp" || continue
        ver=$(macos_version "$tmp")
        [[ -n "$ver" ]] || { rm -f "$tmp"; continue; }
        local esd_size=0
        esd_size=$(curl -sI "$esd_url" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2; exit}')
        printf '  %-9s %-9s %s\n' "$ver" \
            "$(humansize "${esd_size:-0}")" "$id"
        rm -f "$tmp"
    done < <(macos_products "${catalogs[@]}")
}

# macos_download <version> → fetch the media into the cache; echoes the dir
macos_download() {
    local want="$1" row id info_url base_url esd_url dir tmp ver
    local -a catalogs
    macos_have_python || { warn "macos: needs python3"; return 1; }
    macos_have_curl || { warn "macos: needs curl or wget"; return 1; }
    mapfile -t catalogs < <(macos_fetch_catalog) || true
    [[ ${#catalogs[@]} -gt 0 ]] || { warn "macos: cannot reach Apple's catalog"; return 1; }
    dir=$(macos_dir); mkdir -p "$dir"

    # find the product whose InstallInfo.plist says the version we want
    local found_id="" found_info="" found_base="" found_esd=""
    while IFS=$'\t' read -r id info_url base_url esd_url; do
        [[ -n "$info_url" ]] || continue
        tmp="$dir/.info-$id.plist"
        macos_fetch "$info_url" "$tmp" || continue
        ver=$(macos_version "$tmp")
        if [[ "$ver" == "$want" || "$ver" == "$want."* ]]; then
            found_id="$id"; found_info="$info_url"; found_base="$base_url"; found_esd="$esd_url"
            rm -f "$tmp"; break
        fi
        rm -f "$tmp"
    done < <(macos_products "${catalogs[@]}")
    [[ -n "$found_id" ]] || { warn "macos: Apple's catalog does not offer macOS $want"; return 1; }

    local out="$dir/$want"
    mkdir -p "$out"
    # messages go to stderr: stdout of this function IS the returned path
    info "macOS $want → $out" >&2

    local base="$found_base"
    local name
    for name in BaseSystem.dmg BaseSystem.chunklist InstallInfo.plist AppleDiagnostics.dmg; do
        if [[ -s "$out/$name" ]]; then
            info "have $name" >&2
            continue
        fi
        info "downloading $name …" >&2
        macos_fetch "$base/$name" "$out/$name" || { warn "macos: failed to fetch $name"; return 1; }
    done

    # the payload ships as a flat package; the DMG inside it is the real image
    if [[ ! -s "$out/InstallESD.dmg" ]]; then
        if [[ ! -s "$out/InstallESDDmg.pkg" ]]; then
            info "downloading InstallESDDmg.pkg (this is the big one, several GB) …" >&2
            macos_fetch "$found_esd" "$out/InstallESDDmg.pkg" || { warn "macos: failed to fetch the payload"; return 1; }
        fi
        info "unpacking InstallESD.dmg from the package …" >&2
        python3 "$(macimg_script)" pkgextract "$out/InstallESDDmg.pkg" InstallESD.dmg "$out/InstallESD.dmg" \
            >&2 || { warn "macos: could not unpack the payload"; return 1; }
    fi

    printf '%s' "$out"
}

# macos_build <version-dir> <out.img> → assemble a bootable macOS disk image
#
# The result is a GPT disk image with ONE Apple HFS+ partition holding the
# whole recovery/install system plus the payload inside the installer's
# SharedSupport — the same thing Apple's createinstallmedia puts on a stick,
# built without a Mac.
#
# It is built as a FILE, not straight onto the stick, so that the normal
# write path (rails, progress, verify) still applies to it.
macos_build() {
    local src="$1" out="$2"
    macos_have_python || { warn "macos: needs python3"; return 1; }
    command -v mkfs.hfsplus >/dev/null 2>&1 || {
        warn "macos: needs hfsprogs for mkfs.hfsplus (sudo apt install hfsprogs)"
        return 1
    }
    command -v sfdisk >/dev/null 2>&1 || { warn "macos: needs sfdisk (util-linux)"; return 1; }

    # 1. the recovery system, unwrapped to a bare HFS+ volume
    local raw="$src/.recovery.raw"
    [[ -s "$raw" ]] || python3 "$(macimg_script)" dmg2raw "$src/BaseSystem.dmg" "$raw" >&2 || return 1

    # 2. a fresh HFS+ volume, big enough for the recovery system AND the payload
    local payload=0 f
    for f in "$src/InstallESD.dmg" "$src/BaseSystem.dmg" "$src/AppleDiagnostics.dmg"; do
        [[ -f "$f" ]] && payload=$(( payload + $(stat -c %s -- "$f" 2>/dev/null || echo 0) ))
    done
    local vol="$src/.volume.hfs"
    local vol_bytes=$(( $(stat -c %s -- "$raw" 2>/dev/null || echo 0) + payload + 1073741824 ))
    rm -f "$vol"
    truncate -s "$vol_bytes" "$vol"
    mkfs.hfsplus -v "OS X Base System" "$vol" || { warn "macos: mkfs.hfsplus failed"; return 1; }

    # 3. copy the recovery system in, then drop the payload where the
    #    installer looks for it
    local mnt_base="$src/.mnt-base" mnt_out="$src/.mnt-out"
    mkdir -p "$mnt_base" "$mnt_out"
    sudo_run mount -o loop,ro "$raw" "$mnt_base" || { warn "macos: could not mount the recovery volume"; return 1; }
    sudo_run mount -t hfsplus "$vol" "$mnt_out" || {
        sudo_run umount "$mnt_base"; warn "macos: could not mount the HFS+ volume"; return 1; }
    sudo_run cp -rT --no-preserve=xattr,ownership "$mnt_base/." "$mnt_out/" 2>/dev/null || true
    local app
    app=$(sudo_run find "$mnt_out" -maxdepth 1 -name 'Install macOS *.app' 2>/dev/null | head -1)
    if [[ -n "$app" ]]; then
        sudo_run mkdir -p "$app/Contents/SharedSupport"
        sudo_run cp "$src/InstallESD.dmg" "$src/BaseSystem.dmg" \
              "$src/BaseSystem.chunklist" "$src/InstallInfo.plist" \
              "$src/AppleDiagnostics.dmg" "$app/Contents/SharedSupport/" 2>/dev/null || true
    else
        warn "macos: no 'Install macOS *.app' in the recovery volume — the install would not be offline"
    fi
    sudo_run umount "$mnt_out"
    sudo_run umount "$mnt_base"
    sudo_run rm -rf "$mnt_base" "$mnt_out"

    # 4. lay the volume into a GPT disk image, as the single Apple HFS+ partition
    rm -f "$out"
    truncate -s "$(( vol_bytes + 1073741824 ))" "$out"
    printf ',,48465300-0000-11AA-AA11-00306543ECAC\n' | sfdisk --quiet --label=gpt "$out" 2>/dev/null
    local start
    start=$(sfdisk -l -o Start "$out" 2>/dev/null | sed -n '2p' | tr -d ' ')
    [[ "$start" =~ ^[0-9]+$ ]] || { warn "macos: could not lay out the image"; return 1; }
    dd if="$vol" of="$out" bs=512 seek="$start" conv=notrunc,sparse status=none
    return 0
}

# macos_brief → the short version, shown on a bare `bootablez` run so the
# macOS route is discoverable without knowing any flags
macos_brief() {
    section "MACOS INSTALLER MEDIA"
    printf "  ${C_DIM}Apple's installers are not ISO files. A .dmg is a UDIF${C_RESET}\n"
    printf "  ${C_DIM}container around a disk image — dd-ing it to a stick gives${C_RESET}\n"
    printf "  ${C_DIM}a stick that will not boot. bootablez unwraps it for you.${C_RESET}\n"
    printf "\n"
    printf "  ${C_BOLD}--macos-list${C_RESET}          ${C_DIM}what macOS versions Apple's catalog still offers${C_RESET}\n"
    printf "  ${C_BOLD}--macos-download 10.13${C_RESET}  ${C_DIM}fetch that version's installer media${C_RESET}\n"
    printf "  ${C_BOLD}--macos-build 10.13${C_RESET}    ${C_DIM}assemble a bootable offline image, then write it${C_RESET}\n"
    printf "\n"
    printf "  ${C_DIM}booting a Mac from a stick:${C_RESET}\n"
    macos_boot_help
    printf "\n"
}

# macos_boot_help → the boot keys, for a Mac keyboard and a PC one
macos_boot_help() {
    printf "  ${C_BOLD}Intel Mac:${C_RESET} hold ${C_BOLD}Option (⌥)${C_RESET} while powering on\n"
    printf "     ${C_DIM}on a PC keyboard that key is ${C_RESET}${C_BOLD}Alt${C_RESET}${C_DIM} — the one next to the space bar${C_RESET}\n"
    printf "     ${C_DIM}then pick the stick in the Startup Manager (arrow keys + Enter)${C_RESET}\n"
    printf "  ${C_BOLD}Apple Silicon:${C_RESET} hold the ${C_BOLD}Power${C_RESET} button until \"Loading startup options\"\n"
    printf "  ${C_DIM}· the volume shows up as the only external drive; pick it${C_RESET}\n"
    printf "  ${C_DIM}· 2018–2020 Intel Macs with a T2 chip refuse external boot${C_RESET}\n"
    printf "  ${C_DIM}  until Secure Boot is lowered in Recovery${C_RESET}\n"
    printf "  ${C_DIM}· ⌘R boots the Mac's OWN recovery instead of the stick — that is${C_RESET}\n"
    printf "  ${C_DIM}  the path to use if the internal disk still has a Recovery HD${C_RESET}\n"
}
