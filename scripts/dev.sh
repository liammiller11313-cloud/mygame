#!/usr/bin/env bash
# One command for a working session: Rojo serving, and this branch pulling
# itself as new commits land.
#
#   ./scripts/dev.sh              serve + auto-pull every 20s
#   ./scripts/dev.sh --pull-only  auto-pull only (a Rojo server is already up)
#   ./scripts/dev.sh --every 5    poll every 5 seconds instead of 20
#   ./scripts/dev.sh --keep-local never reclaim what Studio writes back
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
# It only ever FAST-FORWARDS. If the branch has diverged it says so and keeps
# serving rather than merging anything. Deciding what happens to your own work
# is not a background job's business.
#
# ── THE ONE EXCEPTION, AND WHY IT IS NOT YOUR WORK ───────────────────────────
# A modified file under src/ that you did not edit is Studio writing back.
#
# The Rojo plugin's two-way sync pushes Studio's own older copy of a script down
# onto disk when it connects. That dirties the tree, a dirty tree cannot
# fast-forward, and this loop then refuses every pull FOREVER after — which
# presents as "Claude's updates stopped arriving" with a warning sitting in a
# log file nobody is watching. It is the single most common way this stops
# working.
#
# So an UNSTAGED modification or deletion of a TRACKED file under src/, and
# nothing else in the tree, is reclaimed and the pull goes through. The bar is
# deliberately narrow: a staged change, an untracked file, or anything at all
# outside src/ still blocks the pull exactly as before, because each of those
# takes a deliberate act and this one does not.
#
# And nothing is destroyed. The diff is written to .rojo-writeback/ first, so
# even the case this is wrong about is `git apply` away from being undone. Use
# --keep-local to turn the whole thing off.
set -uo pipefail
cd "$(dirname "$0")/.."


INTERVAL=20
SERVE=1
RECLAIM=1
while [ $# -gt 0 ]; do
  case "$1" in
    --pull-only) SERVE=0; shift ;;
    --keep-local) RECLAIM=0; shift ;;
    --every) INTERVAL="${2:-20}"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# Only when we are the one starting it. --pull-only exists precisely for the case
# where Rojo is already running in another window, and demanding a binary we are
# never going to execute would turn that into a setup problem it is not.
ROJO=""
if [ "$SERVE" -eq 1 ]; then
  #[[
  #  ./rojo FIRST, and the order is the whole point.
  #
  #  This used to ask PATH first, and every other script here asks ./rojo first.
  #  That disagreement was a real bug with a very quiet presentation: the
  #  LaunchAgent's plist puts $HOME/.rokit/bin on PATH, so under launchd this
  #  found a Rokit shim and served whatever rokit.toml pinned — 7.6.1 — while
  #  update-rojo.sh had put 7.7.0 in ./rojo and every diagnostic agreed the
  #  update had worked. The interactive shell had no rojo on PATH at all, so the
  #  two contexts did not even see the same binaries.
  #
  #  ./rojo is what update-rojo.sh maintains, so ./rojo is what runs.
  #]]
  if [ -x ./rojo ]; then
    ROJO=./rojo
  elif command -v rojo >/dev/null 2>&1; then
    ROJO=rojo
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

