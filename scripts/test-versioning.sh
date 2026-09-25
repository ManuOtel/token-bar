#!/bin/sh
# test-versioning.sh - focused versioning checks for the release scripts.
#
# Black-box only: runs the real scripts with stubbed external tools and
# asserts the resolved version in Info.plist / artifact names. Covers:
#   - VERSION file exists and is SemVer x.y.z (single source of truth)
#   - build-app.sh defaults to VERSION, TOKENBAR_VERSION env wins,
#     --version flag wins over env, --build / --bundle-id still apply
#   - package-release.sh falls back to VERSION, env and flag precedence,
#     invalid versions rejected
#
# Needs no Swift toolchain and no network: `swift` and `zip` are stubbed
# on PATH. Run: ./scripts/test-versioning.sh (from the repo root).
set -eu
cd "$(dirname "$0")/.."

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s -- %s\n' "$1" "$2"; }

TMP="$(mktemp -d)"
HAD_BUILD=0
[ -d .build ] && HAD_BUILD=1
cleanup() { rm -rf "$TMP"; if [ "$HAD_BUILD" -eq 0 ]; then rm -rf .build; fi; }
trap cleanup EXIT

# --- Stubs (shadow real tools; repo-local effects only) ---
mkdir -p "$TMP/stubbin"
cat > "$TMP/stubbin/swift" <<'EOF'
#!/bin/sh
mkdir -p .build/release
printf '#!/bin/sh\nexit 0\n' > .build/release/TokenBarApp
chmod +x .build/release/TokenBarApp
exit 0
EOF
cat > "$TMP/stubbin/zip" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in *.zip) : > "$a" ;; esac
done
exit 0
EOF
cat > "$TMP/stubbin/hdiutil" <<'EOF'
#!/bin/sh
# Stub hdiutil for Linux: records the -srcfolder staging layout, asserts it
# holds TokenBar.app plus an Applications symlink to /Applications, then
# touches the artifact path (last non-flag arg).
SRC=""
LAST=""
for a in "$@"; do
  case "$a" in
    -srcfolder) WANT_SRC=1 ;;
    *)
      if [ "${WANT_SRC:-0}" -eq 1 ]; then SRC="$a"; WANT_SRC=0;
      else LAST="$a"; fi ;;
  esac
done
if [ -n "$SRC" ]; then
  APP_HIT="$(find "$SRC" -maxdepth 1 -name '*.app' | head -1 || true)"
  if [ -z "$APP_HIT" ]; then echo "stub hdiutil: no .app in staging $SRC" >&2; exit 1; fi
  if [ ! -L "$SRC/Applications" ]; then echo "stub hdiutil: Applications symlink missing in $SRC" >&2; exit 1; fi
  if [ "$(readlink "$SRC/Applications")" != "/Applications" ]; then echo "stub hdiutil: Applications symlink target wrong" >&2; exit 1; fi
fi
if [ -n "$LAST" ]; then : > "$LAST"; fi
exit 0
EOF
cat > "$TMP/stubbin/qlmanage" <<'EOF'
#!/bin/sh
OUT=""
SOURCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    -*) shift ;;
    *) SOURCE="$1"; shift ;;
  esac
done
mkdir -p "$OUT"
: > "$OUT/$(basename "$SOURCE").png"
EOF
cat > "$TMP/stubbin/sips" <<'EOF'
#!/bin/sh
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    *) shift ;;
  esac
done
: > "$OUT"
EOF
cat > "$TMP/stubbin/iconutil" <<'EOF'
#!/bin/sh
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    *) shift ;;
  esac
done
: > "$OUT"
EOF
chmod +x "$TMP/stubbin/swift" "$TMP/stubbin/zip" "$TMP/stubbin/hdiutil" \
  "$TMP/stubbin/qlmanage" "$TMP/stubbin/sips" "$TMP/stubbin/iconutil"
PATH="$TMP/stubbin:$PATH"
export PATH

