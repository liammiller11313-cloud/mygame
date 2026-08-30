#!/usr/bin/env bash
# check.sh — format, syntax-check and audit. Run before you call a change done.
#
#   ./scripts/check.sh          format in place, then audit
#   ./scripts/check.sh --check  verify without writing (what CI runs)
#
# StyLua is doing two jobs here, and the second is the important one: it parses
# with full-moon, so anything it cannot format is a syntax error it will name
# with a line number.
set -euo pipefail

cd "$(dirname "$0")/.."
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

fail=0
mapfile -t LUA_FILES < <(find src -name '*.lua' | sort)

if [[ ${#LUA_FILES[@]} -eq 0 ]]; then
	echo "no .lua files under src/ — nothing to check"
	exit 0
fi

echo "== StyLua (${#LUA_FILES[@]} files) =="
if command -v stylua >/dev/null 2>&1; then
	# The pinned native binary. This is the one that decides CI.
	if [[ $CHECK_ONLY -eq 1 ]]; then
		stylua --check "${LUA_FILES[@]}" || fail=1
	else
		stylua "${LUA_FILES[@]}"
	fi
elif [[ -d scripts/luau-wasm/node_modules ]]; then
	# Same parser, no release binary needed. See scripts/luau-wasm/README.md.
	echo "  (stylua not on PATH — using the WASM fallback)"
	if [[ $CHECK_ONLY -eq 1 ]]; then
		node scripts/luau-wasm/check.mjs "${LUA_FILES[@]}" || fail=1
	else
		node scripts/luau-wasm/format.mjs "${LUA_FILES[@]}"
	fi
else
	echo "  SKIPPED — no stylua on PATH and the WASM fallback is not installed."
	echo "  Fix with:  rokit install   (preferred)"
	echo "         or:  npm install --prefix scripts/luau-wasm"
	fail=1
fi

echo
echo "== selene =="
if command -v selene >/dev/null 2>&1; then
	selene src || fail=1
else
	echo "  SKIPPED — selene not on PATH (rokit install)"
fi

echo
if [[ $fail -ne 0 ]]; then
	echo "check.sh FAILED"
	exit 1
fi
echo "check.sh passed"
