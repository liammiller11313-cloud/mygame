#!/usr/bin/env bash
# Update the Rojo CLI in this folder, and the Studio plugin to match it.
#
#   ./scripts/update-rojo.sh           update to the latest release
#   ./scripts/update-rojo.sh 7.6.1     update to a specific version
#   ./scripts/update-rojo.sh --check   say what is available, change nothing
#
# ── WHY BOTH HALVES, ALWAYS ──────────────────────────────────────────────────
# Rojo is two programs that talk to each other: a CLI serving your files and a
# Studio plugin receiving them. They speak a versioned protocol, and when they
# disagree the plugin refuses to connect with "protocol version mismatch" — so
# updating one and not the other does not get you a newer Rojo, it gets you a
# Rojo that does not work.
#
# `rojo plugin install` installs the plugin build belonging to the CLI that ran
# it, which is why this runs it for you rather than leaving it as a step to
# remember. That is the whole reason this script exists instead of a line in a
# README saying "download the new one".
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd -P)"

TARGET=""
CHECK_ONLY=0
case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  -*) echo "unknown option: $1" >&2; exit 2 ;;
  *) TARGET="${1#v}" ;;
esac

# ── which build this machine wants ──────────────────────────────────────────
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS-$ARCH" in
  Darwin-arm64)  SLUG="macos-aarch64" ;;
  Darwin-x86_64) SLUG="macos-x86_64" ;;
  Linux-x86_64)  SLUG="linux-x86_64" ;;
  Linux-aarch64) SLUG="linux-aarch64" ;;
  *)
    echo "No prebuilt Rojo for $OS $ARCH." >&2
    echo "See https://github.com/rojo-rbx/rojo/releases" >&2
    exit 1
    ;;
esac

# ── what is here now ────────────────────────────────────────────────────────
if [ -x ./rojo ]; then
  ROJO=./rojo
elif command -v rojo >/dev/null 2>&1; then
  ROJO="$(command -v rojo)"
else
  ROJO=""
fi

CURRENT=""
if [ -n "$ROJO" ]; then
  CURRENT="$("$ROJO" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
fi
echo "installed: ${CURRENT:-none}${ROJO:+  ($ROJO)}"

# A Rokit-managed rojo is not ours to overwrite: replacing a shim with a binary
# leaves rokit.toml claiming a version that is no longer what runs.
case "$ROJO" in
  */.rokit/*)
    echo ""
    echo "That Rojo is managed by Rokit, so update it there instead:"
    echo "  1. edit rokit.toml and change the rojo version"
    echo "  2. rokit install"
    echo "  3. rojo plugin install     (keeps the Studio plugin matching)"
    echo "  4. restart Roblox Studio"
    exit 0
    ;;
esac

# ── what is available ───────────────────────────────────────────────────────
if [ -z "$TARGET" ]; then
  echo "checking for the latest release..."
  LATEST_JSON="$(curl -fsSL -m 20 https://api.github.com/repos/rojo-rbx/rojo/releases/latest 2>/dev/null)"
  TARGET="$(printf '%s' "$LATEST_JSON" | grep -m1 '"tag_name"' | sed 's/.*"v\{0,1\}\([0-9][^"]*\)".*/\1/')"
  if [ -z "$TARGET" ]; then
    echo "Could not reach GitHub to find the latest version." >&2
    echo "Open https://github.com/rojo-rbx/rojo/releases, note the version," >&2
    echo "then run:  ./scripts/update-rojo.sh <version>" >&2
    exit 1
  fi
fi
echo "latest:    $TARGET"

if [ "$CURRENT" = "$TARGET" ]; then
  echo ""
  echo "Already on $TARGET."
  echo "If Studio still says 'protocol version mismatch', the PLUGIN is the half"
  echo "that is behind. Fix just that:"
  echo "  $ROJO plugin install"
  echo "  then restart Roblox Studio."
  exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo ""
  echo "Run ./scripts/update-rojo.sh to install $TARGET."
  exit 0
fi

# ── the autostart job holds the old binary open ─────────────────────────────
# Replacing a running executable leaves the running process on the old inode, so
# it would keep serving the version you just replaced and nothing would look
# wrong. Stop it first, put it back at the end.
AGENT_LABEL="dev.fadinglight.rojo"
AGENT_WAS_UP=0
if [ "$OS" = "Darwin" ] && launchctl print "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1; then
  AGENT_WAS_UP=1
  echo "stopping the autostart job while we swap the binary"
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1
  sleep 1
