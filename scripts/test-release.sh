#!/bin/sh
# test-release.sh - contract checks for the tag-driven public release path.
#
# Asserts (no Swift toolchain, no network):
#   - VERSION is SemVer x.y.z (single source of truth, never bumped here)
#   - .github/workflows/release.yml exists, parses as YAML when PyYAML is
#     available, triggers exactly on the version-tag shape, keeps exactly
#     one read default plus one job-scoped write widening
#   - the workflow validates the pushed tag against VERSION, runs swift build
#     plus swift test, builds with VERSION plus the monotonic workflow build
#     number, packages both zip and dmg with the existing scripts, verifies
#     both checksums, runs the DMG layout verification, stages stable
#     latest aliases for both formats, and uploads all eight versioned plus
#     latest assets with no extra secrets and no shell/credential use
#   - scripts/package-release.sh stages the DMG drag-and-drop layout
#     (TokenBar.app plus an Applications symlink to /Applications) with
#     safe cleanup, and fails clearly off macOS when hdiutil is missing
#   - scripts/verify-dmg.sh mounts the DMG read-only, asserts TokenBar.app
#     plus the Applications symlink, and always detaches/cleans up
#   - README.md and docs/MACOS_PACKAGING.md expose all four stable latest
#     downloads as Markdown links, checksum verification, release tag
#     steps, and the unsigned/not-notarized Gatekeeper note
#
# Run: ./scripts/test-release.sh (from the repo root).
set -eu
cd "$(dirname "$0")/.."

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s -- %s\n' "$1" "$2"; }

WF=".github/workflows/release.yml"
README="README.md"
PACKAGING="docs/MACOS_PACKAGING.md"

# --- 1. VERSION stays the SemVer source of truth ---
if [ ! -f VERSION ]; then
  bad "VERSION file exists" "missing at repo root"
else
  EXPECTED="$(tr -d ' \t\r\n' < VERSION)"
  if printf '%s' "$EXPECTED" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    ok "VERSION is SemVer x.y.z ($EXPECTED)"
  else
    bad "VERSION is SemVer x.y.z" "got '$EXPECTED'"
    EXPECTED="0.0.0"
  fi
fi

# --- 2. Workflow file exists ---
if [ ! -f "$WF" ]; then
  bad "release workflow exists" "missing $WF"
  printf '%d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi
ok "release workflow exists ($WF)"

# --- 3. YAML syntax (PyYAML when available, structural grep otherwise) ---
if python3 -c "import yaml" 2>/dev/null; then
  if python3 -c "import yaml,sys; yaml.safe_load(open('$WF'))"; then
    ok "release workflow parses as YAML"
  else
    bad "release workflow parses as YAML" "yaml.safe_load failed"
  fi
else
  if grep -Eq '^[a-zA-Z_]+:' "$WF" && grep -Eq 'on:|jobs:|steps:' "$WF"; then
    ok "release workflow has YAML structure (PyYAML unavailable, grep fallback)"
  else
    bad "release workflow has YAML structure" "missing top-level keys"
  fi
fi

# --- 4. Exact trigger shape, exact permission arrangement, platform ---
if grep -Fq -e '- "v[0-9]*.[0-9]*.[0-9]*"' "$WF" \
  && [ "$(grep -c -e 'tags:' "$WF" || true)" -eq 1 ] \
  && [ "$(grep -c -e 'v\[0-9\]' "$WF" || true)" -eq 1 ]; then
  ok "release workflow triggers exactly on the version-tag shape"
else
  bad "release workflow triggers exactly on the version-tag shape" "expected a single tags entry: - \"v[0-9]*.[0-9]*.[0-9]*\""
fi
if grep -Eq 'runs-on:.*macos-26' "$WF"; then
  ok "release workflow runs on macOS 26 for Liquid Glass"
else
  bad "release workflow runs on macOS 26 for Liquid Glass" "missing runs-on: macos-26"
fi
# Count effective (non-comment) config lines so prose comments can never
# satisfy the arrangement check.
WF_CODE="$(grep -v -e '^[[:space:]]*#' "$WF")"
if [ "$(printf '%s\n' "$WF_CODE" | grep -c -e '^ *permissions: *$' || true)" -eq 2 ] \
  && [ "$(printf '%s\n' "$WF_CODE" | grep -c -e 'contents: *read' || true)" -eq 1 ] \
  && [ "$(printf '%s\n' "$WF_CODE" | grep -c -e 'contents: *write' || true)" -eq 1 ]; then
  ok "release workflow has one read default plus one write widening"
else
  bad "release workflow has one read default plus one write widening" "expected 2 permissions blocks with 1 contents: read and 1 contents: write"
