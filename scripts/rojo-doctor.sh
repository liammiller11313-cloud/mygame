#!/usr/bin/env bash
# Check that the Rojo CLI, the running server and the Studio plugin agree.
#
#   ./scripts/rojo-doctor.sh          check the default port
#   ./scripts/rojo-doctor.sh 34873    check another port
#
# ── WHY THIS IS WORTH A SCRIPT ───────────────────────────────────────────────
# Rojo is three things that must be the same version: the binary on disk, the
# SERVER PROCESS running (which is not the same thing — a running process keeps
# executing the file it started with even after that file is replaced), and the
# Studio plugin.
#
# When they disagree the plugin usually says "protocol version mismatch", which
# tells you what to do. Between 7.6.1 and 7.7.0 it does not, because the plugin
# changed how it decodes /api/rojo — 7.6.1 reads JSON, 7.7.0 reads MessagePack.
# A 7.7.0 plugin against a 7.6.1 server msgpack-decodes a JSON body, reads the
# opening `{` as the number 123, and dies with
#
#     attempt to index number with 'protocolVersion'
#
# That names neither Rojo nor versions. This does.
set -uo pipefail
cd "$(dirname "$0")/.."

PORT="${1:-34872}"
echo "── Rojo doctor ──"
echo ""

# ── 1. the binary on disk ───────────────────────────────────────────────────
if [ -x ./rojo ]; then
  CLI_PATH=./rojo
elif command -v rojo >/dev/null 2>&1; then
  CLI_PATH="$(command -v rojo)"
else
  CLI_PATH=""
fi

CLI_VER=""
if [ -n "$CLI_PATH" ]; then
  CLI_VER="$("$CLI_PATH" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  echo "CLI on disk      ${CLI_VER:-would not run}   ($CLI_PATH)"
else
  echo "CLI on disk      NOT FOUND"
fi

#[[
#  EVERY rojo this machine can reach, not just the one this script picked.
#
#  Because the two are not the same question. This script prefers ./rojo. Your
#  SHELL does not: typing `rojo serve` runs whatever PATH finds first, and an
#  older copy left in /usr/local/bin, /opt/homebrew/bin or a Rokit shim wins
#  over the new one sitting in this folder — which has no ./ in front of it and
#  is not on PATH at all.
#
#  So `./scripts/update-rojo.sh` updates ./rojo, the doctor reports 7.7.0, and
#  `rojo serve` still starts the old one. Everything looks right and nothing
#  works, and between 7.6.1 and 7.7.0 the plugin cannot even say why.
#]]
#[[
#  PATH is walked by hand because `command -v -a` is not a thing — bash's
#  `command` takes no -a, so it silently printed nothing and the check passed
#  for everyone. `type -a -P` is bold but bash-only. This works in either shell.
#
#  And it searches MORE than this shell's PATH, because the process that matters
#  may not have had this shell's PATH. The LaunchAgent's plist sets its own —
#  $HOME/.rokit/bin and both Homebrew prefixes — since a launchd job never runs
#  your profile. That is not a hypothetical: a Rokit shim in ~/.rokit/bin served
#  7.6.1 under launchd while the interactive shell had no rojo on PATH at all,
#  so this reported "nothing on PATH" about a machine that was running one.
#]]
SHADOW_WARN=""
SHADOW_VER=""
SHADOW_ON_PATH=""
FOUND_ANY=""
while IFS= read -r cand; do
  [ -n "$cand" ] || continue
  V="$("$cand" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  FOUND_ANY="yes"
  # On this shell's PATH, or only somewhere launchd looks? Different problem,
  # different sentence — see the warning below.
  ON_PATH=no
  case ":$PATH:" in *":$(dirname "$cand"):"*) ON_PATH=yes ;; esac

  MARK=""
  if [ -n "$CLI_VER" ] && [ -n "$V" ] && [ "$V" != "$CLI_VER" ]; then
    MARK="   <-- DIFFERENT VERSION"
    SHADOW_WARN="$cand"
    SHADOW_VER="$V"
    SHADOW_ON_PATH="$ON_PATH"
  fi
  echo "  elsewhere      ${V:-would not run}   ($cand)$MARK"
done <<EOF
$(printf '%s\n' "$HOME/.rokit/bin" /opt/homebrew/bin /usr/local/bin \
    $(printf '%s' "$PATH" | tr ':' '\n') \
  | awk 'NF && !seen[$0]++' \
  | while IFS= read -r dir; do
      [ -x "$dir/rojo" ] && printf '%s\n' "$dir/rojo"
    done)
