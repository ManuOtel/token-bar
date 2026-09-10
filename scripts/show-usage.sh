#!/bin/sh
# One-command terminal usage report (no menu bar, no private data).
#
# Usage:
#   ./scripts/show-usage.sh [--preset today|24h|7d|30d|best-month|lifetime]
#                           [--source all|codex|opencode] [--all-presets] [--json]
#
# Examples:
#   ./scripts/show-usage.sh
#   ./scripts/show-usage.sh --preset today
#   ./scripts/show-usage.sh --preset 7d --source codex
#   ./scripts/show-usage.sh --all-presets
#   ./scripts/show-usage.sh --preset lifetime --json
#
# Env overrides (testing only):
#   TOKENBAR_CODEX_ROOT=/tmp/fake-codex ./scripts/show-usage.sh
#   TOKENBAR_OPENCODE_DB=/tmp/fake.db ./scripts/show-usage.sh
set -eu
cd "$(dirname "$0")/.."
exec swift run TokenBarCLI "$@"
