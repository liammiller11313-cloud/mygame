#!/usr/bin/env bash
# sync.sh — put this checkout exactly on the branch, and prove it is the one
#           Studio is running.
#
#   ./scripts/sync.sh              # sync, diagnose, report, restart Rojo
#   ./scripts/sync.sh --force      # ...discarding local changes that are in the way
#   ./scripts/sync.sh --no-serve   # sync and report only
#
# ── WHY THIS EXISTS ──────────────────────────────────────────────────────────
# "The guns behave the same as before" has four different causes that all look
# identical from inside Studio:
#
#   1. the commit never reached this disk          (a fetch that failed)
#   2. it reached disk but a pull could not apply  (a dirty or diverged tree)
#   3. it applied, but Studio wrote its own stale  (the plugin's two-way sync)
#      copy back over it
#   4. it applied everywhere, but the Rojo server  (a second checkout, or the
#      Studio is connected to is serving a          autostart job pointing at one)
#      DIFFERENT FOLDER
#
# Cause 4 is the quiet one. There is more than one copy of this project on this
# machine, and a server started in the wrong one is indistinguishable from a
# server started in the right one — same port, same "Connected", same
# everything, serving code from months ago. So this script does not just pull;
# it asks who is actually serving, and from where.
set -uo pipefail
cd "$(dirname "$0")/.."
HERE_DIR="$(pwd -P)"

BRANCH="claude/fading-light-roblox-game-flg5ig"
LABEL="dev.fadinglight.rojo"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
FORCE=0
SERVE=1
for arg in "$@"; do
  case "$arg" in
    --force)    FORCE=1 ;;
    --no-serve) SERVE=0 ;;
    -h|--help)  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
PROBLEMS=0
note_problem() { PROBLEMS=$((PROBLEMS + 1)); }

say "── sync ──"
say ""
say "  checkout    $HERE_DIR"
say "  branch      $BRANCH"
say ""

# ── 1. the branch ───────────────────────────────────────────────────────────
ON="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || { say "not a git repository"; exit 1; }
if [ "$ON" != "$BRANCH" ]; then
  say "on branch '$ON', want '$BRANCH' — switching"
  git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH" "origin/$BRANCH" || {
    say ""
    say "Could not switch. Local changes are probably in the way:"
    git status --short | sed 's/^/  /'
    say ""
    say "Re-run with --force to discard them."
    exit 1
  }
fi

# ── 2. fetch ────────────────────────────────────────────────────────────────
#[[
#  GIT_TERMINAL_PROMPT=0 on purpose.
#
#  Without it, a fetch with no stored credential stops and asks for a username
#  at a bare prompt with no punctuation and no explanation. That prompt is
#  indistinguishable from a shell, so the next thing typed goes into it — which
#  is how a fetch ends up trying to log in as the user "rojo serve". Then the
#  whole command is derailed and nothing that was supposed to happen after it
#  ran at all.
#
#  With it, the same situation is an instant error with the words "could not
#  read Username" in it, which we can recognise and explain below.
#]]
FETCH_OK=0
FETCH_ERR=""
for delay in 0 2 4 8 16; do
  [ "$delay" = 0 ] || { say "fetch failed, retrying in ${delay}s..."; sleep "$delay"; }
  FETCH_ERR="$(GIT_TERMINAL_PROMPT=0 git fetch origin "$BRANCH" 2>&1)" && { FETCH_OK=1; break; }
  # Retrying an authentication failure just spends 30 seconds arriving at the
  # same answer. Only a network failure is worth the backoff.
  case "$FETCH_ERR" in
    *Username*|*sername\ for*|*uthentication\ failed*|*terminal\ prompts\ disabled*|\
    *403*|*Permission\ denied*|*Permission\ to*denied\ to*|*Invalid\ username*|\
    *Support\ for\ password\ authentication*)
      break ;;
  esac
done