EOF
if [ -z "$FOUND_ANY" ] && [ "$CLI_PATH" = "./rojo" ]; then
  echo "  elsewhere      none — so 'rojo serve' will not work; use './rojo serve'"
fi

# ── 2. the process actually serving ─────────────────────────────────────────
#[[ -x matches the executable's NAME, not the command line. `pgrep -f 'rojo
#   serve'` looks more precise and is worse: -f matches the full command line of
#   every process, including any shell whose own arguments merely contain that
#   phrase — this script's parent, when it was being written, matched itself. ]]
PIDS="$(pgrep -x rojo 2>/dev/null)"
if [ -z "$PIDS" ]; then
  echo "server process   none running"
else
  for pid in $PIDS; do
    # The binary a process is REALLY executing, which is the question that
    # matters — it can differ from what is on disk under the same path.
    BIN="$(ps -o comm= -p "$pid" 2>/dev/null | sed 's/^ *//')"
    echo "server process   pid $pid   ($BIN)"
  done
fi

# ── 3. what that process reports over HTTP ──────────────────────────────────
# Read whatever it answers and pull a version out of it. Deliberately format
# agnostic: 7.6.1 answers JSON and 7.7.0 answers MessagePack, and the version
# string sits in the bytes as readable text either way.
BODY="$(curl -fsS --noproxy '*' -m 5 "http://localhost:$PORT/api/rojo" 2>/dev/null | tr -c '[:print:]' '\n')"
SRV_VER=""
if [ -n "$BODY" ]; then
  SRV_VER="$(printf '%s' "$BODY" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  echo "server on :$PORT  ${SRV_VER:-answered, but no version found in the reply}"
  case "$BODY" in
    *serverVersion*) : ;;
    *) echo "                 (the reply does not look like Rojo's — is something else on this port?)" ;;
  esac
else
  echo "server on :$PORT  nothing answering"
fi

echo ""

# ── the verdict ─────────────────────────────────────────────────────────────
PROBLEM=0

if [ -n "$CLI_VER" ] && [ -n "$SRV_VER" ] && [ "$CLI_VER" != "$SRV_VER" ]; then
  PROBLEM=1
  echo "PROBLEM: the running server is $SRV_VER but the CLI on disk is $CLI_VER."
  echo ""
  echo "  A server started before you updated keeps running the old binary. Stop"
  echo "  it and start it again:"
  echo ""
  if launchctl print "gui/$(id -u)/dev.fadinglight.rojo" >/dev/null 2>&1; then
    echo "    ./scripts/autostart.sh uninstall"
    echo "    ./scripts/autostart.sh install"
  else
    echo "    Ctrl+C in the Terminal window running it, then: ./scripts/dev.sh"
  fi
fi

if [ -z "$SRV_VER" ] && [ -n "$PIDS" ]; then
  PROBLEM=1
  echo "PROBLEM: a rojo serve process is running but nothing answers on port $PORT."
  echo "  It may be serving a different port. Check the window it is running in,"
  echo "  then: ./scripts/rojo-doctor.sh <that port>"
fi

if [ -n "$SHADOW_WARN" ]; then
  PROBLEM=1
  echo "PROBLEM: there is more than one Rojo on this machine, on different versions."
  echo ""
  echo "    this folder   $CLI_VER   ./rojo"
  echo "    other         $SHADOW_VER   $SHADOW_WARN"
  echo ""
  if [ "$SHADOW_ON_PATH" = "yes" ]; then
    echo "  That one is on your PATH, so typing 'rojo serve' runs IT, not the ./rojo"
    echo "  this project maintains. ./rojo is not on PATH at all."
  else
    echo "  That one is NOT on your shell's PATH, so it is not what you get by typing"
    echo "  'rojo serve' — but the autostart job has its own PATH which DOES include"
    echo "  it, because a launchd job never runs your shell profile. If a server is"
    echo "  running on the old version, that is where it came from."
  fi
  echo ""
  echo "  Start the server with the one this project uses:"
  echo ""
  echo "    ./scripts/restart-rojo.sh"
  echo ""
  echo "  And to stop the two disagreeing at all, bring the other copy up too:"
  echo ""
  echo "    rokit install"
  echo ""
fi

