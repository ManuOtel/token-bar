#!/bin/sh
# check-release-sdk.sh - enforce the macOS SDK floor for release builds.
#
# The release binary must be compiled with macOS SDK 26 or newer so the
# conditional Liquid Glass branch is present; the deployment target stays
# macOS 14. The check accepts any SDK major >= 26 (26.x, 27.x, ...) so a
# newer Xcode never breaks the release, and rejects 25.x and older.
#
# Usage: ./scripts/check-release-sdk.sh [version]
#   With an argument, that version string is checked (test seam for
#   scripts/test-release.sh). With no argument, the installed toolchain is
#   queried with: xcrun --sdk macosx --show-sdk-version.
# Exits 0 when the SDK major is >= 26, 1 otherwise.
#
# Run: ./scripts/check-release-sdk.sh 26.2
set -eu

if [ "${1:-}" != "" ]; then
  SDK_VERSION="$1"
else
  SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
fi
echo "macOS SDK: $SDK_VERSION"
MAJOR="${SDK_VERSION%%.*}"
case "$MAJOR" in
  ""|*[!0-9]*)
    echo "Release failed: cannot parse macOS SDK major from '$SDK_VERSION' (macOS SDK 26 or newer required for Liquid Glass)."
    exit 1 ;;
esac
if [ "$MAJOR" -ge 26 ]; then
  echo "Release SDK check passed: macOS SDK $SDK_VERSION meets the SDK 26 floor."
else
  echo "Release failed: macOS SDK 26 or newer required to compile Liquid Glass (got $SDK_VERSION)."
  exit 1
fi
