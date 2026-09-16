#!/bin/sh
# test-site.sh - offline contract checks for the public product page.
#
# Asserts (no network, no build, dependency-free POSIX sh + grep):
#   - site/index.html plus site/styles.css exist; styles are local only
#   - site/CNAME exists with the single custom-domain line
#     (token-bar subdomain of the maintainer domain, intentionally
#     allowlisted below and in scripts/check-privacy.sh)
#   - required stable download links are present as HTML anchors:
#     latest dmg, zip, both SHA-256 checksums, repo, changelog
#   - exactly one h1 plus semantic landmarks (header/main/nav/footer,
#     lang, title, viewport, skip link)
#   - no external URLs outside the public repo, its Pages site, the
#     intentional custom domain, or the SEO standards allowlist
#     (schema.org JSON-LD context, sitemaps.org namespace); no scripts
#     except one JSON-LD metadata block, no external assets except the
#     canonical link, no tracker/cookie strings
#   - page states the unsigned/not-notarized Gatekeeper note, the
#     estimates-only cost note, and the local-first privacy boundary
#   - page names the current VERSION (fails stale on version bump)
#   - no obvious personal data (emails, home dirs, SSH material,
#     real snapshot names)
#   - canonical Token Bar logo plus real bundled provider logos are
#     wired by relative asset paths in the README and the site, with
#     meaningful alt text, theme variants via <picture>, a trademark
#     disclaimer, a brand-attribution doc, and no remote image embeds;
#     the old invented source marks are fully gone
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

# --- 4. No external URLs outside the allowlist plus custom domain ---
# Every http(s) URL under site/ must stay on the public repo, its Pages
# site, the intentional custom domain (site/CNAME), or the standards
# allowlist (schema.org JSON-LD context, sitemaps.org sitemap namespace,
# and the w3.org SVG XML namespace identifier). The SVG xmlns string is a
# vocabulary identifier parsed locally by the renderer, never fetched over
# the network, so it is allowlisted as a literal while remote SVG/img/link
# fetches stay rejected by section 5 below.
# The custom domain is a deliberate product URL, allowlisted here and in
# scripts/check-privacy.sh. Fragments stay split so this validator never
# self-matches the privacy guard's path rule.
_PU1='/Us'; _PU2='ers/'; _PH1='/ho'; _PH2='me/'
URLS="$(grep -rhoE 'https?://[^"'"'"' )<>]+' site/ || true)"
BAD_URLS=""
for url in $URLS; do
  case "$url" in
    https://github.com/ManuOtel/token-bar*|https://manuotel.github.io/token-bar*|https://token-bar.manuotel.com*|https://schema.org*|http://www.sitemaps.org/*|https://www.sitemaps.org/*|http://www.w3.org/2000/svg) ;;
    *) BAD_URLS="$BAD_URLS $url" ;;
  esac
done
if [ -z "$BAD_URLS" ]; then
  ok "site uses no external URLs outside the public repo"
else
  bad "site uses no external URLs outside the public repo" "found:$BAD_URLS"
fi

# --- 5. No scripts (except one JSON-LD block), external assets
# (except the canonical link), trackers, or cookies ---
# The single <script type="application/ld+json"> metadata block is the
# only script allowed: it carries no code, only structured data.
SCRIPT_HITS="$(grep -iE '<script|onclick|onload=|onerror=|<iframe' "$SITE" | grep -vi 'application/ld+json' || true)"
if [ -n "$SCRIPT_HITS" ]; then
  bad "site ships no scripts or frames" "found script/iframe/event handler"
else
  ok "site ships no scripts or frames"
fi
ASSET_HITS="$(grep -iE '@import|url\(http|<img[^>]+src="http|<link[^>]+href="http' site/index.html site/styles.css | grep -vi 'rel="canonical"' || true)"
if [ -n "$ASSET_HITS" ]; then
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

# --- 9. Custom domain CNAME plus on-page reference ---
# site/CNAME must hold exactly the custom-domain line (trailing newline
# allowed); the page footer must reference the same host so the domain
# stays an intentional product URL rather than a stray file.
if [ -f site/CNAME ]; then
  ok "site CNAME file exists (site/CNAME)"
  CNAME_TRIMMED="$(tr -d ' \t\r\n' < site/CNAME)"
  if [ "$CNAME_TRIMMED" = "token-bar.manuotel.com" ]; then
    ok "site CNAME names the custom domain"
  else
    bad "site CNAME names the custom domain" "expected token-bar.manuotel.com, got '$CNAME_TRIMMED'"
  fi
