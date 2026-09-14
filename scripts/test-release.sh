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
#     number, packages with the existing scripts, verifies the checksum,
#     stages stable latest aliases, and uploads all four versioned plus
#     latest assets with no extra secrets and no shell/credential use
#   - README.md and docs/MACOS_PACKAGING.md expose both stable latest
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
if grep -Eq 'runs-on:.*macos-14' "$WF"; then
  ok "release workflow runs on macOS"
else
  bad "release workflow runs on macOS" "missing runs-on: macos-14"
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

# --- 6. Build, test, package through the existing scripts ---
if grep -Eq 'swift build' "$WF" && grep -Eq 'swift test' "$WF"; then
  ok "release workflow runs swift build and swift test"
else
  bad "release workflow runs swift build and swift test" "missing swift steps"
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
if grep -Eq 'scripts/package-release\.sh' "$WF"; then
  ok "release workflow packages with scripts/package-release.sh"
else
  bad "release workflow packages with scripts/package-release.sh" "missing package-release.sh"
fi
if grep -Eq 'shasum -a 256 -c' "$WF"; then
  ok "release workflow verifies the checksum"
else
  bad "release workflow verifies the checksum" "missing shasum -c"
fi

# --- 7. Versioned plus stable latest aliases, no hardcoded release number ---
if grep -Eq 'TokenBar-latest-macos\.zip' "$WF"; then
  ok "release workflow stages the stable latest alias"
else
  bad "release workflow stages the stable latest alias" "missing TokenBar-latest-macos.zip"
fi
if grep -Eq 'TokenBar-\$VERSION-macos\.zip|TokenBar-.*VERSION.*macos' "$WF"; then
  ok "release workflow keeps the versioned asset"
else
  bad "release workflow keeps the versioned asset" "missing versioned zip reference"
fi
if grep -Eq 'gh release create' "$WF"; then
  ok "release workflow creates the GitHub Release"
else
  bad "release workflow creates the GitHub Release" "missing gh release create"
fi
# All four files must ride on the gh release create invocation itself, not
# merely appear somewhere in the workflow.
RELEASE_BLOCK="$(sed -n '/gh release create/,/TokenBar-latest-macos\.zip\.sha256/p' "$WF")"
if [ -n "$RELEASE_BLOCK" ] \
  && printf '%s\n' "$RELEASE_BLOCK" | grep -Fq -e 'TokenBar-$VERSION-macos.zip"' \
  && printf '%s\n' "$RELEASE_BLOCK" | grep -Fq -e 'TokenBar-$VERSION-macos.zip.sha256"' \
  && printf '%s\n' "$RELEASE_BLOCK" | grep -Fq -e 'TokenBar-latest-macos.zip"' \
  && printf '%s\n' "$RELEASE_BLOCK" | grep -Fq -e 'TokenBar-latest-macos.zip.sha256"'; then
  ok "release upload carries all four versioned plus latest assets"
else
  bad "release upload carries all four versioned plus latest assets" "gh release create block must list both zips plus both checksums"
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
    ok "$doc links the stable latest checksum as Markdown"
  else
    bad "$doc links the stable latest checksum as Markdown" "missing [label](...TokenBar-latest-macos.zip.sha256) link"
  fi
  if grep -Eq 'shasum -a 256 -c' "$doc"; then
    ok "$doc documents checksum verification"
  else
    bad "$doc documents checksum verification" "missing shasum -c"
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

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
