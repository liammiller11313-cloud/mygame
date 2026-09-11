#!/usr/bin/env bash
# github-login.sh — get this computer talking to the private repo. Once.
#
#   ./scripts/github-login.sh
#
# ── WHY THE PASSWORD SAYS WRONG ──────────────────────────────────────────────
# It is not wrong. GitHub stopped accepting account passwords over git on
# 13 August 2021. The box still says "Password", and it still rejects the
# password, and it does not explain the difference — so the obvious reading is
# "I typed it wrong", and typing it more carefully cannot ever work.
#
# What that box wants is a PERSONAL ACCESS TOKEN: a long string beginning
# ghp_ or github_pat_ that you generate on github.com and paste in once.
#
# This script gets one stored properly, and — just as important — clears out
# the bad credential the failed attempts already left in the Keychain, which
# git will otherwise keep sending on your behalf so that even a correct token
# looks like it failed.
set -uo pipefail
cd "$(dirname "$0")/.."

say() { printf '%s\n' "$*"; }
die() { say ""; say "✗ $*"; exit 1; }

# ── what are we even connecting to ──────────────────────────────────────────
REMOTE="$(git remote get-url origin 2>/dev/null)" || die "No 'origin' remote here. Is this the repo folder?"
SLUG="$(printf '%s' "$REMOTE" \
  | sed -e 's#^git@github\.com:#https://github.com/#' \
        -e 's#^ssh://git@github\.com/#https://github.com/#' \
        -e 's#^https://github\.com/##' -e 's#\.git$##' -e 's#/$##')"
case "$SLUG" in
  */*) : ;;
  *) die "Could not read an owner/repo out of the remote: $REMOTE" ;;
esac
OWNER="${SLUG%%/*}"

say "── github login ──"
say ""

#[[
#  Ask GitHub whether the repo is public before saying anything about what is
#  required, rather than assuming. The answer changes the advice completely: a
#  public repo is readable with no credential at all, so someone sent here by a
#  credential prompt on one is being asked for a login they do not need, and the
#  real fault is elsewhere — almost always a mistyped remote URL, since GitHub
#  answers 404 for a repo it cannot show you and git reads a 404 as "perhaps
#  they just need to log in".
#
#  Unauthenticated on purpose: that is exactly the request a stranger makes, so
#  a 200 means genuinely public and not merely visible to us.
#]]
VISIBILITY="unknown"
if command -v curl >/dev/null 2>&1; then
  case "$(curl -sS -o /dev/null -w '%{http_code}' "https://api.github.com/repos/$SLUG" 2>/dev/null)" in
    200) VISIBILITY="public" ;;
    404) VISIBILITY="private" ;;
  esac
fi
case "$VISIBILITY" in
  public)  NOTE="(public — reading it needs no credential at all)" ;;
  private) NOTE="(private — every fetch needs a credential)" ;;
  *)       NOTE="" ;;
esac
say "  repo        $SLUG  $NOTE"
say "  remote      $REMOTE"
say ""

if [ "$VISIBILITY" = "public" ]; then
  say "Heads up: this repo is public, so ./scripts/sync.sh needs no login."
  say "You only need a credential here to PUSH commits back up."
  say ""
  say "If a pull is still asking you to log in, the credential is not the"
  say "problem — check the remote URL above for a typo. GitHub answers 404"
  say "for a repo it cannot find, and git reads that as 'maybe log in'."
  say ""
  if [ -t 0 ]; then
    printf '  Set up pushing anyway? [y/N] '
    IFS= read -r ANSWER
    case "$ANSWER" in
      y|Y|yes|YES) say "" ;;
      *) say ""; say "Nothing changed. Run: ./scripts/sync.sh --force"; exit 0 ;;
    esac
  fi
fi

# ── 1. clear what is already saved and broken ───────────────────────────────
#[[
#  This has to happen first, and it is the step people skip.
#
#  Once anything has been typed at that prompt — a password, or a command that
#  landed in the username box by accident — a helper may have saved it. git
#  then sends the saved one silently on every later attempt. So the next
#  correct token appears to fail too, because it is never reached, and the loop
#  of "it keeps asking and keeps saying wrong" has no visible exit.
#]]
#[[
#  have_helper looks in git's exec-path as well as PATH, and that is not a
#  detail. Credential helpers are not installed as ordinary commands: on macOS
#  git-credential-osxkeychain lives inside `git --exec-path`, so a plain
#  `command -v` says it is absent on the exact machine where it is the helper
#  that matters. Testing only PATH would have made this whole step do nothing
#  on a Mac while still printing "done".
#]]
have_helper() {
  command -v "git-credential-$1" >/dev/null 2>&1 && return 0
  [ -x "$(git --exec-path)/git-credential-$1" ] && return 0
  return 1
}

say "Clearing any saved github.com credential (the failed attempts left one)..."
CLEARED=""
for helper in osxkeychain manager manager-core libsecret cache store; do
  have_helper "$helper" || continue
  printf 'protocol=https\nhost=github.com\n\n' \
    | git -c credential.helper="$helper" credential reject >/dev/null 2>&1
  CLEARED="$CLEARED $helper"
done
printf 'protocol=https\nhost=github.com\n\n' | git credential reject >/dev/null 2>&1
say "  cleared from:${CLEARED:- (no helper found — nothing was saved)}"
say ""

# ── 2. the easy road, if gh is installed ────────────────────────────────────
#[[
#  `gh auth login --web` is strictly nicer than the token flow: it shows an
#  eight-character code, opens github.com in the browser, and you approve it
#  there. Nothing secret is ever typed into a terminal, and gh installs itself
#  as git's credential helper afterwards. Worth preferring whenever it exists.
#]]
if command -v gh >/dev/null 2>&1; then
  say "GitHub CLI is installed — using it, so you never have to handle a token."
  say ""
  if gh auth status --hostname github.com >/dev/null 2>&1; then
    say "Already signed in as: $(gh auth status --hostname github.com 2>&1 | sed -n 's/.*account \([^ ]*\).*/\1/p' | head -1)"
  else
    say "A browser will open. Approve the code it shows you, then come back here."
    say ""
    gh auth login --hostname github.com --git-protocol https --web || die "gh auth login did not finish."
  fi
  gh auth setup-git --hostname github.com >/dev/null 2>&1
  say ""
