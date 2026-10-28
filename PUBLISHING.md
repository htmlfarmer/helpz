# Publishing & maintaining helpz

*Generated 2026-10-28 by `publishz`.*

## One-command release (from the source suite)

```bash
cd <suite-dir>          # the working directory where the tools live
./publishz             # security gate → copy → sanitize → audit → docs → commit
./publishz --push      # ...and push to GitHub
```

What `publishz` does, in order:

1. **Security gate** — runs `secretz --code` over the source suite.
2. **Copy** — every executable `*z` tool + `lib/*.sh` + `.helpz_log.sh`.
   Personal tools and business-specific tools (which carry real systemd unit
   names and worker env vars) are excluded, as are backup files.
3. **Sanitize** — rewrites absolute suite paths to script-relative lookups,
   replaces personal identity defaults with env-var placeholders, swaps LAN
   IPs for `127.0.0.1`, and generates `ai.json.example`.
4. **Leak audit + publish gate** — greps the publish copy for personal
   paths, names and private IPs, then runs the full credential scan against
   the exact bytes that will reach GitHub. A non-zero result blocks release.
5. **Docs** — regenerates README.md (this file's tool table) **from the live
   headers of every tool**, so docs can never drift from code. Add a tool,
   run `publishz`, done.
6. **Git** — preserves the existing history and remote, stages, and commits.
   `--push` sends it to the remote named `origin`.

## First-time GitHub setup

```bash
# with the gh CLI:
cd ../helpz
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
. <suite-dir>/.helpz_log.sh
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
# source lib/chart.sh  → chart_hbars/chart_gauge/chart_donut/chart_spark/chart_heat
```

- Support `--json`, `--no-color`, `-h|--help` (the house style).
- Write reports to `$SCRIPT_DIR/mytoolz-reports/` (git-ignored).
- Exit codes: 0 healthy · 1 warnings · 2 critical.