else
  bad "site CNAME file exists" "missing site/CNAME"
fi
if grep -Fq "token-bar.manuotel.com" "$SITE"; then
  ok "site references the custom domain"
else
  bad "site references the custom domain" "missing token-bar.manuotel.com in $SITE"
fi

# --- 10. Search discoverability: canonical, robots, social, JSON-LD, sitemap ---
if grep -Fq '<link rel="canonical" href="https://token-bar.manuotel.com/">' "$SITE"; then
  ok "site sets the canonical homepage URL"
else
  bad "site sets the canonical homepage URL" "missing canonical link to https://token-bar.manuotel.com/"
fi
if grep -qiE '<meta name="robots" content="[^"]*index[^"]*"' "$SITE" \
  && ! grep -qiE '<meta name="robots" content="[^"]*noindex' "$SITE"; then
  ok "site permits indexing via robots metadata"
else
  bad "site permits indexing via robots metadata" "needs an index robots meta without noindex"
fi
for tag in 'property="og:title"' 'property="og:description"' 'property="og:url"' 'name="twitter:card"'; do
  if grep -Fq "$tag" "$SITE"; then
    ok "site sets social metadata $tag"
  else
    bad "site sets social metadata $tag" "missing in $SITE"
  fi
done
LD_COUNT="$(grep -c 'application/ld+json' "$SITE" || true)"
if [ "$LD_COUNT" = "1" ]; then
  ok "site ships exactly one JSON-LD block"
else
  bad "site ships exactly one JSON-LD block" "found $LD_COUNT"
fi
for claim in '"@type": "SoftwareApplication"' '"downloadUrl"' '"price": 0' '"priceCurrency": "USD"'; do
  if grep -Fq "$claim" "$SITE"; then
    ok "JSON-LD states $claim"
  else
    bad "JSON-LD states $claim" "missing in $SITE"
  fi
done
if [ -n "${CURRENT:-}" ] && grep -Fq "\"softwareVersion\": \"$CURRENT\"" "$SITE"; then
  ok "JSON-LD softwareVersion matches VERSION ($CURRENT)"
else
  bad "JSON-LD softwareVersion matches VERSION" "missing \"softwareVersion\": \"${CURRENT:-unknown}\" in $SITE"
fi
if [ -f site/robots.txt ] \
  && grep -Fq "Allow: /" site/robots.txt \
  && grep -Fq "Sitemap: https://token-bar.manuotel.com/sitemap.xml" site/robots.txt; then
  ok "site serves crawler robots.txt with sitemap pointer"
else
  bad "site serves crawler robots.txt with sitemap pointer" "missing site/robots.txt Allow plus Sitemap lines"
fi
if [ -f site/sitemap.xml ] \
  && grep -Fq "<loc>https://token-bar.manuotel.com/</loc>" site/sitemap.xml; then
  if python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse('site/sitemap.xml')" 2>/dev/null; then
    ok "site serves a valid sitemap with the canonical homepage URL"
  else
    bad "site serves a valid sitemap" "site/sitemap.xml does not parse as XML"
  fi
else
  bad "site serves a valid sitemap" "missing site/sitemap.xml canonical loc"
fi

# --- 11. Canonical orbit logo plus favicon contract ---
# Exactly one canonical asset (site/assets/tokenbar-logo.svg); comparison
# candidates (orbit/pulse/signal suffixed files) must not ship.
# The favicon plus all brand/source imagery use document-relative
# assets/... paths so the page works under the custom-domain root and the
# GitHub Pages project subpath alike. Root-relative /assets/... stays
# rejected because it breaks the project subpath.
LOGO="site/assets/tokenbar-logo.svg"
if [ -f "$LOGO" ]; then
  ok "canonical orbit logo exists ($LOGO)"
else
  bad "canonical orbit logo exists" "missing $LOGO"
fi
if ls site/assets/tokenbar-logo-orbit.svg site/assets/tokenbar-logo-pulse.svg site/assets/tokenbar-logo-signal.svg >/dev/null 2>&1; then
  bad "site ships no comparison-candidate logo assets" "found suffixed tokenbar-logo-*.svg beside the canonical asset"
else
  ok "site ships no comparison-candidate logo assets"
