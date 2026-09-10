#!/bin/sh
# Package a built TokenBar.app into a versioned zip (default) or DMG.
#
# Usage:
#   ./scripts/package-release.sh [--version 0.1.0] [--format zip|dmg]
#                                [--app dist/TokenBar.app] [--outdir dist]
#
# Env overrides: TOKENBAR_VERSION, TOKENBAR_FORMAT, TOKENBAR_APP.
# Requires ./scripts/build-app.sh to have run first. No signing or
# notarization here (see docs/MACOS_PACKAGING.md): sign + staple the .app
# first, then package, then publish the .sha256 checksum beside the artifact.
set -eu
cd "$(dirname "$0")/.."

VERSION="${TOKENBAR_VERSION:-0.1.0}"
FORMAT="${TOKENBAR_FORMAT:-zip}"
APP="${TOKENBAR_APP:-dist/TokenBar.app}"
OUTDIR="dist"

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    --app) APP="$2"; shift 2 ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,10p' "$0"
      exit 0 ;;
    *) echo "Error: unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [ ! -d "$APP" ]; then
  echo "Error: app bundle missing at $APP. Run ./scripts/build-app.sh first." >&2
  exit 1
fi

# Prefer the bundled version when the caller did not override it.
if [ -f "$APP/Contents/Info.plist" ] && [ "${TOKENBAR_VERSION:-}" = "" ]; then
  PLIST_VERSION="$(/usr/bin/defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
  if [ -n "$PLIST_VERSION" ]; then
    VERSION="$PLIST_VERSION"
  fi
fi

mkdir -p "$OUTDIR"

checksum_file() {
  # $1 = artifact path. Writes $1.sha256 and prints verify hint.
  if command -v shasum >/dev/null 2>&1; then
    (cd "$(dirname "$1")" && shasum -a 256 "$(basename "$1")" > "$(basename "$1").sha256")
  elif command -v sha256sum >/dev/null 2>&1; then
    (cd "$(dirname "$1")" && sha256sum "$(basename "$1")" > "$(basename "$1").sha256")
  else
    echo "Warning: no shasum/sha256sum found; skipping checksum." >&2
    return 0
  fi
  echo "Checksum: $1.sha256"
  echo "Verify with: (cd $OUTDIR && shasum -a 256 -c $(basename "$1").sha256)"
}

case "$FORMAT" in
  zip)
    ARTIFACT="$OUTDIR/TokenBar-$VERSION-macos.zip"
    rm -f "$ARTIFACT"
    if command -v ditto >/dev/null 2>&1; then
      ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARTIFACT"
    elif command -v zip >/dev/null 2>&1; then
      rm -f "$ARTIFACT"
      (cd "$(dirname "$APP")" && zip -qry "$PWD/$ARTIFACT" "$(basename "$APP")")
    else
      echo "Error: neither ditto nor zip is available." >&2
      exit 1
    fi
    echo "Packaged $ARTIFACT"
    echo "Install: unzip, drag TokenBar.app to Applications, then open."
    checksum_file "$ARTIFACT"
    ;;
  dmg)
    if ! command -v hdiutil >/dev/null 2>&1; then
      echo "Error: hdiutil not found (DMG needs macOS). Use --format zip instead." >&2
      exit 1
    fi
    ARTIFACT="$OUTDIR/TokenBar-$VERSION-macos.dmg"
    rm -f "$ARTIFACT"
    hdiutil create -volname "TokenBar $VERSION" -srcfolder "$APP" -ov -format UDZO "$ARTIFACT"
    echo "Packaged $ARTIFACT"
    echo "Install: open the DMG, drag TokenBar.app to Applications, then open."
    checksum_file "$ARTIFACT"
    ;;
  *)
    echo "Error: invalid --format '$FORMAT'. Expected zip or dmg." >&2
    exit 2 ;;
esac