fi
if grep -Eq 'contents:[[:space:]]*write-all|permissions:[[:space:]]*write-all|admin' "$WF"; then
  bad "release workflow avoids over-broad permissions" "found write-all/admin"
else
  ok "release workflow avoids over-broad permissions"
fi

# --- 5. Tag-vs-VERSION validation consumes the VERSION file ---
if grep -Eq 'GITHUB_REF_NAME' "$WF" && grep -Eq '< VERSION|cat VERSION|VERSION.*file' "$WF"; then
  ok "release workflow validates the pushed tag against VERSION"
else
  bad "release workflow validates the pushed tag against VERSION" "missing tag/VERSION comparison"
fi
if grep -Eq 'v\$VERSION|v0|expected .v' "$WF"; then
  ok "release workflow requires the exact v<VERSION> tag"
else
  bad "release workflow requires the exact v<VERSION> tag" "missing v VERSION check"
fi

# --- 6. Build, test, package both formats through the existing scripts ---
if grep -Eq 'swift build' "$WF" && grep -Eq 'swift test' "$WF"; then
  ok "release workflow runs swift build and swift test"
else
  bad "release workflow runs swift build and swift test" "missing swift steps"
fi
if grep -Eq 'xcrun --sdk macosx --show-sdk-version' "$WF" \
  && grep -Eq '26\.\*' "$WF"; then
  ok "release workflow rejects a toolchain without the macOS 26 SDK"
else
  bad "release workflow rejects a toolchain without the macOS 26 SDK" "missing the SDK guard"
fi
if grep -Eq 'scripts/build-app\.sh' "$WF"; then
  ok "release workflow builds with scripts/build-app.sh"
else
  bad "release workflow builds with scripts/build-app.sh" "missing build-app.sh"
fi
if grep -Eq 'GITHUB_RUN_NUMBER|RUN_NUMBER' "$WF"; then
  ok "release workflow uses the monotonic workflow build number"
else
  bad "release workflow uses the monotonic workflow build number" "missing run number"
fi
if grep -Eq 'scripts/package-release\.sh.*--format zip' "$WF" \
  && grep -Eq 'scripts/package-release\.sh.*--format dmg' "$WF"; then
  ok "release workflow packages both zip and dmg with scripts/package-release.sh"
else
  bad "release workflow packages both zip and dmg with scripts/package-release.sh" "missing --format zip and --format dmg invocations"
fi
if grep -Eq 'TokenBar-\$VERSION-macos\.zip\.sha256' "$WF" \
  && grep -Eq 'TokenBar-\$VERSION-macos\.dmg\.sha256' "$WF" \
  && [ "$(grep -c -e 'shasum -a 256 -c' "$WF" || true)" -ge 2 ]; then
  ok "release workflow verifies both zip and dmg checksums"
else
  bad "release workflow verifies both zip and dmg checksums" "missing shasum -c for both formats"
fi
if grep -Eq 'scripts/verify-dmg\.sh' "$WF"; then
  ok "release workflow runs the DMG layout verification"
else
  bad "release workflow runs the DMG layout verification" "missing scripts/verify-dmg.sh"
fi

# --- 7. Versioned plus stable latest aliases for both formats, no hardcoded release number ---
if grep -Eq 'TokenBar-latest-macos\.zip' "$WF" \
  && grep -Eq 'TokenBar-latest-macos\.dmg' "$WF"; then
  ok "release workflow stages both stable latest aliases"
else
  bad "release workflow stages both stable latest aliases" "missing TokenBar-latest-macos.zip and TokenBar-latest-macos.dmg"
fi
if grep -Eq 'TokenBar-latest-macos\.zip\.sha256' "$WF" \
  && grep -Eq 'TokenBar-latest-macos\.dmg\.sha256' "$WF"; then
  ok "release workflow stages both stable latest checksums"
else
  bad "release workflow stages both stable latest checksums" "missing latest .sha256 aliases for both formats"
fi
if grep -Eq 'TokenBar-\$VERSION-macos\.zip|TokenBar-.*VERSION.*macos' "$WF" \
  && grep -Eq 'TokenBar-\$VERSION-macos\.dmg' "$WF"; then
  ok "release workflow keeps both versioned assets"
else
  bad "release workflow keeps both versioned assets" "missing versioned zip and dmg references"
fi
if grep -Eq 'gh release create' "$WF"; then
  ok "release workflow creates the GitHub Release"
else
  bad "release workflow creates the GitHub Release" "missing gh release create"