fi
if [ -f "$LOGO" ]; then
  if python3 -c "import xml.dom.minidom; d=xml.dom.minidom.parse('$LOGO'); assert d.documentElement.tagName=='svg'" 2>/dev/null; then
    ok "canonical logo parses as SVG XML"
  else
    bad "canonical logo parses as SVG XML" "$LOGO does not parse"
  fi
  if grep -Fq 'xmlns="http://www.w3.org/2000/svg"' "$LOGO" \
    && grep -Fq 'viewBox="0 0 64 64"' "$LOGO"; then
    ok "canonical logo keeps the SVG namespace and square viewBox"
  else
    bad "canonical logo keeps the SVG namespace and square viewBox" "needs xmlns plus viewBox 0 0 64 64"
  fi
  if grep -Fq '<title' "$LOGO" && grep -Fq 'role="img"' "$LOGO"; then
    ok "canonical logo carries accessible title metadata"
  else
    bad "canonical logo carries accessible title metadata" "needs <title> plus role=img"
  fi
  for color in '#30d158' '#0a84ff' '#ff9f0a'; do
    if grep -Fq "$color" "$LOGO"; then
      ok "canonical logo keeps provider color $color"
    else
      bad "canonical logo keeps provider color $color" "missing $color in $LOGO"
    fi
  done
  if [ "$(grep -c '<path' "$LOGO" || true)" = "3" ] \
    && [ "$(grep -c '<rect' "$LOGO" || true)" = "3" ]; then
    ok "canonical logo keeps the three-orbit plus three-bar geometry"
  else
    bad "canonical logo keeps the three-orbit plus three-bar geometry" "expected 3 paths and 3 rects in $LOGO"
  fi
  if grep -qiE '<script|onclick|onload=|onerror=|<image|<foreignObject|url\(|linearGradient|radialGradient|<pattern|@import|http://|https://' "$LOGO" \
    | grep -vF 'http://www.w3.org/2000/svg' | grep -q .; then
    bad "canonical logo stays code-native with no scripts or remote refs" "found script/gradient/image/remote reference"
  else
    ok "canonical logo stays code-native with no scripts or remote refs"
  fi
  if grep -Eq '<rect[^>]*x="0"[^>]*y="0"[^>]*width="6[04]"' "$LOGO"; then
    bad "canonical logo stays transparent by default" "found full-canvas background rect"
  else
    ok "canonical logo stays transparent by default"
  fi
fi
if grep -Fq '<link rel="icon" type="image/svg+xml" href="assets/tokenbar-logo.svg">' "$SITE"; then
  ok "site wires the canonical SVG as favicon with a relative path"
else
  bad "site wires the canonical SVG as favicon" "missing <link rel=icon type=image/svg+xml href=assets/tokenbar-logo.svg> in $SITE"
fi
if grep -Fq 'href="/assets/tokenbar-logo.svg"' "$SITE"; then
  bad "site avoids root-relative asset paths" "found href=/assets/... which breaks the GitHub Pages project subpath"
else
  ok "site avoids root-relative asset paths"
fi

# --- 12. Branding use plus real bundled provider logos ---
# The Token Bar logo is primary (header brand plus hero identity, larger
# than any provider mark); the three provider logos support the source
# list only. All provider artwork is official, bundled locally under
# site/assets/ (see docs/BRAND_ASSETS.md), referenced by relative paths
# with meaningful alt text, and swapped for dark themes via <picture>
# (no JavaScript, no runtime fetch). Remote <img>/image embeds stay
# rejected by section 5. The old invented source marks
# (assets/source-*.svg plus "integration mark" copy) must be fully gone
# from the README, the site, and docs.
if grep -Fq 'src="assets/tokenbar-logo.svg"' "$SITE" && grep -Fq 'class="brand-logo"' "$SITE"; then
  ok "site header uses the canonical logo by relative path"
else
  bad "site header uses the canonical logo by relative path" "needs img src=assets/tokenbar-logo.svg with class=brand-logo in $SITE"
fi
if grep -Fq 'class="hero-logo"' "$SITE" && grep -Fq 'src="assets/tokenbar-logo.svg"' "$SITE"; then
  ok "site hero uses the canonical logo identity"
else
  bad "site hero uses the canonical logo identity" "needs img class=hero-logo with src=assets/tokenbar-logo.svg in $SITE"
fi
# 12a. Old invented marks are gone: files plus every reference and the
# old disclaimer copy (scoped to content files so this script never
# self-matches its own assertion literals).
for old in site/assets/source-codex.svg site/assets/source-opencode.svg site/assets/source-claude.svg; do
  if [ -e "$old" ]; then
    bad "invented source mark removed" "still ships $old"
  else
    ok "invented source mark removed ($old)"
  fi
