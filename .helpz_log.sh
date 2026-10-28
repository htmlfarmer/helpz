# helpz usage tracking — append this tool's invocation to the shared log
[[ -n "${HELPZ_LOGGED:-}" ]] && return 0
HELPZ_LOGGED=1
if [[ -w "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" ]]; then
    printf '%s\t%s\n' "$(date +%s)" "${0##*/} $*" >> "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.helpz_history" 2>/dev/null
fi
