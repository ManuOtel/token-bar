#!/bin/sh
# Build a versioned TokenBar.app from the TokenBarApp SwiftPM product.
#
# Usage:
#   ./scripts/build-app.sh [--version 0.1.0] [--build 1]
#                          [--bundle-id com.manuotel.TokenBar]
#                          [--output dist/TokenBar.app]
#
# Env overrides (same effect as flags):
#   TOKENBAR_VERSION=0.2.0 TOKENBAR_BUILD=3 TOKENBAR_BUNDLE_ID=com.example.TokenBar
#
# Output: <output>/Contents/{MacOS/TokenBar,Resources,Info.plist}
# Requires: macOS 14 SDK + Swift 5.9+ (run on a Mac). No signing, no network,
# no credentials. For signed releases see docs/MACOS_PACKAGING.md.
set -eu
cd "$(dirname "$0")/.."

VERSION="${TOKENBAR_VERSION:-0.1.0}"
BUILD="${TOKENBAR_BUILD:-1}"
BUNDLE_ID="${TOKENBAR_BUNDLE_ID:-com.manuotel.TokenBar}"
OUTPUT="dist/TokenBar.app"

need_value() {
  # $1 = flag name. Caller must have at least the flag + one value left.
  if [ $# -lt 2 ]; then
    echo "Error: missing value for $1." >&2
    exit 2
  fi
  if [ -z "${2:-}" ] || [ "${2#-}" != "$2" ]; then
    echo "Error: missing value for $1 (got '${2:-}')." >&2
    exit 2
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) need_value "$@"; VERSION="$2"; shift 2 ;;
    --build) need_value "$@"; BUILD="$2"; shift 2 ;;
    --bundle-id) need_value "$@"; BUNDLE_ID="$2"; shift 2 ;;
    --output) need_value "$@"; OUTPUT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0 ;;
    *) echo "Error: unknown flag: $1" >&2; exit 2 ;;
  esac
done

case "$VERSION" in
  ""|*[!0-9A-Za-z.\-]*)
    echo "Error: invalid --version '$VERSION' (use digits, letters, dots, dashes)." >&2
    exit 2 ;;
esac

case "$BUILD" in
  ""|*[!0-9A-Za-z.\-]*)
    echo "Error: invalid --build '$BUILD' (use digits, letters, dots, dashes)." >&2
    exit 2 ;;
esac

# Reverse-DNS bundle id, e.g. com.example.TokenBar: dot-separated, each part
# starts with a letter, rest letters/digits/dashes. Validated before it ever
# reaches Info.plist.
valid_bundle_id() {
  case "$1" in
    *[!A-Za-z0-9.-]*|""|.*|*.|*..*) return 1 ;;
  esac
  _old="$IFS"; IFS="."
  # shellcheck disable=SC2162
  set -- $1
  IFS="$_old"
  if [ $# -lt 2 ]; then return 1; fi
  for _part in "$@"; do
    case "$_part" in
      ""|[!A-Za-z]*|*[!A-Za-z0-9-]*) return 1 ;;
    esac
  done
  return 0
}
if ! valid_bundle_id "$BUNDLE_ID"; then
  echo "Error: invalid --bundle-id '$BUNDLE_ID' (expected reverse-DNS like com.example.TokenBar)." >&2
  exit 2
fi

# Guard the destructive removal: never allow empty, root, cwd, or non-.app
# targets so a bad --output cannot wipe the repo or the filesystem.
case "$OUTPUT" in
  ""|/|.|..)
    echo "Error: invalid --output '$OUTPUT'." >&2
    exit 2 ;;
esac
OUTPUT="${OUTPUT%/}"
case "$OUTPUT" in
  ""|/|.|..)
    echo "Error: invalid --output '$OUTPUT'." >&2
    exit 2 ;;
  *.app) ;;
  *)
    echo "Error: invalid --output '$OUTPUT' (expected a path ending in .app)." >&2
    exit 2 ;;
esac

echo "Building TokenBar $VERSION ($BUILD) id=$BUNDLE_ID"
swift build -c release --product TokenBarApp

BIN=".build/release/TokenBarApp"
if [ ! -x "$BIN" ]; then
  echo "Error: expected binary missing at $BIN after swift build." >&2
  exit 1
fi

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources"
cp "$BIN" "$OUTPUT/Contents/MacOS/TokenBar"
chmod +x "$OUTPUT/Contents/MacOS/TokenBar"

cat > "$OUTPUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>TokenBar</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>TokenBar</string>
  <key>CFBundleDisplayName</key><string>TokenBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
</dict>
</plist>
EOF

echo "Built $OUTPUT"
echo "  version: $VERSION ($BUILD)"
echo "  bundle id: $BUNDLE_ID"
echo "  run (unsigned dev check): open $OUTPUT"
echo "Dev alternative (no bundle needed): ./scripts/run-token-bar.sh"