plist_val() {
  # $1 = plist path, $2 = key name. Prints the <string> on the key line
  # (build-app.sh writes key and value on one line).
  grep "<key>$2</key>" "$1" | head -1 | sed 's/.*<string>//;s/<\/string>.*//'
}

clean_env() {
  # Strip version-related env so each case controls its own inputs.
  env -u TOKENBAR_VERSION -u TOKENBAR_BUILD -u TOKENBAR_BUNDLE_ID \
      -u TOKENBAR_APP -u TOKENBAR_FORMAT "$@"
}

# --- 1. VERSION file is the SemVer source of truth ---
if [ ! -f VERSION ]; then
  bad "VERSION file exists" "missing at repo root"
  printf '%d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi
EXPECTED="$(tr -d ' \t\r\n' < VERSION)"
if printf '%s' "$EXPECTED" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  ok "VERSION is SemVer x.y.z ($EXPECTED)"
else
  bad "VERSION is SemVer x.y.z" "got '$EXPECTED'"
fi

# --- 2. build-app.sh defaults to VERSION ---
clean_env ./scripts/build-app.sh --output "$TMP/Default.app" >/dev/null
if [ "$(plist_val "$TMP/Default.app/Contents/Info.plist" CFBundleShortVersionString)" = "$EXPECTED" ]; then
  ok "build-app default version matches VERSION ($EXPECTED)"
else
  bad "build-app default version matches VERSION" \
    "got '$(plist_val "$TMP/Default.app/Contents/Info.plist" CFBundleShortVersionString)'"
fi
if [ -f "$TMP/Default.app/Contents/Resources/TokenBar.icns" ] \
  && grep -Fq '<key>CFBundleIconFile</key><string>TokenBar.icns</string>' \
    "$TMP/Default.app/Contents/Info.plist"; then
  ok "build-app packages the Token Bar app icon"
else
  bad "build-app packages the Token Bar app icon" "missing TokenBar.icns or CFBundleIconFile"
fi

# --- 3. TOKENBAR_VERSION env overrides the default ---
clean_env env TOKENBAR_VERSION=9.8.7 TOKENBAR_BUILD=42 \
  ./scripts/build-app.sh --output "$TMP/Env.app" >/dev/null
if [ "$(plist_val "$TMP/Env.app/Contents/Info.plist" CFBundleShortVersionString)" = "9.8.7" ] \
   && [ "$(plist_val "$TMP/Env.app/Contents/Info.plist" CFBundleVersion)" = "42" ]; then
  ok "build-app env override applies (9.8.7 build 42)"
else
  bad "build-app env override applies" "unexpected Info.plist values"
fi

# --- 4. --version / --build flags win over env ---
clean_env env TOKENBAR_VERSION=9.8.7 TOKENBAR_BUILD=42 \
  ./scripts/build-app.sh --version 1.2.3 --build 5 --bundle-id com.example.TokenBar \
  --output "$TMP/Flag.app" >/dev/null
if [ "$(plist_val "$TMP/Flag.app/Contents/Info.plist" CFBundleShortVersionString)" = "1.2.3" ] \
   && [ "$(plist_val "$TMP/Flag.app/Contents/Info.plist" CFBundleVersion)" = "5" ] \
   && [ "$(plist_val "$TMP/Flag.app/Contents/Info.plist" CFBundleIdentifier)" = "com.example.TokenBar" ]; then
  ok "build-app flag precedence applies (1.2.3 build 5, custom bundle id)"
else
  bad "build-app flag precedence applies" "unexpected Info.plist values"
fi

# --- 5. Invalid versions are rejected ---
if clean_env ./scripts/build-app.sh --version 'bad version!' --output "$TMP/Bad.app" >/dev/null 2>&1; then
  bad "build-app rejects invalid version" "exit 0"
else
  ok "build-app rejects invalid version"
fi

