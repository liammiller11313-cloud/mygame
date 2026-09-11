#!/usr/bin/env bash
# sync.sh — put this checkout exactly on the branch, and prove it.
#
#   ./scripts/sync.sh              # sync, report, and restart Rojo
#   ./scripts/sync.sh --force      # ...discarding local changes that are in the way
#   ./scripts/sync.sh --no-serve   # sync and report only
#
# Written because "the guns behave the same as before" and "Rojo is not serving
# this tree" look identical from inside Studio, and dev.sh refuses to pull on a
# dirty or diverged tree with one warning that is easy to scroll past.
set -uo pipefail
cd "$(dirname "$0")/.."

BRANCH="claude/fading-light-roblox-game-flg5ig"
FORCE=0
SERVE=1
for arg in "$@"; do
  case "$arg" in
    --force)    FORCE=1 ;;
    --no-serve) SERVE=0 ;;
    -h|--help)  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
say "── sync ──"
say ""

# ── 1. the branch ───────────────────────────────────────────────────────────
HERE="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || { say "not a git repository"; exit 1; }
if [ "$HERE" != "$BRANCH" ]; then
  say "on branch '$HERE', want '$BRANCH' — switching"
  git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH" "origin/$BRANCH" || {
    say ""
    say "Could not switch. Local changes are probably in the way:"
    git status --short | sed 's/^/  /'
    say ""
    say "Re-run with --force to discard them."
    exit 1
  }
fi

# ── 2. fetch, with the retry the network sometimes needs ────────────────────
for delay in 0 2 4 8 16; do
  [ "$delay" = 0 ] || { say "fetch failed, retrying in ${delay}s..."; sleep "$delay"; }
  git fetch origin "$BRANCH" --quiet && break
done

LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse "origin/$BRANCH")"
BEHIND="$(git rev-list --count "HEAD..origin/$BRANCH" 2>/dev/null || echo 0)"
AHEAD="$(git rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo 0)"

# ── 3. say what is actually wrong, then fix it ──────────────────────────────
DIRTY="$(git status --porcelain)"
if [ -n "$DIRTY" ]; then
  say "The working tree has changes:"
  printf '%s\n' "$DIRTY" | sed 's/^/  /'
  say ""
  if [ "$FORCE" -eq 1 ]; then
    say "--force: discarding them."
    git reset --hard --quiet
    git clean -fdq
  else
    say "THIS IS WHY NOTHING IS UPDATING: a pull cannot run over these."
    say "Re-run as:  ./scripts/sync.sh --force    (discards the above)"
    exit 1
  fi
fi

if [ "$AHEAD" -gt 0 ] && [ "$FORCE" -eq 0 ]; then
  say "You have $AHEAD commit(s) origin does not, so this checkout has diverged."
  say "THIS IS WHY NOTHING IS UPDATING: dev.sh will not pull across a divergence."
  say "Re-run as:  ./scripts/sync.sh --force    (discards your $AHEAD commit(s))"
  exit 1
fi

if [ "$LOCAL" != "$REMOTE" ]; then
  say "$BEHIND commit(s) behind. Moving to origin/$BRANCH:"
  git log --oneline --no-decorate "HEAD..origin/$BRANCH" | sed 's/^/  /'
  git reset --hard --quiet "origin/$BRANCH"
else
  say "Already on the newest commit."
fi

# ── 4. the proof ────────────────────────────────────────────────────────────
STAMP="$(grep -oE 'BuildStamp = "[^"]+"' src/shared/Config/GameConfig.lua | head -1 | cut -d'"' -f2)"
say ""
say "── this checkout is now ──"
say "  commit      $(git rev-parse --short HEAD)  $(git log -1 --format=%s | cut -c1-54)"
say "  committed   $(git log -1 --format=%cr)"
say "  build       $STAMP"
say ""
say "Start the place and look at the server output. The banner must say:"
say ""
say "    FADING LIGHT — build $STAMP — server up in ... ms"
say "    pack        PaintballGun 200/s · RocketLauncher 75/s · Slingshot 165/s · Sword lunge 0.30s"
say ""
say "If the build line says anything else, Studio is NOT running this tree —"
say "check that the Rojo plugin is CONNECTED, not merely that the server is up."
say "If it says HITSCAN anywhere on the pack line, same answer."
say ""

# ── 5. serve ────────────────────────────────────────────────────────────────
if [ "$SERVE" -eq 0 ]; then
  exit 0
fi
if [ -x ./scripts/restart-rojo.sh ]; then
  say "── restarting Rojo ──"
  ./scripts/restart-rojo.sh
else
  say "No restart-rojo.sh here; start Rojo yourself and reconnect the plugin."
fi