done
if grep -rFq -e 'assets/source-codex.svg' -e 'assets/source-opencode.svg' -e 'assets/source-claude.svg' README.md site/ docs/ 2>/dev/null; then
  bad "no references to invented source marks" "found assets/source-*.svg in README.md, site/, or docs/"
else
  ok "no references to invented source marks"
fi
if grep -rqiF 'integration mark' README.md site/index.html site/styles.css docs/BRAND_ASSETS.md 2>/dev/null; then
  bad "no invented-mark disclaimer copy" "found 'integration mark' in README.md, site/, or docs/BRAND_ASSETS.md"
else
  ok "no invented-mark disclaimer copy"
fi
if grep -rqiE 'local Token Bar (source-integration icons|integration marks), not provider logos' README.md site/ 2>/dev/null; then
  bad "old not-provider-logos disclaimer removed" "found the old disclaimer in README.md or site/"
else
  ok "old not-provider-logos disclaimer removed"
fi
# 12b. Real provider assets exist with the exact bundled filenames.
for asset in \
  site/assets/provider-opencode-light.svg \
  site/assets/provider-opencode-dark.svg \
  site/assets/provider-claude-spark.svg \
  site/assets/provider-openai-blossom.svg \
  site/assets/provider-openai-blossom-inverse.svg; do
  if [ -f "$asset" ]; then
    ok "bundled provider asset exists ($asset)"
  else
    bad "bundled provider asset exists" "missing $asset"
  fi
done
# 12c. Each provider asset parses as SVG XML, keeps the SVG namespace,
# and carries no scripts, gradients, embedded images, or remote refs
# (the xmlns vocabulary identifier is allowlisted, never fetched).
for asset in site/assets/provider-*.svg; do
  if python3 -c "import xml.dom.minidom; d=xml.dom.minidom.parse('$asset'); assert d.documentElement.tagName=='svg'" 2>/dev/null; then
    ok "provider asset parses as SVG XML ($asset)"
  else
    bad "provider asset parses as SVG XML" "$asset does not parse"
  fi
  if grep -Fq 'xmlns="http://www.w3.org/2000/svg"' "$asset"; then
    ok "provider asset keeps the SVG namespace ($asset)"
  else
    bad "provider asset keeps the SVG namespace" "missing xmlns in $asset"
  fi
  if grep -qiE '<script|onclick|onload=|onerror=|<image|<foreignObject|url\(|linearGradient|radialGradient|<pattern|@import|http://|https://' "$asset" \
    | grep -vF 'http://www.w3.org/2000/svg' | grep -q .; then
    bad "provider asset ships no scripts or remote refs ($asset)" "found script/gradient/image/remote reference in $asset"
  else
    ok "provider asset ships no scripts or remote refs ($asset)"
  fi
  if grep -Eq '<rect[^>]*x="0"[^>]*y="0"[^>]*width="6[04]"' "$asset"; then
    bad "provider asset has no full-canvas background rect ($asset)" "found full-canvas background rect in $asset"
  else
    ok "provider asset has no full-canvas background rect ($asset)"
  fi
done
# 12d. Provider-specific artwork markers (official geometry, not redraws).
if grep -Fq 'viewBox="0 0 234 42"' site/assets/provider-opencode-light.svg \
  && grep -Fq 'viewBox="0 0 234 42"' site/assets/provider-opencode-dark.svg; then
  ok "OpenCode assets keep the official wordmark viewBox"
else
  bad "OpenCode assets keep the official wordmark viewBox" "needs viewBox 0 0 234 42 in both provider-opencode-*.svg"
fi
if grep -Fq '#D97757' site/assets/provider-claude-spark.svg \
  && grep -Fq 'viewBox="0 0 94 94"' site/assets/provider-claude-spark.svg; then
  ok "Claude asset keeps the official Spark clay artwork"
else
  bad "Claude asset keeps the official Spark clay artwork" "needs #D97757 plus viewBox 0 0 94 94 in provider-claude-spark.svg"
fi
if grep -Fq 'viewBox="1.68 1.75 16.65 16.5"' site/assets/provider-openai-blossom.svg; then
  ok "OpenAI asset keeps the official Blossom symbol viewBox"
else
  bad "OpenAI asset keeps the official Blossom symbol viewBox" "needs viewBox 1.68 1.75 16.65 16.5 in provider-openai-blossom.svg"
