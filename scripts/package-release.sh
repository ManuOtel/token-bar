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

# Precedence: explicit --version flag wins, then TOKENBAR_VERSION env,
# then the built app's Info.plist, then the 0.1.0 default. This keeps the
# artifact name consistent with what the caller asked for.
VERSION="${TOKENBAR_VERSION:-}"
VERSION_FROM_FLAG=0
FORMAT="${TOKENBAR_FORMAT:-zip}"
APP="${TOKENBAR_APP:-dist/TokenBar.app}"
OUTDIR="dist"

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
    --version) need_value "$@"; VERSION="$2"; VERSION_FROM_FLAG=1; shift 2 ;;
    --format) need_value "$@"; FORMAT="$2"; shift 2 ;;
    --app) need_value "$@"; APP="$2"; shift 2 ;;
    --outdir) need_value "$@"; OUTDIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,10p' "$0"
      exit 0 ;;
    *) echo "Error: unknown flag: $1" >&2; exit 2 ;;
  esac
done

case "$OUTDIR" in
  ""|/|.|..)
    echo "Error: invalid --outdir '$OUTDIR'." >&2
    exit 2 ;;
esac

# Fail fast on an explicit bad version before touching the filesystem, so
# the caller sees the real problem even when the app bundle is also missing.
if [ -n "$VERSION" ]; then
  case "$VERSION" in
    *[!0-9A-Za-z.\-]*)
      echo "Error: invalid --version '$VERSION' (use digits, letters, dots, dashes)." >&2
      exit 2 ;;
  esac
fi

if [ ! -d "$APP" ]; then
  echo "Error: app bundle missing at $APP. Run ./scripts/build-app.sh first." >&2
  exit 1
fi

# Fall back to the bundled version only when the caller did not ask for one
# via flag or env, so an explicit --version always names the artifact.
# `defaults` exists on macOS only; elsewhere the default below applies.
if [ "$VERSION_FROM_FLAG" -eq 0 ] && [ -z "$VERSION" ] && [ -f "$APP/Contents/Info.plist" ] \
    && command -v defaults >/dev/null 2>&1; then
  case "$APP" in
    /*) INFO_PATH="$APP/Contents/Info" ;;
    *) INFO_PATH="$PWD/$APP/Contents/Info" ;;
  esac
  PLIST_VERSION="$(defaults read "$INFO_PATH" CFBundleShortVersionString 2>/dev/null || true)"
  if [ -n "$PLIST_VERSION" ]; then
    VERSION="$PLIST_VERSION"
  fi
fi
if [ -z "$VERSION" ]; then
  VERSION="0.1.0"
fi
case "$VERSION" in
  *[!0-9A-Za-z.\-]*)
    echo "Error: invalid --version '$VERSION' (use digits, letters, dots, dashes)." >&2
    exit 2 ;;
esac

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
      case "$ARTIFACT" in
        /*) ZIP_TARGET="$ARTIFACT" ;;
        *) ZIP_TARGET="$PWD/$ARTIFACT" ;;
      esac
      (cd "$(dirname "$APP")" && zip -qry "$ZIP_TARGET" "$(basename "$APP")")
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
