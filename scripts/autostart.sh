#!/usr/bin/env bash
# Make scripts/dev.sh start by itself at login, and stay running.
#
#   ./scripts/autostart.sh install     start now, and at every login
#   ./scripts/autostart.sh uninstall   stop, and stop starting
#   ./scripts/autostart.sh status      is it running
#   ./scripts/autostart.sh log         watch what it is doing
#
# ── WHAT THIS ACTUALLY DOES ──────────────────────────────────────────────────
# Writes a launchd LaunchAgent — macOS's own "run this for me" mechanism, the
# same one your other background apps use. Nothing here polls for launchd; the
# system starts the job at login, restarts it if it dies, and stops it when you
# log out.
#
# The job is scripts/dev.sh, so what you get is: Rojo serving, and this branch
# fast-forwarding itself, from the moment you log in, with a Terminal window
# nowhere in it. Studio still has to be told to Connect once per session — a
# plugin cannot be driven from out here.
#
# ── macOS ONLY ───────────────────────────────────────────────────────────────
# launchd is Apple's. On Linux the equivalent is a systemd user unit and on
# Windows it is Task Scheduler; this refuses rather than pretending.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd -P)"

LABEL="dev.fadinglight.rojo"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$REPO/.rojo-dev.log"

ACTION="${1:-}"

# Usage answers on any platform — being told what a command does should not
# require being able to run it.
if [ -z "$ACTION" ] || [ "$ACTION" = "-h" ] || [ "$ACTION" = "--help" ]; then
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This installs a macOS LaunchAgent and you are not on macOS." >&2
  echo "Run ./scripts/dev.sh directly instead." >&2
  exit 1
fi

# launchctl changed verbs in 10.11 and the old ones are deprecated but alive.
# Prefer the modern pair and fall back, because a machine that only has one of
# them should still work rather than half-work.
DOMAIN="gui/$(id -u)"
load_job() {
  launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST" 2>/dev/null
}
unload_job() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || launchctl unload -w "$PLIST" 2>/dev/null
}
job_running() {
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || launchctl list "$LABEL" >/dev/null 2>&1
}

#[[
#  Which folder the INSTALLED job serves, which need not be this one.
#
#  A LaunchAgent keeps serving whatever directory it was installed from, across
#  every reboot, forever. There is more than one copy of this project on a
#  working machine — a mygame-old beside a mygame is the normal shape of it —
#  and a job pointed at the wrong one is indistinguishable from a job pointed at
#  the right one: same label, same port, same "running", same Connected in
#  Studio. It just serves code from months ago.
#
#  That is the quiet way this feature stops working, and it cannot be noticed
#  without printing the path, so the path is printed.
#]]
installed_dir() {
  [ -f "$PLIST" ] || return 1
  sed -n '/<key>WorkingDirectory<\/key>/,/<\/string>/p' "$PLIST" \
    | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p' | head -1
}

case "$ACTION" in
install)
  if [ ! -x "$REPO/scripts/dev.sh" ]; then
    echo "scripts/dev.sh is missing or not executable. Run: chmod +x scripts/dev.sh" >&2
    exit 1
  fi

  mkdir -p "$HOME/Library/LaunchAgents"
  # Said out loud when it moves, because "I reinstalled it and nothing changed"
  # and "I reinstalled it and it now serves somewhere else" look identical from
  # the outside, and only one of them is what you wanted.
  PREVIOUS="$(installed_dir)"
  if [ -n "$PREVIOUS" ] && [ "$PREVIOUS" != "$REPO" ]; then
    echo "The installed job was serving:"
    echo "    $PREVIOUS"
    echo "Repointing it at this checkout:"
    echo "    $REPO"
    echo ""
  fi
  # Replace rather than layer: bootstrap refuses a label already loaded, and an
  # install that silently kept the OLD plist would be the worst kind of working.
  unload_job

  #[[ launchd gives a job almost no PATH — not the one your Terminal has, because
  #   your shell profile never runs for it. So the places Rojo actually lives are
  #   named here: Rokit's shims, both Homebrew prefixes, and the system ones for
  #   git. dev.sh also finds ./rojo in the repo, which covers a hand-unzipped
  #   binary. ]]
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$REPO/scripts/dev.sh</string>
	</array>
	<key>WorkingDirectory</key>
	<string>$REPO</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$HOME/.rokit/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>HOME</key>
		<string>$HOME</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>30</integer>
	<key>StandardOutPath</key>
	<string>$LOG</string>
	<key>StandardErrorPath</key>
	<string>$LOG</string>
	<key>ProcessType</key>
	<string>Background</string>
</dict>
</plist>
PLISTEOF

  : > "$LOG"
  if ! load_job; then
    echo "launchctl refused to load the job. The plist is at:" >&2
    echo "  $PLIST" >&2
    exit 1
  fi

  sleep 2
  echo "Installed. Rojo is serving $REPO and the branch pulls itself."
  echo ""
  echo "  watch it:    ./scripts/autostart.sh log"
  echo "  turn it off: ./scripts/autostart.sh uninstall"
  echo ""
  echo "It starts again by itself every time you log in. In Studio, click Rojo"
  echo "then Connect once per session — a plugin button cannot be pressed from"
  echo "out here."
  echo ""
  if [ -s "$LOG" ]; then
    echo "First few lines of the log:"
    head -n 6 "$LOG" | sed 's/^/  /'
  else
    echo "The log is empty so far; give it a moment, then run the log command."
  fi
  ;;

