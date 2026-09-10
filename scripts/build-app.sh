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

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
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
