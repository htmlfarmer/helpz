# Publishing & maintaining helpz

*Generated 2026-10-27 by `publishz`.*

## One-command release (from the source suite)

```bash
cd ~/security          # the working directory where the tools live
./publishz             # security gate → copy → sanitize → audit → docs → commit
./publishz --push      # ...and push to GitHub
```

What `publishz` does, in order:

1. **Security gate** — runs `secretz --code` over the source suite; aborts if
   credential-shaped hits are found in *code* (use `--force` to override).
2. **Copy** — every executable `*z` tool + `lib/*.sh` + `.helpz_log.sh`.
   Personal tools (e.g. `spiritz`) and backup files are excluded. Business-
   specific tools (e.g. `xyzo*`) do ship, but their internal unit names,
   worker env vars and database names are rewritten to generic examples.
3. **Sanitize** — rewrites absolute suite paths to script-relative lookups,
   replaces personal identity defaults with env-var placeholders, swaps LAN
   IPs for `127.0.0.1`, and generates `ai.json.example`.
4. **Leak audit** — greps the publish copy for personal paths, names, and
   private IPs; a non-zero result blocks a clean release.
5. **Docs** — regenerates README.md (this file's tool table) **from the live
   headers of every tool**, so docs can never drift from code. Add a tool,
   run `publishz`, done.
6. **Git** — initializes the repo if needed, stages, and commits. `--push`
   sends it to the remote named `origin`.

## First-time GitHub setup

```bash
# with the gh CLI:
cd <suite-dir>          # the directory holding the publish copy
gh repo create helpz --public --source=. --push

# or manual: create an empty repo on github.com, then:
git remote add origin git@github.com:<you>/helpz.git
git push -u origin main
```

## Keeping docs fresh automatically

The README + PUBLISHING files are *generated*, never hand-edited:
- Add/change a tool → update its header comment (`# name - desc`, usage lines)
  → run `./publishz` → the docs regenerate and commit.
- `helpz` reads the same headers, so CLI docs, cheat-sheet, and README always
  agree.

## Conventions for new tools (so everything keeps working)

```bash
#!/usr/bin/env bash
. /home/USER/security/.helpz_log.sh
# ============================================================
# mytoolz - One-line description            <- helpz list + README
# ------------------------------------------------------------
# Longer description...
#
# Usage:
#   ./mytoolz ...                            <- helpz examples
#   ./mytoolz --json ...
# ============================================================
# source lib/common.sh  → section/ok/warn/crit, bar(), spark(), kpi(), emit_verdict
```

- Support `--json`, `--no-color`, `-h|--help` (the house style).
- Write reports to `$SCRIPT_DIR/mytoolz-reports/` (git-ignored).
- Exit codes: 0 healthy · 1 warnings · 2 critical.