# --- 6. package-release.sh falls back to VERSION (no flag/env/plist) ---
mkdir -p "$TMP/NoPlist.app"
clean_env ./scripts/package-release.sh --app "$TMP/NoPlist.app" --outdir "$TMP/out" >/dev/null
if [ -f "$TMP/out/TokenBar-$EXPECTED-macos.zip" ] \
   && [ -f "$TMP/out/TokenBar-$EXPECTED-macos.zip.sha256" ]; then
  ok "package-release default artifact uses VERSION ($EXPECTED)"
else
  bad "package-release default artifact uses VERSION" "unexpected dist contents: $(ls "$TMP/out" 2>/dev/null)"
fi

# --- 7. package-release env override, then flag-wins-over-env ---
mkdir -p "$TMP/Other.app"
clean_env env TOKENBAR_VERSION=7.7.7 \
  ./scripts/package-release.sh --app "$TMP/Other.app" --outdir "$TMP/out-env" >/dev/null
if [ -f "$TMP/out-env/TokenBar-7.7.7-macos.zip" ]; then
  ok "package-release env override applies (7.7.7)"
else
  bad "package-release env override applies" "unexpected dist contents: $(ls "$TMP/out-env" 2>/dev/null)"
fi
clean_env env TOKENBAR_VERSION=7.7.7 \
  ./scripts/package-release.sh --version 6.6.6 --app "$TMP/Other.app" --outdir "$TMP/out-flag" >/dev/null
if [ -f "$TMP/out-flag/TokenBar-6.6.6-macos.zip" ]; then
  ok "package-release flag wins over env (6.6.6)"
else
  bad "package-release flag wins over env" "unexpected dist contents: $(ls "$TMP/out-flag" 2>/dev/null)"
fi

# --- 8. package-release rejects invalid versions ---
if clean_env ./scripts/package-release.sh --version 'oops!' --app "$TMP/Other.app" \
    --outdir "$TMP/out-bad" >/dev/null 2>&1; then
  bad "package-release rejects invalid version" "exit 0"
else
  ok "package-release rejects invalid version"
fi

# --- 9. package-release dmg stages the drag-and-drop layout (stubbed hdiutil) ---
mkdir -p "$TMP/Dmg.app/Contents"
clean_env ./scripts/package-release.sh --version 6.6.7 --format dmg \
  --app "$TMP/Dmg.app" --outdir "$TMP/out-dmg" >/dev/null
if [ -f "$TMP/out-dmg/TokenBar-6.6.7-macos.dmg" ] \
   && [ -f "$TMP/out-dmg/TokenBar-6.6.7-macos.dmg.sha256" ]; then
  ok "package-release dmg artifact uses the requested version (6.6.7)"
else
  bad "package-release dmg artifact uses the requested version" "unexpected dist contents: $(ls "$TMP/out-dmg" 2>/dev/null)"
fi

# --- 10. package-release keeps zip behavior alongside dmg ---
mkdir -p "$TMP/Both.app"
clean_env ./scripts/package-release.sh --version 6.6.7 --format zip \
  --app "$TMP/Both.app" --outdir "$TMP/out-both" >/dev/null
clean_env ./scripts/package-release.sh --version 6.6.7 --format dmg \
  --app "$TMP/Both.app" --outdir "$TMP/out-both" >/dev/null
if [ -f "$TMP/out-both/TokenBar-6.6.7-macos.zip" ] \
   && [ -f "$TMP/out-both/TokenBar-6.6.7-macos.dmg" ] \
   && [ -f "$TMP/out-both/TokenBar-6.6.7-macos.zip.sha256" ] \
   && [ -f "$TMP/out-both/TokenBar-6.6.7-macos.dmg.sha256" ]; then
  ok "package-release keeps both zip and dmg artifacts plus checksums"
else
  bad "package-release keeps both zip and dmg artifacts plus checksums" "unexpected dist contents: $(ls "$TMP/out-both" 2>/dev/null)"
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
