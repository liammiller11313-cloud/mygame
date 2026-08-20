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

case "$ACTION" in
install)
  if [ ! -x "$REPO/scripts/dev.sh" ]; then
    echo "scripts/dev.sh is missing or not executable. Run: chmod +x scripts/dev.sh" >&2
    exit 1
  fi

  mkdir -p "$HOME/Library/LaunchAgents"
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
    echo "running — Rojo is serving $REPO"
    echo ""
    echo "Last few lines:"
    tail -n 8 "$LOG" 2>/dev/null | sed 's/^/  /'
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
