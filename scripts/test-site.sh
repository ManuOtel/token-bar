#!/bin/sh
# test-site.sh - offline contract checks for the public product page.
#
# Asserts (no network, no build, dependency-free POSIX sh + grep):
#   - site/index.html plus site/styles.css exist; styles are local only
#   - required stable download links are present as HTML anchors:
#     latest dmg, zip, both SHA-256 checksums, repo, changelog
#   - exactly one h1 plus semantic landmarks (header/main/nav/footer,
#     lang, title, viewport, skip link)
#   - no external URLs outside the public repo or its Pages site, no
#     scripts, no external assets, no tracker/cookie strings
#   - page states the unsigned/not-notarized Gatekeeper note, the
#     estimates-only cost note, and the local-first privacy boundary
#   - page names the current VERSION (fails stale on version bump)
#   - no obvious personal data (emails, home dirs, SSH material,
#     real snapshot names)
#
# Run: ./scripts/test-site.sh (from the repo root).
set -eu
cd "$(dirname "$0")/.."

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s -- %s\n' "$1" "$2"; }

SITE="site/index.html"
CSS="site/styles.css"

# --- 1. Files exist ---
if [ -f "$SITE" ]; then
  ok "site page exists ($SITE)"
else
  bad "site page exists" "missing $SITE"
  printf '%d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi
if [ -f "$CSS" ]; then
  ok "site stylesheet exists ($CSS)"
else
  bad "site stylesheet exists" "missing $CSS"
fi

# --- 2. Required stable download links plus repo/changelog ---
for asset in \
  "releases/latest/download/TokenBar-latest-macos.zip\">" \
  "releases/latest/download/TokenBar-latest-macos.zip.sha256" \
  "releases/latest/download/TokenBar-latest-macos.dmg\">" \
  "releases/latest/download/TokenBar-latest-macos.dmg.sha256"; do
  base="$(printf '%s' "$asset" | sed 's/\\">$//')"
  if grep -Fq "$base" "$SITE"; then
    ok "site links $base"
  else
    bad "site links $base" "missing stable asset URL in $SITE"
  fi
done
if grep -Fq 'href="https://github.com/ManuOtel/token-bar"' "$SITE"; then
  ok "site links the public repository"
else
  bad "site links the public repository" "missing anchor to https://github.com/ManuOtel/token-bar"
fi
if grep -Fq "https://github.com/ManuOtel/token-bar/blob/main/CHANGELOG.md" "$SITE"; then
  ok "site links the public changelog"
else
  bad "site links the public changelog" "missing CHANGELOG.md anchor"
fi

# --- 3. Exactly one h1 plus landmarks ---
H1_COUNT="$(grep -o -i '<h1[ >]' "$SITE" | wc -l | tr -d ' ')"
if [ "$H1_COUNT" = "1" ]; then
  ok "site has exactly one h1"
else
  bad "site has exactly one h1" "found $H1_COUNT"
fi
for landmark in '<header' '<main' '<nav' '<footer' 'lang="en"' '<title>' 'name="viewport"' 'href="#main"'; do
  if grep -Fq "$landmark" "$SITE"; then
    ok "site has landmark $landmark"
  else
    bad "site has landmark $landmark" "missing in $SITE"
  fi
done

# --- 4. No external URLs outside the public repo ---
# Every http(s) URL in HTML/CSS must stay on github.com/ManuOtel/token-bar.
# Every http(s) URL in HTML/CSS must stay on the public repo or its
# Pages site. Fragments stay split so this validator never self-matches
# the privacy guard's path rule.
_PU1='/Us'; _PU2='ers/'; _PH1='/ho'; _PH2='me/'
URLS="$(grep -rhoE 'https?://[^"'"'"' )<>]+' site/ || true)"
BAD_URLS=""
for url in $URLS; do
  case "$url" in
    https://github.com/ManuOtel/token-bar*|https://manuotel.github.io/token-bar*) ;;
    *) BAD_URLS="$BAD_URLS $url" ;;
  esac
done
if [ -z "$BAD_URLS" ]; then
  ok "site uses no external URLs outside the public repo"
else
  bad "site uses no external URLs outside the public repo" "found:$BAD_URLS"
fi

# --- 5. No scripts, external assets, trackers, or cookies ---
if grep -qiE '<script|onclick|onload=|onerror=|<iframe' "$SITE"; then
  bad "site ships no scripts or frames" "found script/iframe/event handler"
else
  ok "site ships no scripts or frames"
fi
if grep -qiE '@import|url\(http|<img[^>]+src="http|<link[^>]+href="http' site/index.html site/styles.css; then
  bad "site ships no external assets" "found remote import/img/link"
else
  ok "site ships no external assets"
fi
if grep -qiE 'googletag|google-analytics|plausible|segment\.io|mixpanel|hotjar|doubleclick|facebook\.net|intercom|document\.cookie|localStorage' site/index.html site/styles.css; then
  bad "site ships no trackers or cookie use" "found tracker/cookie string"
else
  ok "site ships no trackers or cookie use"
fi

# --- 6. Required product copy ---
if grep -qi 'unsigned' "$SITE" && grep -qi 'not notarized' "$SITE" \
  && grep -qi 'Gatekeeper' "$SITE" && grep -qi 'right-click Open' "$SITE"; then
  ok "site states the unsigned Gatekeeper opening note"
else
  bad "site states the unsigned Gatekeeper opening note" "needs unsigned/not-notarized/Gatekeeper/right-click Open copy"
fi
if grep -qi 'estimate' "$SITE" && grep -qi 'never a bill' "$SITE"; then
  ok "site labels costs as estimates only"
else
  bad "site labels costs as estimates only" "needs estimate/never-a-bill copy"
fi
if grep -qi 'never leave the machine' "$SITE" && grep -qi 'no accounts' "$SITE"; then
  ok "site states the local-first privacy boundary"
else
  bad "site states the local-first privacy boundary" "needs never-leave/no-accounts copy"
fi

# --- 7. Version freshness: page names current VERSION ---
if [ -f VERSION ]; then
  CURRENT="$(tr -d ' \t\r\n' < VERSION)"
  if grep -Fq "v$CURRENT" "$SITE"; then
    ok "site names current VERSION (v$CURRENT)"
  else
    bad "site names current VERSION" "missing v$CURRENT in $SITE (stale version claim)"
  fi
else
  bad "VERSION file exists" "missing at repo root"
fi

# --- 8. No obvious personal data in the site ---
# Path/SSH/snapshot literals are assembled from the split fragments above
# so this validator never self-matches the privacy guard.
_SSH='.ssh'; _HS='homeserver'; _OR='opencode-remote.json'; _OH='opencode-homeserver.json'
_CX='.codex/sessions'; _CL='.claude/projects'; _IR='id_rsa'
if grep -qiE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' site/index.html site/styles.css; then
  bad "site contains no email addresses" "found email-like string"
else
  ok "site contains no email addresses"
fi
if grep -qE "${_PU1}${_PU2}|${_PH1}${_PH2}|${_SSH}|${_IR}|${_HS}|${_OR}|${_OH}|${_CX}|${_CL}" site/index.html site/styles.css; then
  bad "site contains no private paths or snapshot names" "found home/ssh/snapshot string"
else
  ok "site contains no private paths or snapshot names"
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
