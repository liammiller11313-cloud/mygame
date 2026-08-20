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
BODY="$(curl -fsS -m 5 "http://localhost:$PORT/api/rojo" 2>/dev/null | tr -c '[:print:]' '\n')"
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

if [ -z "$PIDS" ] && [ -z "$SRV_VER" ]; then
  PROBLEM=1
  echo "PROBLEM: no Rojo server is running, so Studio has nothing to connect to."
  echo "  Start one:  ./scripts/dev.sh"
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
