#!/usr/bin/env bash
# ============================================================================
# lib/guard.sh — pre-commit / pre-push secret & personal-file guard
# ----------------------------------------------------------------------------
# Single source of truth for the patterns behind:
#   • secretz --gate [staged|range]        (manual/suite use)
#   • the global git hooks installed by `helpz guard` (any repo, any dir)
#
# Blocks three things:
#   1. credential-shaped strings in what you're about to commit/push
#   2. known personal/private PATHS sneaking in (force-added ignored files,
#      reports, key material, trust state, business/personal tools)
#   3. tracked files that match the blocklist (pre-push catches history)
#
# Bypass once:  SECRET_GUARD_OK=1 git commit ...
# Per-repo line allowlist: .secret-guard-ignore (grep -vE patterns)
# ============================================================================

GUARD_SECRET_RE='-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|gh[ourps]_[A-Za-z0-9]{36}|xox[bpars]-[A-Za-z0-9-]{10,}|sk-(live|test|proj)-[A-Za-z0-9_\-]{20,}|AIza[0-9A-Za-z_-]{35}|ya29\.[0-9A-Za-z_-]{25,}|eyJ[A-Za-z0-9_-]{12,}\.eyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{8,}|[0-9]{8,10}:AA[A-Za-z0-9_-]{30,}|hooks\.slack\.com/services/T[A-Za-z0-9]+/B[A-Za-z0-9]+/[A-Za-z0-9]+|whsec_[A-Za-z0-9]{16,}|GOCSPX-[A-Za-z0-9_-]{16,}|hf_[A-Za-z0-9]{30,}|[a-z][a-z0-9+.-]{2,10}://[^/[:space:]:@]+:[^/[:space:]@]{6,}@|Basic[[:space:]]+["'"'"']?[A-Za-z0-9+/=]{16,}|Buffer\.from\(["'"'"'][A-Za-z0-9_.+-]{2,30}:[^"'"'"'[:space:]]{8,}["'"'"']\)|b64decode\(["'"'"'][A-Za-z0-9+/]{20,}={0,2}["'"'"']\)|(password|passwd|pwd|secret|token|api[_-]?key|apikey|client[_-]?secret|access[_-]?key)[A-Za-z0-9_-]*["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9+_./=:-]{12,}'

# path tokens: substring match against staged/tracked paths
# NOTE: the backup dir token below is deliberately narrow — it blocks the
# local backup directory a business-specific tool writes, without blocking
# the tool names themselves.
GUARD_BLOCK_TOKENS='-reports/ _reports/ .trustz/ ai.json .env id_rsa id_ed25519 .kdbx .pcap .pftrace .pem .key .p12 .pfx .netrc secrets. secure.csv O3.txt .helpz_history xyzoservicesz-backups .aws/ .gnupg/ .kube/config docker/config.json .git-credentials'

# Template/config files are non-secret by convention: ai.json.example,
# config.yaml.sample, .env.template … never carry live credentials.
GUARD_SAFE_SUFFIX_RE='\.(example|sample|template|dist|default)$|\.example\.'

guard_log() { printf '  guard: %s\n' "$*" >&2; }

guard_allow() {   # repo-root .secret-guard-ignore regex lines filter
    local allowfile="${1:-}/.secret-guard-ignore"
    [[ -r "$allowfile" ]] && cat "$allowfile" || true
}

guard_paths_check() {   # list of paths on stdin → echoes offenders
    local f tok base
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        # .example/.sample/.template files are templates by definition — skip.
        base="$(basename "$f")"
        [[ "$base" =~ $GUARD_SAFE_SUFFIX_RE ]] && continue
        for tok in $GUARD_BLOCK_TOKENS; do
            [[ "$f" == *"$tok"* ]] && { printf '%s\n' "$f"; break; }
        done
    done
}

guard_secrets_check() { # diff/content on stdin → echoes offenders (masked)
    local allow
    allow=$(guard_allow "$(git rev-parse --show-toplevel 2>/dev/null || echo .)")
    grep -inE -e "$GUARD_SECRET_RE" | grep -vE "GUARD_SECRET_RE='-----|SEC_GREP='-----|HIST_PATTERNS='\(" \
      | grep -viE 'EXAMPLE|CHANGE[_-]?ME|PLACEHOLDER|YOUR[_-]|dummy|sample|template|xxxx|yyyy|<[^>]*>|\$\{|<your|insecure[_-]|your-' \
      | { [[ -n "$allow" ]] && grep -viE "$allow" || cat; }
}

guard_gate() {   # $1 = staged | tracked ; returns 1 on violation
    local mode="${1:-staged}" files content rc=0
    if [[ "$mode" == "staged" ]]; then
        files=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)
        content=$(git diff --cached -U0 --diff-filter=ACM 2>/dev/null)
    else
        # tracked: scan every tracked file in the worktree
        files=$(git ls-files 2>/dev/null)
        content=""
        local f
        while IFS= read -r f; do
            [[ -f "$f" ]] && content+=$(grep -inHE -e "$GUARD_SECRET_RE" "$f" 2>/dev/null | head -5) && content+=$'\n'
        done <<< "$files"
    fi
    [[ -z "$files" ]] && return 0

    local bad_paths
    bad_paths=$(printf '%s\n' "$files" | guard_paths_check)
    if [[ -n "$bad_paths" ]]; then
        guard_log "BLOCKED — private/personal path(s) are being committed:"
        printf '    %s\n' $bad_paths >&2
        rc=1
    fi

    local bad_secrets
    bad_secrets=$(printf '%s\n' "$content" | guard_secrets_check | head -10)
    if [[ -n "$bad_secrets" ]]; then
        guard_log "BLOCKED — credential-shaped strings:"
        printf '    %.120s\n' "$bad_secrets" | sed 's/[A-Za-z0-9_\-]\{16,\}/[REDACTED]/g' >&2
        rc=1
    fi

    if (( rc )); then
        guard_log "fix the above, or bypass ONCE: SECRET_GUARD_OK=1 git commit ..."
        guard_log "per-repo line allowlist: .secret-guard-ignore (grep -vE patterns)"
    fi
    return $rc
}
