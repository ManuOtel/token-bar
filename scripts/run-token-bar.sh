#!/bin/sh
# One-command menu bar launcher (macOS 14+).
#
# Usage:
#   ./scripts/run-token-bar.sh
#
# Builds (if needed) and runs the TokenBarApp menu bar extra.
# Keeps the app alive in the menu bar; stop with Ctrl-C.
set -eu
cd "$(dirname "$0")/.."
exec swift run TokenBarApp