if [ -z "$PIDS" ] && [ -z "$SRV_VER" ]; then
  PROBLEM=1
  echo "PROBLEM: no Rojo server is running, so Studio has nothing to connect to."
  #[[ Which advice is right depends on whether the LaunchAgent exists, and
  #   getting it wrong is not harmless: telling someone with an agent installed
  #   to run dev.sh gives them a second server that fights the first for the
  #   port the next time the agent starts. The mismatch branch above already
  #   checks this; this one did not, and said dev.sh to everybody. ]]
  if [ -f "$HOME/Library/LaunchAgents/dev.fadinglight.rojo.plist" ]; then
    echo "  The autostart job is installed but not running. Start it:"
    echo ""
    echo "    ./scripts/autostart.sh install"
  else
    echo "  Start one, and have it start itself at every login from now on:"
    echo ""
    echo "    ./scripts/autostart.sh install"
    echo ""
    echo "  Or just for now, in a window you keep open:"
    echo ""
    echo "    ./scripts/dev.sh"
  fi
fi

# ── 4. is this checkout even current? ────────────────────────────────────────
#
#  The question this script did not used to ask, and the one that cost the most.
#
#  Rojo can be perfectly healthy — right CLI, right plugin, connected, syncing
#  every keystroke — and still put eleven-day-old code in Studio, because it
#  serves the FILES ON DISK and nothing makes those current. The symptom is
#  indistinguishable from a bug that will not die: you are handed a fix, you test
#  it, the old behaviour is still there, and every version number checks out.
#
#  So: how far behind origin is this working tree, and what stopped it catching
#  up. Both failure modes dev.sh has are silent by design — it refuses to touch a
#  diverged branch or a dirty tree rather than throwing work away — and a refusal
#  nobody reads looks exactly like a sync that is working.
echo ""
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  echo "Not on a branch, so there is nothing to be behind."
else
  git fetch --quiet origin "$BRANCH" 2>/dev/null || true
  BEHIND=$(git rev-list --count "HEAD..origin/$BRANCH" 2>/dev/null || echo 0)
  AHEAD=$(git rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo 0)
  DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')

  if [ "$BEHIND" -gt 0 ] && [ "$AHEAD" -gt 0 ]; then
    echo "PROBLEM: $BRANCH has DIVERGED — $BEHIND behind, $AHEAD ahead."
    echo "  dev.sh will not touch a diverged branch, so it has stopped pulling."
    echo "  Studio is being served whatever was here when that happened."
    PROBLEM=1
  elif [ "$BEHIND" -gt 0 ]; then
    echo "PROBLEM: this checkout is $BEHIND commit(s) BEHIND origin/$BRANCH."
    echo "  Rojo is serving these older files to Studio, correctly and forever."
    if [ "$DIRTY" -gt 0 ]; then
      echo "  $DIRTY changed file(s) here — that is what is blocking the auto-pull."
      echo "  Commit or stash them and it resumes on its own:"
      echo ""
      echo "    git stash && git pull"
    else
      echo ""
      echo "    git pull"
    fi
    PROBLEM=1
  else
    echo "Up to date with origin/$BRANCH."
  fi

  #[[ The ground truth, and the only check that needs no trust in any of the
  #   above: what the code on disk SAYS its build is. Studio prints the same
  #   string on every server start, so the two can be compared by eye. If they
  #   differ, the place is not running this code, whatever git thinks. ]]
  STAMP=$(grep -o 'BuildStamp = "[^"]*"' src/shared/Config/GameConfig.lua 2>/dev/null | head -1 | cut -d'"' -f2)
  if [ -n "$STAMP" ]; then
    echo ""
    echo "This checkout is build $STAMP."
    echo "Studio prints its build on every server start:"
    echo ""
    echo "    FADING LIGHT — build $STAMP — server up in ..."
    echo ""
    echo "If that line says anything else, Studio is not running this code."
  fi
fi

#[[ The plugin cannot be inspected from out here — it lives inside Studio and
#   nothing on this side can read it. So it is not guessed at; it is named as
#   the half still to check, with where to look. ]]
echo ""
echo "The Studio plugin is the third version and cannot be read from here."
echo "In Studio: Plugins > Rojo > the version is in the panel."
if [ -n "$CLI_VER" ]; then
  echo "It must read $CLI_VER. If it does not:"
  echo ""
  echo "    $CLI_PATH plugin install"
  echo ""
  echo "then QUIT AND REOPEN STUDIO — a loaded plugin stays the old one until you do."
fi

if [ "$PROBLEM" -eq 0 ]; then
  echo ""
  echo "Nothing wrong found on this side."
fi
exit "$PROBLEM"
