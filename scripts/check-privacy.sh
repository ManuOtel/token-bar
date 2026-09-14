#!/usr/bin/env bash
# check-privacy.sh - public-repository privacy guard for Token Bar.
#
# Scans TRACKED files only (git ls-files) so ignored local histories,
# databases, snapshots, and SSH config are never read. Content scans cover
# every tracked file EXCEPT this guard script itself: its own pattern and
# allowlist literals would otherwise self-match. That exclusion is a single
# fixed path (not a file class), and the filename check in step 4 still
# covers the full tracked list, so the guard stays fail-closed. Fails on:
#   1. personal account/host identifiers (except explicit allowlist below)
#   2. absolute personal paths (non-synthetic /Users/... and /home/...)
#   3. credential / private-key / token patterns
#   4. real usage artifacts accidentally tracked (DBs, live snapshots, keys)
#   5. personal machine output (hostnames, run URLs with account names)
#
# Synthetic privacy-test strings (/Users/someone, /tmp/secret-host,
# SECRET-PROMPT-XYZ, ...) intentionally do NOT fail: they prove sanitizers
# strip such values. Generic placeholders (user@server.example,
# /path/to/..., com.example....) never fail.
#
# Run locally: ./scripts/check-privacy.sh (from the repo root).
# Runs in CI as part of the privacy-gate job.
set -eu

cd "$(dirname "$0")/.."

fail=0
note() { printf '%s\n' "$*"; }
fail_hit() { fail=1; printf 'PRIVACY FAIL: %s\n' "$*"; }

tracked="$(git ls-files)"
if [ -z "$tracked" ]; then
  echo "PRIVACY FAIL: no tracked files found (run inside the repo)."
  exit 1
fi

# Self-exclusion for content matching (see header): the literals below are
# the patterns themselves. Fixed single path; everything else is scanned.
self="scripts/check-privacy.sh"
content_files="$(echo "$tracked" | grep -vx "$self" || true)"
if [ -z "$content_files" ]; then
  echo "PRIVACY FAIL: no scannable tracked files found."
  exit 1
fi

# 1. Personal account/host identifiers.
# Allowlist: the project badge/link (github.com/ManuOtel/token-bar),
# legal attribution (LICENSE copyright holder), and the shipped bundle-id
# default (com.manuotel.TokenBar in scripts/build-app.sh + its test mirrors).
# Everything else mentioning the personal account fails.
personal_hits="$(echo "$content_files" | xargs grep -nEi 'manuotel|emanuel[^ ]* otel|otel[^ ]*emanuel' 2>/dev/null || true)"
if [ -n "$personal_hits" ]; then
  while IFS= read -r line; do
    case "$line" in
      *github.com/ManuOtel/token-bar*) continue ;;
      *LICENSE*Emanuel*Otel*) continue ;;
      *LICENSE:*Otel*) continue ;;
      *scripts/build-app.sh*com.manuotel.TokenBar*) continue ;;
      *Tests/TokenBarCoreTests/LaunchAtLoginTests.swift*com.manuotel.TokenBar*) continue ;;
      *scripts/verify_logic.py*com.manuotel.TokenBar*) continue ;;
      *) fail_hit "$line" ;;
    esac
  done <<EOF
$personal_hits
EOF
fi

# 2. Absolute personal paths.
# Synthetic test markers stay allowed: someone, private, x, example, test,
# fake, shared. Anything else under /Users/ or /home/ fails.
path_hits="$(echo "$content_files" | xargs grep -nE '/Users/[^ /"'"'"':,]+|/home/[^ /"'"'"':,]+' 2>/dev/null || true)"
if [ -n "$path_hits" ]; then
  while IFS= read -r line; do
    case "$line" in
      */Users/someone*|*/Users/private*|*/Users/x/*|*/Users/x\"*|*/Users/x.*|*/Users/x:*|*/Users/example*|*/Users/test*|*/Users/fake*|*/Users/shared*) continue ;;
      */home/test*|*/home/example*) continue ;;
      *) fail_hit "$line" ;;
    esac
  done <<EOF
$path_hits
EOF
fi

# 3. Credential / private-key / token patterns (high precision only;
# prose like "no password" or "stores no password" never matches).
cred_hits="$(echo "$content_files" | xargs grep -nE -- '-----BEGIN (RSA |OPENSSH |EC |DSA |PGP )?PRIVATE KEY|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{15,}|sk-(live|test)-[A-Za-z0-9]{10,}|xox[bpas]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{20,}' 2>/dev/null || true)"
if [ -n "$cred_hits" ]; then
  fail_hit "credential/private-key/token pattern found:"
  printf '%s\n' "$cred_hits"
fi

# 4. Real usage artifacts must never be tracked (synthetic Fixtures/ only).
# Filename check over the FULL tracked list (this script's own name matches
# nothing here, so no exclusion needed).
artifact_hits="$(echo "$tracked" | grep -E '(^|/)\.env(\.|$)|(^|/)\.env\.|.*\.pem$|.*\.key$|(^|/)id_rsa([^.]|$)|(console|/|\.)id_ed25519|(^|/)opencode\.db$|(^|/)opencode-remote\.json$|(^|/)opencode-homeserver\.json$|(^|/)opencode-sync\.json$|(^|/)opencode-sync-status\.json$|(^|/)\.codex/|(^|/)sessions/' | grep -v '^Fixtures/' || true)"
if [ -n "$artifact_hits" ]; then
  fail_hit "real usage/secret artifact tracked (only synthetic Fixtures/ may ship):"
  printf '%s\n' "$artifact_hits"
fi

# 5. Personal machine output: hostnames, account-qualified run URLs, prompts.
machine_hits="$(echo "$content_files" | xargs grep -nE 'Linux manuotel|manuotel@|/home/manuotel|/Users/manuotel|actions/runs/[0-9]+' 2>/dev/null || true)"
if [ -n "$machine_hits" ]; then
  # Allow the README badge link (actions/workflows, no run id) implicitly:
  # it contains no run id so it cannot match the pattern above.
  fail_hit "personal machine output found:"
  printf '%s\n' "$machine_hits"
fi

if [ "$fail" -ne 0 ]; then
  note "Privacy guard failed. Fix the lines above (generalize to neutral"
  note "placeholders like user@server.example and /path/to/opencode.db),"
  note "then re-run ./scripts/check-privacy.sh."
  exit 1
fi
echo "Privacy guard passed: tracked files contain no personal paths, account identifiers, credentials, or real usage artifacts."
