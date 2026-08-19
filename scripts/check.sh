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

# Parsing is not the same as resolving. audit.py cross-checks the names that
# only fail at runtime — remotes, enum keys, attributes, service lookups.
if command -v python3 >/dev/null 2>&1 && [ -f scripts/audit.py ]; then
  echo
  python3 scripts/audit.py || exit 1
fi