fi

restore_agent() {
  if [ "$AGENT_WAS_UP" -eq 1 ]; then
    echo "restarting the autostart job"
    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$AGENT_LABEL.plist" >/dev/null 2>&1 \
      || launchctl load -w "$HOME/Library/LaunchAgents/$AGENT_LABEL.plist" >/dev/null 2>&1
  fi
}

# ── download and swap ───────────────────────────────────────────────────────
ASSET="rojo-$TARGET-$SLUG.zip"
URL="https://github.com/rojo-rbx/rojo/releases/download/v$TARGET/$ASSET"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "downloading $ASSET"
if ! curl -fsSL -m 120 -o "$TMP/rojo.zip" "$URL"; then
  echo "" >&2
  echo "Download failed: $URL" >&2
  echo "Check that version $TARGET exists and has a $SLUG build:" >&2
  echo "  https://github.com/rojo-rbx/rojo/releases" >&2
  restore_agent
  exit 1
fi

if ! unzip -oq "$TMP/rojo.zip" -d "$TMP"; then
  echo "The download did not unzip — it may be an error page rather than a zip." >&2
  restore_agent
  exit 1
fi

NEW="$(find "$TMP" -type f -name rojo -perm -u+r | head -1)"
if [ -z "$NEW" ]; then
  echo "No 'rojo' binary inside the archive." >&2
  restore_agent
  exit 1
fi

chmod +x "$NEW"
# macOS quarantines anything from the internet and refuses to run it with
# "the developer cannot be verified". Clearing it here is the same step
# docs/SETUP_MAC.md walks through by hand for the first install.
xattr -d com.apple.quarantine "$NEW" 2>/dev/null

mv -f "$NEW" "$REPO/rojo"
ROJO=./rojo
INSTALLED="$("$ROJO" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if [ -z "$INSTALLED" ]; then
  echo "The new binary is in place but will not report a version." >&2
  restore_agent
  exit 1
fi
echo "CLI is now $INSTALLED"

# ── keep the project pin honest ─────────────────────────────────────────────
# rokit.toml is what anyone else cloning this repo installs from. Leaving it
# pinned to a version nobody is running is how two machines quietly diverge.
if [ -f rokit.toml ] && grep -q '^rojo = ' rokit.toml; then
  if command -v sed >/dev/null 2>&1; then
    sed -i.bak "s|^rojo = \"rojo-rbx/rojo@.*\"|rojo = \"rojo-rbx/rojo@$INSTALLED\"|" rokit.toml && rm -f rokit.toml.bak
    echo "rokit.toml now pins $INSTALLED"
  fi
fi

# ── the half everyone forgets ───────────────────────────────────────────────
echo "installing the matching Studio plugin"
PLUGIN_OK=1
"$ROJO" plugin install || PLUGIN_OK=0

restore_agent

echo ""
if [ "$PLUGIN_OK" -eq 1 ]; then
  echo "Done — CLI and plugin are both on $INSTALLED."
  echo ""
  echo "RESTART ROBLOX STUDIO. A plugin that is already loaded stays the old one"
  echo "until Studio is closed and reopened, which looks exactly like the update"
  echo "not having worked."
else
  #[[ Saying "done" here would be a lie with consequences: a CLI and plugin on
  #   different versions is the exact state that produces "protocol version
  #   mismatch", and being told the update succeeded is what would stop anyone
  #   looking at the plugin. ]]
  echo "CLI updated to $INSTALLED, but THE PLUGIN DID NOT INSTALL — see the error above."
  echo ""
  echo "They are now on different versions, which is the state that makes Studio"
  echo "say 'protocol version mismatch'. Fix it before connecting:"
  echo ""
  echo "  ./rojo plugin install"
  echo ""
  echo "If that keeps failing, install the plugin from Studio's Toolbox instead"
  echo "(search Rojo) and make sure its version reads $INSTALLED."
fi
echo ""
echo "Then commit the pin so anyone else cloning this gets the same version:"
echo "  git add rokit.toml && git commit -m \"Update Rojo to $INSTALLED\""

[ "$PLUGIN_OK" -eq 1 ] || exit 1
