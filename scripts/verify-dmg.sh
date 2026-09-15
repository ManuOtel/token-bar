#!/bin/sh
# verify-dmg.sh - runtime check for the TokenBar drag-and-drop DMG layout.
#
# Asserts the DMG contains TokenBar.app plus an Applications symlink
# pointing to /Applications. Mounts read-only with hdiutil on macOS,
# then always detaches and cleans up (trap on EXIT).
#
# Usage:
#   ./scripts/verify-dmg.sh --dmg dist/TokenBar-0.3.2-macos.dmg
#
# Fails clearly off macOS when hdiutil is unavailable. No signing,
# no network, no credentials, no usage data.
set -eu
cd "$(dirname "$0")/.."

DMG=""

need_value() {
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
    --dmg) need_value "$@"; DMG="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0 ;;
    *) echo "Error: unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$DMG" ]; then
  echo "Error: missing --dmg <path>." >&2
  exit 2
fi
if [ ! -f "$DMG" ]; then
  echo "Error: DMG missing at $DMG. Run ./scripts/package-release.sh --format dmg first." >&2
  exit 1
fi
if ! command -v hdiutil >/dev/null 2>&1; then
  echo "Error: hdiutil not found (DMG verification needs macOS)." >&2
  exit 1
fi

MNT="$(mktemp -d)"
cleanup() {
  if [ -n "${MNT:-}" ] && [ -d "$MNT" ]; then
    hdiutil detach "$MNT" -force >/dev/null 2>&1 || true
    rmdir "$MNT" 2>/dev/null || true
  fi
}
trap cleanup EXIT

hdiutil attach -readonly -nobrowse -mountpoint "$MNT" "$DMG" >/dev/null

fail=0
if [ -d "$MNT/TokenBar.app" ]; then
  echo "Found TokenBar.app in $DMG"
else
  echo "Error: TokenBar.app missing inside $DMG." >&2
  fail=1
fi
if [ -L "$MNT/Applications" ]; then
  TARGET="$(readlink "$MNT/Applications" || true)"
  if [ "$TARGET" = "/Applications" ]; then
    echo "Found Applications symlink -> /Applications in $DMG"
  else
    echo "Error: Applications symlink points to '$TARGET', expected '/Applications'." >&2
    fail=1
  fi
else
  echo "Error: Applications symlink missing inside $DMG." >&2
  fail=1
fi

trap - EXIT
cleanup

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "DMG verified: $DMG (TokenBar.app + Applications symlink present)"