if [ "$FETCH_OK" -eq 0 ]; then
  note_problem
  say "✗ Could not fetch from origin. Git said:"
  printf '%s\n' "$FETCH_ERR" | sed 's/^/    /'
  say ""
  case "$FETCH_ERR" in
    *Username*|*sername\ for*|*uthentication\ failed*|*terminal\ prompts\ disabled*|\
    *403*|*Permission\ denied*|*Permission\ to*denied\ to*|*Invalid\ username*|\
    *Support\ for\ password\ authentication*)
      say "  That is authentication, not the network. GitHub stopped accepting"
      say "  account passwords in 2021, so the password box wants a personal"
      say "  access token. Set it up once:"
      say ""
      say "    git config --global credential.helper osxkeychain"
      say "    git fetch origin $BRANCH"
      say ""
      say "  At 'Username' type your GitHub username. At 'Password' paste a"
      say "  token from github.com/settings/tokens (classic, 'repo' scope)."
      say "  The keychain remembers it and you are never asked again."
      say ""
      say "  Nothing else on this line is a prompt. If you see a bare"
      say "  'Username for ...' again, type the username — not a command."
      ;;
    *)
      say "  That reads like a network failure. It retried 4 times over 30s."
      ;;
  esac
  LAST_FETCH="$(git log -1 --format=%cr "origin/$BRANCH" 2>/dev/null || echo 'never')"
  say ""
  say "  Carrying on against the last copy of origin/$BRANCH this checkout has,"
  say "  whose newest commit is from $LAST_FETCH. It may not be the newest one."
  say ""
fi

BEHIND="$(git rev-list --count "HEAD..origin/$BRANCH" 2>/dev/null || echo 0)"
AHEAD="$(git rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo 0)"

# ── 3. the working tree ─────────────────────────────────────────────────────
DIRTY="$(git status --porcelain)"
if [ -n "$DIRTY" ]; then
  note_problem
  say "✗ The working tree has changes:"
  printf '%s\n' "$DIRTY" | sed 's/^/    /'
  say ""

  #[[
  #  Attributing them matters, because --force fixes one of these and not the
  #  other.
  #
  #  Nobody hand-edits src/ on this machine — the code arrives by pull. So a
  #  MODIFIED file under src/ that nobody modified was written by the only other
  #  thing with a handle on that tree: the Rojo plugin's two-way sync, pushing
  #  Studio's older copy of the script back down onto disk. --force discards it
  #  and the next connect writes it straight back.
  #]]
  WROTE_BACK="$(printf '%s\n' "$DIRTY" | grep -E '^ ?M +src/' | sed 's/^ *M *//')"
  if [ -n "$WROTE_BACK" ]; then
    say "  These are inside the tree Rojo serves, and they are MODIFIED, not new:"
    printf '%s\n' "$WROTE_BACK" | sed 's/^/      /'
    say ""
    say "  Nothing here edits src/ by hand; code arrives by pull. So Studio wrote"
    say "  these — the Rojo plugin's TWO-WAY SYNC pushing its own older copy of"
    say "  each script back down onto disk. That is also what produces the"
    say "  'Cannot remove instance ... it's from a project file' warnings and the"
    say "  'Failed to write file .../src/shared/Enums: Is a directory' errors."
    say ""
    say "  ►► TURN IT OFF, or this comes back every time you connect:"
    say "     In Studio: the Rojo plugin's toolbar button → the gear/Settings"
    say "     icon → switch TWO-WAY SYNC off. Then reconnect."
    say ""
    say "  Two-way sync makes Studio the source of truth. You want the opposite:"
    say "  the files on disk are the game, Studio is a viewer."
    say ""
  fi

  if [ "$FORCE" -eq 1 ]; then
    say "  --force: discarding them."
    # -fd, deliberately not -fdx: ./rojo and ./rojo-*.zip are gitignored
    # downloads, not source, and deleting the binary mid-sync would be rude.
    git reset --hard --quiet
    git clean -fdq
    say ""
  else
    say "  THIS IS WHY NOTHING IS UPDATING: a pull cannot run over these."
    say "  Re-run as:  ./scripts/sync.sh --force    (discards the above)"
    exit 1
  fi
fi

if [ "$AHEAD" -gt 0 ]; then
  if [ "$FORCE" -eq 1 ]; then
    say "Discarding $AHEAD local commit(s) origin does not have."
  else
    note_problem
    say "✗ You have $AHEAD commit(s) origin does not, so this checkout has diverged."
    say "  THIS IS WHY NOTHING IS UPDATING: dev.sh will not pull across a divergence."
    say "  Re-run as:  ./scripts/sync.sh --force    (discards your $AHEAD commit(s))"
    exit 1
  fi
fi

if [ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$BRANCH")" ]; then
  say "$BEHIND commit(s) behind. Moving to origin/$BRANCH:"
  git log --oneline --no-decorate "HEAD..origin/$BRANCH" | sed 's/^/  /'
  git reset --hard --quiet "origin/$BRANCH"
  say ""
