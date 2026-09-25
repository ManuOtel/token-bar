#!/bin/sh
# Generate the macOS app icon from the canonical Token Bar SVG logo.
#
# Usage: ./scripts/generate-app-icon.sh [output.icns]
# Requires macOS Quick Look, sips, and iconutil. The source SVG remains the
# single logo definition; this script only creates the packaged raster sizes.
set -eu
cd "$(dirname "$0")/.."

SOURCE="site/assets/tokenbar-logo.svg"
OUTPUT="${1:-dist/TokenBar.app/Contents/Resources/TokenBar.icns}"

case "$OUTPUT" in
  ""|-|/|.|..|-*|*.app|*.app/|*.icns/)
    echo "Error: invalid icon output '$OUTPUT'. Expected a .icns file." >&2
    exit 2
    ;;
  *.icns)
    ;;
  *)
    echo "Error: invalid icon output '$OUTPUT'. Expected a .icns file." >&2
    exit 2
    ;;
esac

if [ ! -f "$SOURCE" ]; then
  echo "Error: canonical logo missing at $SOURCE." >&2
  exit 1
fi

for tool in qlmanage sips iconutil; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: $tool is required to generate TokenBar.icns on macOS." >&2
    exit 1
  fi
done

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

ICONSET="$TMP/TokenBar.iconset"
mkdir -p "$ICONSET" "$(dirname "$OUTPUT")"

# Quick Look rasterizes the code-native SVG without adding a graphics
# dependency or a second hand-maintained logo asset to the repository.
qlmanage -t -s 1024 -o "$TMP" "$SOURCE" >/dev/null 2>&1
RENDERED="$TMP/$(basename "$SOURCE").png"
if [ ! -f "$RENDERED" ]; then
  echo "Error: Quick Look did not render $SOURCE." >&2
  exit 1
fi

make_icon() {
  size="$1"
  name="$2"
  sips -z "$size" "$size" "$RENDERED" --out "$ICONSET/$name" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "Generated $OUTPUT from $SOURCE"