fi
# All eight files must ride on the gh release create invocation itself, not
# merely appear somewhere in the workflow.
RELEASE_BLOCK="$(sed -n '/gh release create/,/TokenBar-latest-macos\.dmg\.sha256/p' "$WF")"
if [ -n "$RELEASE_BLOCK" ] \
  && printf '%s\n' "$RELEASE_BLOCK" | grep -Fq -e 'TokenBar-$VERSION-macos.zip"' \
  && printf '%s\n' "$RELEASE_BLOCK" | grep -Fq -e 'TokenBar-$VERSION-macos.zip.sha256"' \
  && printf '%s\n' "$RELEASE_BLOCK" | grep -Fq -e 'TokenBar-latest-macos.zip"' \
  && printf '%s\n' "$RELEASE_BLOCK" | grep -Fq -e 'TokenBar-latest-macos.zip.sha256"' \
  && printf '%s\n' "$RELEASE_BLOCK" | grep -Fq -e 'TokenBar-$VERSION-macos.dmg"' \
  && printf '%s\n' "$RELEASE_BLOCK" | grep -Fq -e 'TokenBar-$VERSION-macos.dmg.sha256"' \
  && printf '%s\n' "$RELEASE_BLOCK" | grep -Fq -e 'TokenBar-latest-macos.dmg"' \
  && printf '%s\n' "$RELEASE_BLOCK" | grep -Fq -e 'TokenBar-latest-macos.dmg.sha256"'; then
  ok "release upload carries all eight versioned plus latest assets"
else
  bad "release upload carries all eight versioned plus latest assets" "gh release create block must list both zips plus both dmgs plus all four checksums"
fi
if grep -Eq '0\.3\.0|0\.2\.0|0\.1\.0' "$WF"; then
  bad "release workflow consumes VERSION instead of hardcoding" "found hardcoded release number"
else
  ok "release workflow consumes VERSION instead of hardcoding"
fi

# --- 8. No extra secrets, no shell/credential use in the workflow ---
SECRET_USES="$(grep -Eo 'secrets\.[A-Za-z0-9_]+' "$WF" || true)"
if [ -z "$SECRET_USES" ]; then
  bad "release workflow auth is the automatic token only" "no secrets reference found"
else
  EXTRA="$(printf '%s\n' "$SECRET_USES" | grep -v 'secrets\.GITHUB_TOKEN' || true)"
  if [ -n "$EXTRA" ]; then
    bad "release workflow uses no provider credentials" "extra secrets: $EXTRA"
  else
    ok "release workflow uses no provider credentials"
  fi
fi
if grep -Eq 'ssh|scp|BatchMode|Cookie|Authorization' "$WF"; then
  bad "release workflow stays offline-safe" "found network/credential use"
else
  ok "release workflow stays offline-safe"
fi

# --- 9. Public docs: Markdown download links, checksum, Gatekeeper note, release steps ---
for doc in "$README" "$PACKAGING"; do
  if grep -Eq '\]\(https?://[^)]*releases/latest/download/TokenBar-latest-macos\.zip\)' "$doc"; then
    ok "$doc links the stable latest zip as Markdown"
  else
    bad "$doc links the stable latest zip as Markdown" "missing [label](...TokenBar-latest-macos.zip) link"
  fi
  if grep -Eq '\]\(https?://[^)]*releases/latest/download/TokenBar-latest-macos\.zip\.sha256\)' "$doc"; then
    ok "$doc links the stable latest zip checksum as Markdown"
  else
    bad "$doc links the stable latest zip checksum as Markdown" "missing [label](...TokenBar-latest-macos.zip.sha256) link"
  fi
  if grep -Eq '\]\(https?://[^)]*releases/latest/download/TokenBar-latest-macos\.dmg\)' "$doc"; then
    ok "$doc links the stable latest dmg as Markdown"
  else
    bad "$doc links the stable latest dmg as Markdown" "missing [label](...TokenBar-latest-macos.dmg) link"
  fi
  if grep -Eq '\]\(https?://[^)]*releases/latest/download/TokenBar-latest-macos\.dmg\.sha256\)' "$doc"; then
    ok "$doc links the stable latest dmg checksum as Markdown"
  else
    bad "$doc links the stable latest dmg checksum as Markdown" "missing [label](...TokenBar-latest-macos.dmg.sha256) link"
  fi
  if grep -Eq 'shasum -a 256 -c' "$doc"; then
    ok "$doc documents checksum verification"
  else
    bad "$doc documents checksum verification" "missing shasum -c"
  fi
  if grep -Eqi 'drag.*Applications|Applications.*drag' "$doc"; then
    ok "$doc documents drag-and-drop install"
  else
    bad "$doc documents drag-and-drop install" "missing drag TokenBar.app to Applications copy"
  fi
  if grep -Eqi 'unsigned|not notarized|notarized' "$doc" && grep -Eqi 'Gatekeeper' "$doc"; then
    ok "$doc notes the unsigned Gatekeeper behavior"
  else
    bad "$doc notes the unsigned Gatekeeper behavior" "missing unsigned/notarized Gatekeeper note"
  fi
