#!/usr/bin/env bash
# One command for a working session: Rojo serving, and this branch pulling
# itself as new commits land.
#
#   ./scripts/dev.sh              serve + auto-pull every 20s
#   ./scripts/dev.sh --pull-only  auto-pull only (a Rojo server is already up)
#   ./scripts/dev.sh --every 5    poll every 5 seconds instead of 20
#
# ── WHY THIS EXISTS ──────────────────────────────────────────────────────────
# Rojo's live sync is genuinely live: while `rojo serve` is running and the
# Studio plugin is connected, a file changing on disk is in Studio a moment
# later, with nothing to press.
#
# But the files only change on disk when something changes them, and when the
# work is happening somewhere else — an agent pushing to the branch, another
# machine, a teammate — that something is a `git pull` you have to remember to
# run in a second terminal. That is the manual step. This removes it.
#
# ── WHAT IT WILL NOT DO ──────────────────────────────────────────────────────
# It only ever FAST-FORWARDS. If the branch has diverged, or the working tree
# has edits that a pull would touch, it says so and keeps serving rather than
# merging, stashing or resetting anything. Deciding what happens to your own
# work is not a background job's business.
set -uo pipefail
cd "$(dirname "$0")/.."


INTERVAL=20
SERVE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --pull-only) SERVE=0; shift ;;
    --every) INTERVAL="${2:-20}"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# Only when we are the one starting it. --pull-only exists precisely for the case
# where Rojo is already running in another window, and demanding a binary we are
# never going to execute would turn that into a setup problem it is not.
ROJO=""
if [ "$SERVE" -eq 1 ]; then
  # Rokit puts tools on the PATH; a hand-unzipped binary sits in the repo root.
  # Both are normal ways to have Rojo here, so try both before giving up.
  if command -v rojo >/dev/null 2>&1; then
    ROJO=rojo
  elif [ -x ./rojo ]; then
    ROJO=./rojo
  else
    echo "Rojo not found. Install it with 'rokit install', or see docs/SETUP_MAC.md." >&2
    echo "If Rojo is already serving in another window, use: ./scripts/dev.sh --pull-only" >&2
    exit 127
  fi
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || {
  echo "not a git repository" >&2; exit 1
}

ROJO_PID=""
cleanup() {
  if [ -n "$ROJO_PID" ] && kill -0 "$ROJO_PID" 2>/dev/null; then
    echo ""
    echo "[dev] stopping Rojo"
    kill "$ROJO_PID" 2>/dev/null
    wait "$ROJO_PID" 2>/dev/null
  fi
  exit 0
}
trap cleanup INT TERM

if [ "$SERVE" -eq 1 ]; then
  echo "[dev] starting Rojo on branch $BRANCH"
  "$ROJO" serve &
  ROJO_PID=$!
  # A moment for it to bind, so "Address already in use" is reported by Rojo
  # itself before the pull loop starts printing over the top of it.
  sleep 2
  if ! kill -0 "$ROJO_PID" 2>/dev/null; then
    echo "[dev] Rojo exited immediately — see its message above." >&2
    echo "[dev] If the port is taken, a server is already running; use --pull-only." >&2
    exit 1
  fi
fi

echo "[dev] watching origin/$BRANCH every ${INTERVAL}s — Ctrl+C to stop"
if [ "$SERVE" -eq 1 ]; then
  echo "[dev] connect Studio to Rojo now; pulled changes reach it with no reconnect"
else
  echo "[dev] pulled changes reach a connected Studio with no reconnect"
fi

WARNED_DIVERGED=0
WARNED_DIRTY=0
FETCH_FAILS=0

while true; do
  sleep "$INTERVAL" &
  wait $! 2>/dev/null || cleanup

  if ! git fetch --quiet origin "$BRANCH" 2>/dev/null; then
    # Offline, or a transient failure — retrying is right. But a fetch that
    # fails FOREVER is usually credentials, and when this runs unattended into a
    # log file, silence is the difference between "nothing has changed" and
    # "nothing has worked since Tuesday". So it says so, once, after a few.
    FETCH_FAILS=$((FETCH_FAILS + 1))
    if [ "$FETCH_FAILS" -eq 3 ] ; then
      echo "[dev] cannot reach origin (3 tries). Still trying every ${INTERVAL}s."
      echo "[dev] If this persists, run 'git fetch' by hand here — it will show why."
      echo "[dev] For a private repo the usual cause is credentials this process cannot reach."
    fi
    continue
  fi
  if [ "$FETCH_FAILS" -ge 3 ]; then
    echo "[dev] origin is reachable again."
  fi
  FETCH_FAILS=0

  LOCAL=$(git rev-parse HEAD 2>/dev/null)
  REMOTE=$(git rev-parse "origin/$BRANCH" 2>/dev/null)
  [ "$LOCAL" = "$REMOTE" ] && continue

  # Only fast-forward. A branch that has moved on both sides is a merge, and a
  # merge is a decision.
  if ! git merge-base --is-ancestor HEAD "origin/$BRANCH" 2>/dev/null; then
    if [ "$WARNED_DIVERGED" -eq 0 ]; then
      WARNED_DIVERGED=1
      echo "[dev] $BRANCH has diverged from origin — not pulling."
      echo "[dev] You have commits origin does not. Merge or rebase yourself; still serving."
    fi
    continue
  fi
  WARNED_DIVERGED=0

  COUNT=$(git rev-list --count HEAD.."origin/$BRANCH" 2>/dev/null)
  if ! git merge --ff-only --quiet "origin/$BRANCH" 2>/dev/null; then
    if [ "$WARNED_DIRTY" -eq 0 ]; then
      WARNED_DIRTY=1
      echo "[dev] $COUNT new commit(s) waiting, but the working tree is in the way:"
      git status --short | sed 's/^/[dev]   /'
      echo "[dev] Commit or stash those and it will pull on the next tick."
    fi
    continue
  fi
  WARNED_DIRTY=0

  echo "[dev] pulled $COUNT commit(s):"
  git log --oneline -n "$COUNT" --no-decorate | sed 's/^/[dev]   /'
done