uninstall)
  unload_job
  rm -f "$PLIST"
  echo "Removed. It will not start again at login."
  echo "Run ./scripts/dev.sh by hand when you want it."
  ;;

status)
  if job_running; then
    #[[
    #  "Registered with launchd" and "actually serving" are different facts, and
    #  this used to print the first while claiming the second.
    #
    #  launchctl says a job is loaded whether it is running happily, exiting
    #  instantly in a KeepAlive restart loop, or sitting there having failed to
    #  bind. All three read as "running". The one that gets reported is "Rojo is
    #  serving <folder>", which is a promise about a socket nothing has asked
    #  about — and when it is wrong, the visible evidence is an EMPTY LOG beside
    #  a green line, which is the least actionable pair of facts possible.
    #
    #  So: the pid launchd actually holds, the exit code of the last run, and an
    #  answer from the port. The port is the only one of the three that means
    #  Studio can connect.
    #]]
    DETAIL="$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null)"
    JOB_PID="$(printf '%s' "$DETAIL" | sed -n 's/^[[:space:]]*pid = \([0-9]*\).*/\1/p' | head -1)"
    LAST_EXIT="$(printf '%s' "$DETAIL" | sed -n 's/^[[:space:]]*last exit code = \([0-9-]*\).*/\1/p' | head -1)"

    WD="$(installed_dir)"
    if [ -n "$WD" ] && [ "$WD" != "$REPO" ]; then
      echo "loaded — but pointed at a DIFFERENT folder:"
      echo "    $WD"
      echo "  you are standing in:"
      echo "    $REPO"
      echo ""
      echo "  Studio will connect to it and say Connected, and receive that"
      echo "  folder's code. Point it here:  ./scripts/autostart.sh install"
      echo ""
    else
      echo "loaded — pointed at ${WD:-$REPO}"
    fi

    if [ -n "$JOB_PID" ] && [ "$JOB_PID" != "0" ]; then
      echo "process     alive, pid $JOB_PID"
    else
      echo "process     NOT RUNNING${LAST_EXIT:+ — last exit code $LAST_EXIT}"
      echo "            launchd has the job but nothing is executing. With"
      echo "            KeepAlive set that means it is exiting as fast as it"
      echo "            starts, once every 30s."
    fi

    # The only question Studio cares about. Same probe restart-rojo.sh uses,
    # and --noproxy because a system proxy must not answer for localhost.
    SERVED="$(curl -fsS --noproxy '*' -m 2 "http://localhost:34872/api/rojo" 2>/dev/null \
      | tr -c '[:print:]' '\n' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [ -n "$SERVED" ]; then
      echo "port 34872  answering, Rojo $SERVED  <- Studio can connect"
    else
      echo "port 34872  NOTHING ANSWERING  <- Studio cannot connect"
    fi

    if [ -s "$LOG" ]; then
      echo ""
      echo "Last few lines:"
      tail -n 8 "$LOG" 2>/dev/null | sed 's/^/  /'
    elif [ -f "$LOG" ]; then
      echo "log         EMPTY"
      echo ""
      #[[ Worth being exact about, because the tempting explanation is wrong.
      #   dev.sh writing to a FILE appears within two seconds — measured, not
      #   assumed — so its output is not sitting in a buffer waiting for the
      #   process to end. An empty log is an empty log: it did not run. ]]
      echo "  dev.sh echoes a line before it does any work, and its output"
      echo "  reaches a log file within two seconds. So an empty log means it"
      echo "  never ran, not that it is running quietly. Run it in the"
      echo "  foreground and the reason prints straight to the terminal:"
      echo ""
      echo "      ./scripts/dev.sh"
      echo ""
    else
      echo "log         MISSING ($LOG)"
      echo ""
      echo "  launchd creates this the moment it starts the job, so a missing"
      echo "  one means the job has never been started at all — not that it"
      echo "  started and failed. Reinstall:  ./scripts/autostart.sh install"
      echo ""
    fi
  else
    echo "not running."
    if [ -f "$PLIST" ]; then
      echo "The LaunchAgent is installed but the job is not loaded. Try:"
      echo "  ./scripts/autostart.sh install"
    else
      echo "Not installed. To install: ./scripts/autostart.sh install"
    fi
  fi
  ;;

log)
  if [ ! -f "$LOG" ]; then
    echo "No log yet at $LOG — is it installed? ./scripts/autostart.sh status"
    exit 1
  fi
  echo "Watching $LOG — Ctrl+C to stop watching (this does not stop Rojo)."
  echo ""
  tail -n 20 -f "$LOG"
  ;;

*)
  echo "unknown command: $ACTION" >&2
  echo "" >&2
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
  ;;
esac