else
  say "Already on the newest commit this checkout knows about."
  say ""
fi

# ── 4. who is actually serving, and from where ──────────────────────────────
#[[
#  The check this script was missing.
#
#  `find ~ -name default.project.json` on this machine turns up more than one
#  copy of this project. A `rojo serve` started in the wrong one binds the same
#  port and reports the same "Connected" in Studio, so every visible signal says
#  the sync is working while the code being served is from another checkout
#  entirely. Comparing the server's working directory against this one is the
#  only thing that tells them apart.
#]]
say "── who is serving ──"
SERVING_WRONG=0
PIDS="$(pgrep -x rojo 2>/dev/null || true)"
if [ -z "$PIDS" ]; then
  say "  No Rojo server is running. Nothing is being served to Studio at all."
  say "  (This script starts one at the end, unless --no-serve.)"
else
  for pid in $PIDS; do
    CWD=""
    if command -v lsof >/dev/null 2>&1; then
      CWD="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
    fi
    # The port matters as much as the folder: the plugin's Connect dialog has
    # its own remembered port, and a mismatch there fails in a way that reads
    # as "Rojo is broken" rather than "these two numbers differ".
    PORT="$(ps -o command= -p "$pid" 2>/dev/null | grep -oE '\-\-port +[0-9]+' | grep -oE '[0-9]+' | head -1)"
    PORT="${PORT:-34872 (default)}"
    if [ -z "$CWD" ]; then
      say "  pid $pid — port $PORT — could not read its folder (lsof unavailable)."
    elif [ "$CWD" = "$HERE_DIR" ]; then
      say "  pid $pid — port $PORT — serving THIS checkout. ✓"
      say "             The plugin's Connect dialog must say port $PORT too."
    else
      note_problem
      SERVING_WRONG=1
      say "  pid $pid — port $PORT — serving a DIFFERENT folder:"
      say "      $CWD"
    fi
  done
fi

# The autostart job is the same trap with a longer memory: it keeps pointing at
# whatever folder it was installed from, across reboots, forever.
if [ -f "$PLIST" ]; then
  WD="$(sed -n '/<key>WorkingDirectory<\/key>/,/<\/string>/p' "$PLIST" \
        | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p' | head -1)"
  if [ -n "$WD" ] && [ "$WD" != "$HERE_DIR" ]; then
    note_problem
    SERVING_WRONG=1
    say ""
    say "  The autostart job ($LABEL) is installed against:"
    say "      $WD"
    say "  ...which is not this checkout. It will restart itself there on every"
    say "  login. Reinstall it from here:  ./scripts/autostart.sh"
  fi
fi

if [ "$SERVING_WRONG" -eq 1 ]; then
  say ""
  say "  ►► THIS ALONE EXPLAINS EVERYTHING LOOKING UNCHANGED. Studio connects,"
  say "     says Connected, and receives code from that other folder. Pulling"
  say "     into this one will never reach it."
fi
say ""

# ── 5. the proof ────────────────────────────────────────────────────────────
STAMP="$(grep -oE 'BuildStamp = "[^"]+"' src/shared/Config/GameConfig.lua | head -1 | cut -d'"' -f2)"
say "── this checkout is now ──"
say "  commit      $(git rev-parse --short HEAD)  $(git log -1 --format=%s | cut -c1-54)"
say "  committed   $(git log -1 --format=%cr)"
say "  build       $STAMP"
say ""
say "Start the place and look at the SERVER output. The banner must say:"
say ""
say "    FADING LIGHT — build $STAMP — server up in ... ms"
say "    pack        PaintballGun 200/s · RocketLauncher 75/s · Slingshot 165/s · Sword lunge 0.30s"
say ""
say "Any other build line means Studio is not running this tree. If the pack"
say "line says HITSCAN, same answer. Check the plugin is CONNECTED — a server"
say "being up is not the same as Studio being attached to it."
say ""
if [ "$PROBLEMS" -gt 0 ]; then
  say "$PROBLEMS problem(s) named above. Fix them before trusting the banner."
  say ""
fi

# ── 6. serve ────────────────────────────────────────────────────────────────
if [ "$SERVE" -eq 0 ]; then
  exit 0
fi
if [ -x ./scripts/restart-rojo.sh ]; then
  say "── restarting Rojo ──"
  ./scripts/restart-rojo.sh
else
  say "No restart-rojo.sh here; start Rojo yourself and reconnect the plugin."
fi
