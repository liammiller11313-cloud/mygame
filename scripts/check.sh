#!/usr/bin/env bash
# Syntax-check + format every Luau source file in the project.
#   ./scripts/check.sh          format in place, report parse errors
#   ./scripts/check.sh --check  verify only, do not write
set -uo pipefail
export PATH="$HOME/.cargo/bin:$PATH"
cd "$(dirname "$0")/.."

if ! command -v stylua >/dev/null 2>&1; then
  echo "stylua not found. Install it with: rokit install   (or: cargo install stylua --features luau)" >&2
  exit 127
fi

MODE="${1:-format}"
# studio-scripts/ is included deliberately. Those are paste-into-the-command-bar
# scripts, so a syntax error in one is not caught by anything else and only shows
# up as a wall of red in Studio at exactly the moment someone is trying to get
# unblocked. audit.py still only looks at src/ — the cross-references it checks
# are game modules, and a command-bar script has none of them.
FILES=$(find src studio-scripts -name '*.lua' -type f 2>/dev/null | sort)
[ -z "$FILES" ] && { echo "no .lua files under src/ or studio-scripts/"; exit 0; }

TOTAL=$(echo "$FILES" | wc -l | tr -d ' ')
FAILED=0
ERRLOG=$(mktemp)

for f in $FILES; do
  if [ "$MODE" = "--check" ]; then
    OUT=$(stylua --check "$f" 2>&1); RC=$?
  else
    OUT=$(stylua "$f" 2>&1); RC=$?
  fi
  # stylua exits 2 (and prints "error") on a genuine parse failure;
  # a --check formatting difference is exit 1 with a diff, which is not a syntax error.
  if echo "$OUT" | grep -qi 'error'; then
    FAILED=$((FAILED + 1))
    { echo "=== PARSE ERROR: $f"; echo "$OUT"; echo; } >> "$ERRLOG"
  fi
done

echo "checked $TOTAL Luau file(s)"
if [ "$FAILED" -gt 0 ]; then
  echo "$FAILED file(s) failed to parse:" >&2
  cat "$ERRLOG" >&2
  rm -f "$ERRLOG"
  exit 1
fi
rm -f "$ERRLOG"
echo "all files parse cleanly"

# ── selene ──────────────────────────────────────────────────────────────────
# Parsing proves the file is Luau. It does NOT prove that every name in it
# resolves, and Lua's answer to an unresolved name is `nil` rather than an
# error — so a local used above its own declaration, or a service never fetched,
# compiles, loads, and throws the first time that one line runs.
#
# Four of those shipped in a single session before this was wired in: a damage
# number's RNG deleted with the function it sat next to, a stat height declared
# 120 lines below its only use, and a weapon-track table read by two functions
# several hundred lines above it. Every one of them passed stylua and audit.py.
#
# roblox.yml is hand-written rather than generated, because
# `selene generate-roblox-std` needs the network. It declares which GLOBALS
# exist and lets anything through underneath them, which is exactly enough for
# the undefined_variable lint and never enough for a false positive about an
# instance property.
if command -v selene >/dev/null 2>&1 && [ -f selene.toml ]; then
  echo
  selene --config selene.toml --display-style quiet src studio-scripts > /tmp/fl_selene.$$ 2>&1
  # Warnings are informational and printed; only a denied lint fails the build.
  if grep -qE "error\[" /tmp/fl_selene.$$; then
    grep -E "error\[" /tmp/fl_selene.$$ >&2
    rm -f /tmp/fl_selene.$$
    exit 1
  fi
  WARNED=$(grep -cE "warning\[" /tmp/fl_selene.$$ || true)
  rm -f /tmp/fl_selene.$$
  if [ "${WARNED:-0}" -gt 0 ]; then
    echo "selene: no undefined names ($WARNED unused-name warning(s))"
  else
    echo "selene: no undefined names"
  fi
else
  echo
  echo "selene not found — undefined-name checking SKIPPED (rokit install, or cargo install selene)" >&2
fi

# Parsing is not the same as resolving. audit.py cross-checks the names that
# only fail at runtime — remotes, enum keys, attributes, service lookups.
if command -v python3 >/dev/null 2>&1 && [ -f scripts/audit.py ]; then
  echo
  python3 scripts/audit.py || exit 1
fi

# Every remote has two halves in two different files, and a half is invisible.
# The bug this exists for is in ProjectileService's own header: InputController
# sent ThrowItem and nothing anywhere listened, so every throwable in the game
# was inert — no error, no warning, just a button that did nothing. audit.py
# checks that a remote NAME exists; this checks that both ends were wired.
if command -v python3 >/dev/null 2>&1 && [ -f scripts/remotes.py ]; then
  echo
  python3 scripts/remotes.py || exit 1
fi

# A carried item is a chain of eight links across six files — map folder, spawn
# point, pickup, slot, hand, use, effect, refill — and every one of them has
# broken at least once, always silently. items.py walks the chain itself rather
# than checking style: an item that cannot be picked up looks exactly like a map
# with no items in it, and a throwable with no effect looks like a throw that
# never happened.
if command -v python3 >/dev/null 2>&1 && [ -f scripts/items.py ]; then
  echo
  python3 scripts/items.py || exit 1
fi

# The economy is a set of numbers that only mean something together: change a
# payout without changing prices and the whole progression moves. economy.py
# models a round from the real config and fails when the pacing has drifted out
# of the band EconomyConfig's header promises.
if command -v python3 >/dev/null 2>&1 && [ -f scripts/economy.py ]; then
  if ! python3 scripts/economy.py --check > /tmp/fl_economy.$$ 2>&1; then
    echo
    tail -n 20 /tmp/fl_economy.$$ >&2
    rm -f /tmp/fl_economy.$$
    exit 1
  fi
  rm -f /tmp/fl_economy.$$
  echo
  echo "economy pacing within target"
fi
