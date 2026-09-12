#!/usr/bin/env bash
# Restart the Rojo server, however it happens to be running.
#
#   ./scripts/restart-rojo.sh
#
# There are two ways a Rojo server exists on this machine — the autostart
# LaunchAgent, or `./scripts/dev.sh` in a Terminal window — and which one you
# have decides how to restart it. That is a silly thing to have to know, so this
# works it out.
#
# ── WHY RESTARTING IS EVEN A THING ───────────────────────────────────────────
# A running process keeps executing the file it started with, even after that
# file is replaced. So updating Rojo does not update the server that is already
# running: it goes on serving the old version, and nothing looks wrong until
# Studio refuses to connect — between 7.6.1 and 7.7.0, with an error that
# mentions neither Rojo nor versions. See scripts/rojo-doctor.sh.
set -uo pipefail
cd "$(dirname "$0")/.."

LABEL="dev.fadinglight.rojo"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PORT="${1:-34872}"

if [ -x ./rojo ]; then
  ROJO=./rojo
elif command -v rojo >/dev/null 2>&1; then
  ROJO="$(command -v rojo)"
else
  echo "No Rojo here. See docs/SETUP_MAC.md." >&2
  exit 127
fi
WANT="$("$ROJO" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
echo "Rojo on disk is ${WANT:-an unknown version}."

# ── stop whatever is serving ────────────────────────────────────────────────
STOPPED=0

if [ -f "$PLIST" ]; then
  echo "Stopping the autostart job..."
  #[[ No -w. It writes a persistent DISABLED override against the label, and a
  #   disabled job still bootstraps, still lists, and is never run — see
  #   autostart.sh's load_job for the whole trap. This fallback firing once,
  #   because bootout found nothing loaded to boot out, is enough to kill
  #   autostart permanently. ]]
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 \
    || launchctl unload "$PLIST" >/dev/null 2>&1
  STOPPED=1
  sleep 1
fi

# Strays too: a Terminal window's server, or one launchd has let go of. -x
# matches the executable's NAME — -f would match any process whose command line
# merely mentions rojo, including this script's own shell.
PIDS="$(pgrep -x rojo 2>/dev/null)"
if [ -n "$PIDS" ]; then
  echo "Stopping running Rojo server(s): $(echo "$PIDS" | tr '\n' ' ')"
  # TERM first so it can close its sockets; KILL only what refuses.
  kill $PIDS 2>/dev/null
  for _ in 1 2 3 4 5 6; do
    sleep 0.5
    pgrep -x rojo >/dev/null 2>&1 || break
  done
  LEFT="$(pgrep -x rojo 2>/dev/null)"
  if [ -n "$LEFT" ]; then
    echo "One did not stop; forcing it."
    kill -9 $LEFT 2>/dev/null
    sleep 1
  fi
  STOPPED=1
fi

[ "$STOPPED" -eq 0 ] && echo "Nothing was running."

# ── start it again ──────────────────────────────────────────────────────────
if [ -f "$PLIST" ]; then
  echo "Starting the autostart job..."
  # enable first, in case an older copy of these scripts left the flag behind.
  launchctl enable "gui/$(id -u)/$LABEL" >/dev/null 2>&1
  launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 \
    || launchctl load "$PLIST" >/dev/null 2>&1

  # Confirm from the SERVER rather than from the binary. That the file on disk
  # is 7.7.0 was never in doubt; whether the thing now listening is, is the
  # entire question. Read format-agnostically — 7.6.1 answers JSON and 7.7.0
  # answers MessagePack, and the version sits in the bytes as text either way.
  for _ in 1 2 3 4 5 6 7 8; do
    sleep 1
    BODY="$(curl -fsS --noproxy '*' -m 2 "http://localhost:$PORT/api/rojo" 2>/dev/null | LC_ALL=C tr -c '[:print:]' '\n')"
    [ -n "$BODY" ] && break
  done
  GOT="$(printf '%s' "${BODY:-}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"

  echo ""
  if [ -z "$GOT" ]; then
    echo "Started, but nothing is answering on port $PORT yet."
    echo "Give it a few seconds, then: ./scripts/rojo-doctor.sh"
    exit 1
  elif [ -n "$WANT" ] && [ "$GOT" != "$WANT" ]; then
    echo "The server is STILL $GOT, but the binary is $WANT."
    echo "Something is serving that is not the ./rojo in this folder."
    echo "Run ./scripts/rojo-doctor.sh — it will say what."
    exit 1
  fi
  echo "Server is now $GOT."
  echo ""
  echo "In Studio: Rojo > Connect. If it still refuses, the PLUGIN is the half"
  echo "that is behind — $ROJO plugin install, then quit and reopen Studio."
  exit 0
fi

# No LaunchAgent, so the server belongs in a window. This one becomes it.
echo ""
echo "Starting Rojo here. Leave this window open; Ctrl+C stops the server."
echo ""
exec ./scripts/dev.sh