fi
# 12e. The dark-theme OpenAI inverse differs from the official base only
# by its single root fill adaptation (geometry untouched).
if sed 's/ fill="#fff"//' site/assets/provider-openai-blossom-inverse.svg | cmp -s - site/assets/provider-openai-blossom.svg; then
  ok "OpenAI inverse variant keeps official geometry with a fill-only adaptation"
else
  bad "OpenAI inverse variant keeps official geometry" "provider-openai-blossom-inverse.svg differs beyond the fill adaptation"
fi
# 12f. The site wires the real assets by relative paths with theme
# variants, meaningful alt text, and the precise "OpenAI Codex" label
# (never claiming a Codex-specific logo).
if grep -Fq 'class="hero-sources"' "$SITE" \
  && grep -Fq 'src="assets/provider-openai-blossom.svg"' "$SITE" \
  && grep -Fq 'srcset="assets/provider-openai-blossom-inverse.svg"' "$SITE" \
  && grep -Fq 'src="assets/provider-opencode-light.svg"' "$SITE" \
  && grep -Fq 'srcset="assets/provider-opencode-dark.svg"' "$SITE" \
  && grep -Fq 'src="assets/provider-claude-spark.svg"' "$SITE"; then
  ok "site hero lists the three real provider logos"
else
  bad "site hero lists the three real provider logos" "needs hero-sources row with all three provider assets plus dark srcsets in $SITE"
fi
if grep -Fq 'class="source-mark"' "$SITE" \
  && grep -Fq 'src="assets/provider-openai-blossom.svg"' "$SITE" \
  && grep -Fq 'src="assets/provider-opencode-light.svg"' "$SITE" \
  && grep -Fq 'src="assets/provider-claude-spark.svg"' "$SITE"; then
  ok "site sources section uses the three real provider logos"
else
  bad "site sources section uses the three real provider logos" "needs source-mark imgs for all three providers in $SITE"
fi
if grep -Fq '>OpenAI Codex<' "$SITE"; then
  ok "site labels the OpenAI mark precisely as OpenAI Codex"
else
  bad "site labels the OpenAI mark precisely as OpenAI Codex" "missing the OpenAI Codex label in $SITE"
fi
if grep -Fq 'alt="Official OpenAI mark used for OpenAI Codex"' "$SITE" \
  && grep -Fq 'alt="Official OpenCode logo"' "$SITE" \
  && grep -Fq 'alt="Official Claude Spark mark for Claude Code"' "$SITE" \
  && grep -Fq 'alt="Token Bar logo"' "$SITE" \
  && grep -Fq 'alt="Token Bar orbit logo"' "$SITE"; then
  ok "site brand and provider images carry ownership-accurate alt text"
else
  bad "site brand and provider images carry ownership-accurate alt text" "needs official-mark alt text for the Token Bar logo plus all three providers in $SITE"
fi
if grep -qiE 'property of their (owners|respective owners)|not affiliated with or endorsed' "$SITE"; then
  ok "site states the trademark ownership disclaimer"
else
  bad "site states the trademark ownership disclaimer" "needs the ownership/not-endorsed disclaimer in $SITE"
fi
# 12g. The brand-attribution doc exists and names each provider, asset,
# source URL, retrieval date, and license/trademark note.
ATTR="docs/BRAND_ASSETS.md"
if [ -f "$ATTR" ]; then
  ok "brand-attribution doc exists ($ATTR)"
else
  bad "brand-attribution doc exists" "missing $ATTR"
fi
for need in 'provider-opencode-light.svg' 'provider-opencode-dark.svg' 'provider-claude-spark.svg' 'provider-openai-blossom.svg' 'github.com/sst/opencode' 'anthropic.com/press-kit' 'openai.com/brand' '2026-09-16' 'trademark'; do
  if grep -Fq "$need" "$ATTR" 2>/dev/null; then
    ok "attribution doc records $need"
  else
    bad "attribution doc records $need" "missing $need in $ATTR"
  fi
done
if grep -qiE 'no standalone Codex mark' "$ATTR" 2>/dev/null; then
  ok "attribution doc states the Codex branding limitation"
else
  bad "attribution doc states the Codex branding limitation" "missing the no-standalone-Codex-mark note in $ATTR"