#[[
#  ── SOMEBODY ELSE IS ALREADY SERVING, WHICH IS FINE ─────────────────────────
#  Running `rojo serve` by hand is the obvious thing to do, and it used to break
#  the autopull completely.
#
#  Two servers cannot hold port 34872. The second one exits with "Address
#  already in use", this script saw its child die and exited 1, and launchd —
#  which has KeepAlive — restarted it thirty seconds later to fail the same way,
#  forever. The serving half was fine the whole time, because the hand-started
#  server was doing that job; it was the PULLING half that never ran. Which
#  presents as "autostart is on and the updates still are not arriving".
#
#  Serving and pulling are separate jobs and only one of them is contested. So a
#  port that already answers is not an error: it means the serving half is
#  handled, and this drops to pulling only.
#
#  Whose server it is still matters, so it is named. lsof gives the working
#  directory of whatever holds the port, and a server running in a DIFFERENT
#  checkout is the quiet failure sync.sh exists to catch — Studio connects, says
#  Connected, and receives another folder's code while this one pulls updates
#  nobody sees.
#]]
if [ "$SERVE" -eq 1 ]; then
  if curl -fsS --noproxy '*' -m 2 "http://localhost:34872/api/rojo" >/dev/null 2>&1; then
    SERVE=0
    OTHER_PID="$(lsof -ti :34872 -sTCP:LISTEN 2>/dev/null | head -1)"
    OTHER_DIR=""
    if [ -n "$OTHER_PID" ]; then
      OTHER_DIR="$(lsof -a -p "$OTHER_PID" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
    fi
    if [ -n "$OTHER_DIR" ] && [ "$OTHER_DIR" != "$PWD" ]; then
      echo "[dev] A Rojo server already holds port 34872, and it is serving:"
      echo "[dev]     $OTHER_DIR"
      echo "[dev] which is NOT this folder ($PWD). Studio will say Connected and"
      echo "[dev] receive that folder's code. Pulls here will not reach it."
    elif [ -n "$OTHER_DIR" ]; then
      echo "[dev] A Rojo server already serves this folder (pid $OTHER_PID) — using it."
      echo "[dev] Not starting a second; pulling only. Nothing else to do."
    else
      echo "[dev] Something already answers on port 34872 — using it, pulling only."
    fi
  else
    echo "[dev] starting Rojo on branch $BRANCH"
    "$ROJO" serve &
    ROJO_PID=$!
    # A moment for it to bind, so "Address already in use" is reported by Rojo
    # itself before the pull loop starts printing over the top of it.
    sleep 2
    if ! kill -0 "$ROJO_PID" 2>/dev/null; then
      #[[ Not exit 1 any more. Under launchd that is a restart loop that never
      #   converges, and the pull is still worth running even when the serve
      #   failed — the two jobs are independent and failing both because one
      #   failed is strictly worse. ]]
      echo "[dev] Rojo exited immediately — see its message above." >&2
      echo "[dev] Carrying on with pulls only; start a server yourself, or run" >&2
      echo "[dev] ./scripts/rojo-doctor.sh to find out why it will not start." >&2
      SERVE=0
      ROJO_PID=""
    fi
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
WRITEBACK_DIR="$PWD/.rojo-writeback"

#[[
#  Is everything in the way of a pull the plugin's doing, rather than yours?
#
#  Reads git status in porcelain form, whose first two columns are the staged
#  and unstaged state. A space then M or D is "tracked file, modified or deleted,
#  NOT staged" — which is what a process writing over a file on disk produces,
#  and what none of the deliberate acts produce:
#
#      " M src/…"   Studio wrote over it          -> reclaim
#      "M  src/…"   you staged it                 -> refuse, it was deliberate
#      "?? src/…"   a new file nobody tracked     -> refuse, nothing to restore
#      " M docs/…"  outside the served tree       -> refuse, not the plugin
#
#  One non-matching line refuses the whole thing rather than reclaiming the rest
#  around it. A tree with your work in it is a tree to keep your hands off, and
#  partially reclaiming it would be the worst of both.
#]]
writeback_only() {
  local status
  status="$(git status --porcelain)"
  [ -n "$status" ] || return 1
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      " M src/"*|" D src/"*) : ;;
      *) return 1 ;;
    esac
  done <<< "$status"
  return 0
}

#[[
#  Reclaims it, having first put a COPY of every file somewhere it can be got
#  back from. That copy is the whole reason this is allowed to be automatic: the
#  case where this judgement is wrong costs a `cp` rather than the work.
#
#  Copies rather than a patch, and that distinction was measured rather than
#  assumed. The obvious version saved `git diff` and said "git apply it to put
#  those changes back", which is false the moment it matters: the diff is
#  against the commit you were ON, the pull moves the file underneath it, and
#  apply then fails on context. `--3way` is worse — it "succeeds" by writing
#  <<<<<<< markers into a Lua file that Rojo serves straight to Studio, turning
#  a recoverable mistake into a syntax error in the running game.
#
#  A copy has no context to fail on.
#
#  Modified files only. A file Studio DELETED needs no copy: its content is the
#  committed content, which git still has, and checkout is what brings it back.
#]]
reclaim_writeback() {
  local stamp dest file
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="$WRITEBACK_DIR/$stamp"
  mkdir -p "$dest" || return 1

  echo "[dev] Studio had written back over the served tree. Reclaiming:"
  git status --short | sed 's/^/[dev]   /'

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    mkdir -p "$dest/$(dirname "$file")" 2>/dev/null
    cp "$file" "$dest/$file" 2>/dev/null
  done < <(git diff --name-only --diff-filter=M -- src/ 2>/dev/null)

  git checkout -- src/ 2>/dev/null || return 1
  echo "[dev] What Studio wrote is copied under $dest — nothing was lost."
  echo "[dev] TURN TWO-WAY SYNC OFF in the Rojo plugin's settings and this stops."
  return 0
}

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
  #[[ Before the merge is attempted, not after it fails. --ff-only reports a
  #   blocked merge the same way whatever blocked it, so asking afterwards
  #   would mean re-deriving a cause git has already thrown away. ]]
  if [ "$RECLAIM" -eq 1 ] && writeback_only; then
    reclaim_writeback
  fi
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