else
  # ── 3. the token road ─────────────────────────────────────────────────────
  #[[
  #  Chosen here, written to git config in step 6 — after the token has been
  #  checked. A run that ends in "that was your password, not a token" should
  #  leave the machine's git configuration exactly as it found it.
  #]]
  if have_helper osxkeychain; then
    HELPER=osxkeychain
  elif [ "$(uname -s)" = "Darwin" ]; then
    HELPER=osxkeychain
  else
    HELPER=store
    say "⚠  No system keychain here, so the token will be saved as PLAIN TEXT"
    say "   in ~/.git-credentials. Fine on a machine only you use."
    say ""
  fi

  say "Open this link. The 'repo' box is already ticked for you:"
  say ""
  say "  https://github.com/settings/tokens/new?scopes=repo&description=Fading%20Light%20on%20this%20computer"
  say ""
  say "Scroll to the bottom, press 'Generate token', and copy the long string"
  say "it shows you. GitHub shows it exactly once."
  say ""
  say "Then paste it below. Nothing will appear as you paste — that is normal,"
  say "the characters are hidden on purpose. Press return when done."
  say ""

  [ -t 0 ] || die "Nothing to type into (stdin is not a terminal). Run this in a Terminal window."
  printf '  Paste token: '
  IFS= read -rs TOKEN
  printf '\n\n'
  [ -n "$TOKEN" ] || die "Nothing was pasted."

  #[[
  #  Check the SHAPE before the network does. Someone whose password has been
  #  rejected nine times will try the password a tenth time, and "401" is a much
  #  worse thing to tell them than "that is your password, not a token".
  #]]
  case "$TOKEN" in
    ghp_*|github_pat_*|gho_*|ghs_*|ghu_*) : ;;
    *)
      say "✗ That does not look like a token."
      say ""
      say "  Tokens begin with 'ghp_' or 'github_pat_' and are ~40-90 characters."
      say "  What you pasted begins '$(printf '%.4s' "$TOKEN")…' and is ${#TOKEN} characters."
      say ""
      say "  If that was your GitHub account password: that is exactly the thing"
      say "  that cannot work, no matter how correctly it is typed. Generate a"
      say "  token at the link above and paste that instead."
      exit 1
      ;;
  esac

  # ── 4. prove it works BEFORE saving it ────────────────────────────────────
  #[[
  #  Two calls, because they fail for different reasons and the difference is
  #  the whole diagnosis:
  #    /user            — is this token real and unexpired?
  #    /repos/OWNER/REPO — and can it see THIS private repo?
  #  A token with no 'repo' scope passes the first and 404s the second, which
  #  is indistinguishable from a typo unless you ask both questions.
  #
  #  --config - rather than -H so the token never appears in the process list,
  #  where any other program on the machine could read it.
  #]]
  command -v curl >/dev/null 2>&1 || die "curl is missing; cannot check the token."
  BODY="$(mktemp)"; trap 'rm -f "$BODY"' EXIT
  api() {
    printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\n' "$TOKEN" \
      | curl -sS --config - -o "$BODY" -w '%{http_code}' "https://api.github.com/$1" 2>/dev/null
  }

  say "Checking the token..."
  CODE="$(api user)"
  case "$CODE" in
    200)
      LOGIN="$(sed -n 's/.*"login"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$BODY" | head -1)"
      say "  valid, signed in as: ${LOGIN:-unknown}"
      if [ -n "$LOGIN" ] && [ "$LOGIN" != "$OWNER" ]; then
        say ""
        say "  ⚠  That is not '$OWNER', who owns this repo. If you have two"
        say "     GitHub accounts, this token belongs to the other one."
      fi
      ;;
    401) die "GitHub rejected the token (401). It was mistyped, or it has expired, or it was revoked. Generate a fresh one." ;;
    000) die "Could not reach github.com at all. Check the network, then re-run." ;;
    *)   say "  unexpected response $CODE from GitHub:"; sed 's/^/    /' "$BODY" | head -3; die "Stopping rather than saving a token that may not work." ;;
  esac

  CODE="$(api "repos/$SLUG")"
  case "$CODE" in
    200) say "  and it can see $SLUG. ✓" ;;
    403) die "The token is valid but forbidden on $SLUG (403). If the repo is under an organisation, the token needs to be authorised for it." ;;
    404)
      say ""
      say "✗ The token is valid, but cannot see $SLUG."
      say ""
      say "  A private repo answers 404 to anyone not allowed to look, so this"
      say "  means the token is missing the 'repo' permission — not that the"
      say "  repo is missing. Generate another with the 'repo' box ticked:"
      say ""
      say "  https://github.com/settings/tokens/new?scopes=repo&description=Fading%20Light%20on%20this%20computer"
      exit 1
      ;;
    *)   die "Unexpected response $CODE checking $SLUG." ;;
  esac

  # ── 5. save it ────────────────────────────────────────────────────────────
  git config --global credential.helper "$HELPER"
  USERNAME="${LOGIN:-$OWNER}"
  printf 'protocol=https\nhost=github.com\nusername=%s\npassword=%s\n\n' "$USERNAME" "$TOKEN" \
    | git -c credential.helper="$HELPER" credential approve \
    || die "Could not save the credential."
  TOKEN=""
  say ""
  say "Saved to the ${HELPER/osxkeychain/macOS Keychain}. You will not be asked again."
  say ""
fi

# ── 6. the only test that counts ────────────────────────────────────────────
say "Testing a real fetch..."
if OUT="$(GIT_TERMINAL_PROMPT=0 git ls-remote --heads origin 2>&1)"; then
  say "  ✓ connected — origin has $(printf '%s\n' "$OUT" | grep -c 'refs/heads/') branch(es)."
  say ""
  say "Done. Now run:  ./scripts/sync.sh --force"
else
  say "  ✗ still failing:"
  printf '%s\n' "$OUT" | sed 's/^/    /'
  say ""
  say "  Tell Claude exactly what those lines say."
  exit 1
fi