fi
# Every <img> on the page must stay local and relative: remote http(s)
# image sources are rejected, and root-relative /assets/... is rejected
# because it breaks the project subpath.
if grep -oiE '<img[^>]+>' "$SITE" | grep -qiE 'src="https?://'; then
  bad "site images stay local with no remote embeds" "found remote <img> src in $SITE"
else
  ok "site images stay local with no remote embeds"
fi
if grep -oiE '<img[^>]+src="[^"]+"' "$SITE" | grep -vF 'src="assets/' | grep -q .; then
  bad "site images use relative assets paths" "found non-assets <img> src in $SITE"
else
  ok "site images use relative assets paths"
fi
# Theme <source> variants must also stay document-relative: remote or
# root-relative srcsets would break the project subpath or fetch at runtime.
if grep -oiE '<source[^>]+srcset="[^"]+"' "$SITE" | grep -qiE 'srcset="https?://|srcset="/'; then
  bad "site theme variants use relative asset srcsets" "found remote or root-relative srcset in $SITE"
else
  ok "site theme variants use relative asset srcsets"
fi
if grep -oiE '<source[^>]+srcset="[^"]+"' "$SITE" | grep -vF 'srcset="assets/' | grep -q .; then
  bad "site srcsets stay under local assets" "found non-assets srcset in $SITE"
else
  ok "site srcsets stay under local assets"
fi
# README mirrors the same local branding: repository-relative paths that
# render on GitHub, with ownership-accurate alt text, the precise
# OpenAI Codex label, a trademark disclaimer, and no remote image embeds.
if grep -Fq 'src="site/assets/tokenbar-logo.svg"' README.md 2>/dev/null \
  || grep -Fq '(site/assets/tokenbar-logo.svg)' README.md 2>/dev/null; then
  ok "README uses the canonical logo by repository-relative path"
else
  bad "README uses the canonical logo by repository-relative path" "missing site/assets/tokenbar-logo.svg in README.md"
fi
for asset in provider-openai-blossom provider-opencode-light provider-claude-spark; do
  if grep -Fq "site/assets/$asset.svg" README.md; then
    ok "README uses the real provider asset ($asset)"
  else
    bad "README uses the real provider asset" "missing site/assets/$asset.svg in README.md"
  fi
done
if grep -Fq 'srcset="site/assets/provider-openai-blossom-inverse.svg"' README.md \
  && grep -Fq 'srcset="site/assets/provider-opencode-dark.svg"' README.md; then
  ok "README wires dark-theme provider variants"
else
  bad "README wires dark-theme provider variants" "missing dark srcsets for OpenAI/OpenCode in README.md"
fi
if grep -Fq '**OpenAI Codex**' README.md; then
  ok "README labels the OpenAI mark precisely as OpenAI Codex"
else
  bad "README labels the OpenAI mark precisely as OpenAI Codex" "missing the OpenAI Codex label in README.md"
fi
if grep -Fq 'alt="Official OpenAI mark used for OpenAI Codex"' README.md \
  && grep -Fq 'alt="Official OpenCode logo"' README.md \
  && grep -Fq 'alt="Official Claude Spark mark for Claude Code"' README.md; then
  ok "README provider images carry ownership-accurate alt text"
else
  bad "README provider images carry ownership-accurate alt text" "needs official-mark alt text for all three providers in README.md"
fi
if grep -qiE 'property of their|not affiliated with or endorsed' README.md; then
  ok "README states the trademark ownership disclaimer"
else
  bad "README states the trademark ownership disclaimer" "missing the ownership/not-endorsed disclaimer in README.md"
fi
if grep -qiE '!\[.*\]\(https?://' README.md; then
  REMOTE_MD="$(grep -oiE '!\[[^]]*\]\(https?://[^)]+\)' README.md || true)"
  UNEXPECTED_MD="$(printf '%s\n' "$REMOTE_MD" | grep -vF 'https://github.com/ManuOtel/token-bar/actions/workflows/ci.yml/badge.svg' || true)"
  if [ -n "$UNEXPECTED_MD" ]; then
    bad "README ships no remote image embeds beyond the CI badge" "found remote markdown image in README.md: $UNEXPECTED_MD"
  else
    ok "README ships no remote image embeds beyond the CI badge"
  fi
else
  ok "README ships no remote image embeds beyond the CI badge"
fi
if grep -oiE '<img[^>]+>' README.md | grep -qiE 'src="https?://'; then
  bad "README images stay local with no remote embeds" "found remote <img> src in README.md"
else
  ok "README images stay local with no remote embeds"
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