done
if grep -Eq 'git tag v|v\$|push origin.*v' "$PACKAGING"; then
  ok "packaging doc explains the tag-driven release steps"
else
  bad "packaging doc explains the tag-driven release steps" "missing tag/push instructions"
fi

# --- 10. DMG drag-and-drop layout in scripts/package-release.sh ---
PKG="scripts/package-release.sh"
if [ ! -f "$PKG" ]; then
  bad "package-release.sh exists" "missing $PKG"
else
  if grep -Eq 'ln -s /Applications' "$PKG" \
    && grep -Eq 'Applications' "$PKG"; then
    ok "package-release.sh stages the Applications alias"
  else
    bad "package-release.sh stages the Applications alias" "missing ln -s /Applications staging"
  fi
  if grep -Eq 'mktemp -d' "$PKG" \
    && grep -Eq 'rm -rf "\$STAGE"|rm -rf \$STAGE|cleanup_stage' "$PKG"; then
    ok "package-release.sh cleans up DMG staging"
  else
    bad "package-release.sh cleans up DMG staging" "missing mktemp staging plus cleanup"
  fi
  if grep -Eq '\-\-format (zip\|dmg)|--format.*dmg' "$PKG" \
    && grep -Eq '"\$FORMAT"|FORMAT' "$PKG"; then
    ok "package-release.sh supports both zip and dmg formats"
  else
    bad "package-release.sh supports both zip and dmg formats" "missing --format zip|dmg handling"
  fi
  if grep -Eq 'hdiutil not found' "$PKG" \
    && grep -Eq 'command -v hdiutil' "$PKG"; then
    ok "package-release.sh fails clearly off macOS without hdiutil"
  else
    bad "package-release.sh fails clearly off macOS without hdiutil" "missing hdiutil guard"
  fi
  if grep -Eq 'checksum_file|sha256' "$PKG"; then
    ok "package-release.sh generates checksums"
  else
    bad "package-release.sh generates checksums" "missing checksum generation"
  fi
fi

# --- 11. DMG runtime verifier in scripts/verify-dmg.sh ---
VERIFY="scripts/verify-dmg.sh"
if [ ! -f "$VERIFY" ]; then
  bad "verify-dmg.sh exists" "missing $VERIFY"
else
  if [ -x "$VERIFY" ]; then
    ok "verify-dmg.sh is executable"
  else
    bad "verify-dmg.sh is executable" "missing +x bit"
  fi
  if grep -Eq 'hdiutil attach.*-readonly' "$VERIFY" \
    && grep -Eq 'hdiutil detach' "$VERIFY"; then
    ok "verify-dmg.sh mounts read-only and always detaches"
  else
    bad "verify-dmg.sh mounts read-only and always detaches" "missing hdiutil attach -readonly plus detach"
  fi
  if grep -Eq 'trap .*cleanup|trap cleanup EXIT' "$VERIFY"; then
    ok "verify-dmg.sh cleans up on EXIT"
  else
    bad "verify-dmg.sh cleans up on EXIT" "missing trap cleanup"
  fi
  if grep -Eq 'TokenBar\.app' "$VERIFY" \
    && grep -Eq 'Applications' "$VERIFY"; then
    ok "verify-dmg.sh asserts TokenBar.app plus the Applications symlink"
  else
    bad "verify-dmg.sh asserts TokenBar.app plus the Applications symlink" "missing both entry checks"
  fi
  if grep -Eq 'readlink|/Applications' "$VERIFY"; then
    ok "verify-dmg.sh validates the Applications symlink target"
  else
    bad "verify-dmg.sh validates the Applications symlink target" "missing symlink target check"
  fi
  if grep -Eq 'hdiutil not found' "$VERIFY"; then
    ok "verify-dmg.sh fails clearly off macOS without hdiutil"
  else
    bad "verify-dmg.sh fails clearly off macOS without hdiutil" "missing hdiutil guard"
  fi
  if sh -n "$VERIFY" && bash -n "$VERIFY"; then
    ok "verify-dmg.sh passes shell syntax checks"
  else
    bad "verify-dmg.sh passes shell syntax checks" "sh/bash -n failed"
  fi
fi

# --- 12. Public product page contract (offline, no build) ---
# The Linux CI job already runs this script, so delegating here runs the
# site checks on every PR without touching the CI/release workflows.
if [ -x scripts/test-site.sh ]; then
  if scripts/test-site.sh; then
    ok "public site contract passes (scripts/test-site.sh)"
  else
    bad "public site contract passes" "scripts/test-site.sh failed"
  fi
else
  bad "public site validator exists" "missing executable scripts/test-site.sh"
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
