#!/usr/bin/env bash
# check-privacy.sh - public-repository privacy guard for Token Bar.
#
# Scans TRACKED files only (git ls-files) so ignored local histories,
# databases, snapshots, and server credentials are never read. Content scans
# cover every tracked file INCLUDING this script: sensitive match text is
# assembled at runtime from split fragments (below), so the implementation
# literals never self-match. Any hit exits nonzero: fail-closed, no silent
# skips. Fails on:
#   1. personal account identifiers (explicit per-line allowlist only)
#   2. absolute personal paths (non-synthetic user/home dirs)
#   3. credential / private-key / token patterns
#   4. real usage artifacts accidentally tracked (filename check, full list)
#   5. personal machine output (hostnames, run URLs with ids)
#
# Well-known synthetic test markers and neutral placeholders never fail;
# they prove sanitizers strip such values. Residual boundary: this guard
# cannot judge arbitrary prompt prose or recognize every provider token
# format, so human review plus the sanitizer tests remain required.
#
# Run locally: ./scripts/check-privacy.sh (from the repo root).
# Runs in CI as part of the privacy-gate job.
set -eu

# Deterministic byte-wise matching everywhere (ranges like [A-Z] behave
# identically under any developer locale).
export LC_ALL=C

cd "$(dirname "$0")/.."

# --- Split fragments -------------------------------------------------------
# Every sensitive literal is split across two shell literals so the source
# holds no contiguous match text and the guard stays green on itself. The
# real patterns are assembled at runtime (see *_pat variables below).
_A1='manuo'; _A2='tel'
_E1='eman'; _E2='uel'
_O1='ot'; _O2='el'
_US1='/Us'; _US2='ers/'
_HM1='/ho'; _HM2='me/'
_BK1='PRIVA'; _BK2='TE KEY'
_BG1='BEG'; _BG2='IN'
_AK1='AK'; _AK2='IA'
_GH1='gh'; _GH_P='p_'; _GH_O='o_'
_GP1='gith'; _GP2='ub_pat_'
_GL1='glp'; _GL2='at-'
_XO1='xo'; _XO2='x'
_AZ1='AI'; _AZ2='za'
_SKP1='sk-p'; _SKP2='roj-'
_SKA1='sk-a'; _SKA2='nt-'
_SKO1='sk-or-v'; _SKO2='1-'
_BE1='ear'; _BE2='er'
_AR1='actions/ru'; _AR2='ns/'

ACCT="${_A1}${_A2}"
EMAN="${_E1}${_E2}"
OTEL="${_O1}${_O2}"
USP="${_US1}${_US2}"
HMP="${_HM1}${_HM2}"

fail=0
note() { printf '%s\n' "$*"; }
fail_hit() { fail=1; printf 'PRIVACY FAIL: %s\n' "$*"; }

tracked="$(git ls-files)"
if [ -z "$tracked" ]; then
  echo "PRIVACY FAIL: no tracked files found (run inside the repo)."
  exit 1
fi

# 1. Personal account identifiers.
# Allowlist (exact, documented): the project badge/link URL forms, the
# legal attribution line, and the shipped bundle identifier in its build
# script and test mirrors. Anything else fails.
personal_pat="${ACCT}|${EMAN}[^ ]* ${OTEL}|${OTEL}[^ ]*${EMAN}"
personal_hits="$(echo "$tracked" | xargs grep -nEi "$personal_pat" 2>/dev/null || true)"
if [ -n "$personal_hits" ]; then
  while IFS= read -r line; do
    case "$line" in
      *scripts/build-app.sh*TokenBar*|*LaunchAtLoginTests.swift*TokenBar*|*scripts/verify_logic.py*TokenBar*)
        continue ;;
    esac
    if printf '%s' "$line" | grep -qiF "github.com/${ACCT}/token-bar" \
      || printf '%s' "$line" | grep -qiF "git@github.com:${ACCT}/token-bar"; then
      continue
    fi
    case "$line" in
      *LICENSE*)
        if printf '%s' "$line" | grep -qiE "${EMAN}[^ ]* ${OTEL}|${OTEL}[^ ]*${EMAN}"; then
          continue
        fi
        ;;
    esac
    fail_hit "$line"
  done <<EOF
$personal_hits
EOF
fi

# 2. Absolute personal paths.
# Well-known synthetic user markers and standard CI runner homes stay
# allowed. Anything else under a user or home dir fails.
path_pat="${USP}[^ /\"':,]+|${HMP}[^ /\"':,]+"
path_hits="$(echo "$tracked" | xargs grep -nE "$path_pat" 2>/dev/null || true)"
if [ -n "$path_hits" ]; then
  while IFS= read -r line; do
    case "$line" in
      *"${USP}someone"*|*"${USP}private"*|*"${USP}x/"*|*"${USP}x\""*|*"${USP}x."*|*"${USP}x:"*|*"${USP}example"*|*"${USP}test"*|*"${USP}fake"*|*"${USP}shared"*|*"${USP}runner"*|*"${HMP}test"*|*"${HMP}example"*|*"${HMP}runner"*) continue ;;
      *) fail_hit "$line" ;;
    esac
  done <<EOF
$path_hits
EOF
fi

# 3. Credential / private-key / token patterns (high precision only;
# prose like "no password" or "stores no password" never matches).
cred_pat="-----${_BG1}${_BG2} (RSA |OPENSSH |EC |DSA |PGP |ENCRYPTED )?${_BK1}${_BK2}|${_AK1}${_AK2}[0-9A-Z]{16}|${_GH1}${_GH_P}[A-Za-z0-9]{20,}|${_GH1}${_GH_O}[A-Za-z0-9]{20,}|${_GP1}${_GP2}[A-Za-z0-9_]{20,}|${_GL1}${_GL2}[A-Za-z0-9_-]{15,}|${_SKP1}${_SKP2}[A-Za-z0-9_-]{20,}|${_SKA1}${_SKA2}[A-Za-z0-9_-]{20,}|${_SKO1}${_SKO2}[A-Za-z0-9_-]{10,}|sk-(live|test)-[A-Za-z0-9]{10,}|sk-[A-Za-z0-9_-]{20,}|${_XO1}${_XO2}[bpas]-[A-Za-z0-9-]{10,}|${_AZ1}${_AZ2}[0-9A-Za-z_-]{20,}|(api[_-]?key|api[_-]?secret|access[_-]?token)[[:space:]]*[:=][[:space:]]*['\"]?[A-Za-z0-9_.-]{16,}['\"]?|(B|b)${_BE1}${_BE2}[[:space:]]+[A-Za-z0-9_~.-]{20,}"
cred_hits="$(echo "$tracked" | xargs grep -nE -- "$cred_pat" 2>/dev/null || true)"
if [ -n "$cred_hits" ]; then
  fail_hit "credential/private-key/token pattern found:"
  printf '%s\n' "$cred_hits"
fi

# 4. Real usage artifacts must never be tracked (synthetic Fixtures/ only).
# Filename check over the full tracked list, including SQLite sidecars and
# key variants.
artifact_hits="$(echo "$tracked" | grep -E '(^|/)\.env(\.|$)|(^|/)\.env\..*|.*\.pem$|.*\.key$|id_rsa(\.pub|([^.]|$))|id_ecdsa(\.pub|([^.]|$))|id_dsa(\.pub|([^.]|$))|id_ed25519(\.pub|([^.]|$))|opencode\.db$|opencode\.db-(wal|shm|journal)$|[^/]*\.sqlite3?$|startup-report\.json$|\.jsonl$|(^|/)\.codex/|(^|/)sessions/' | grep -v '^Fixtures/' || true)"
if [ -n "$artifact_hits" ]; then
  fail_hit "real usage/secret artifact tracked (only synthetic Fixtures/ may ship):"
  printf '%s\n' "$artifact_hits"
fi

# 5. Personal machine output: hostnames, account-qualified prompts, run URLs.
machine_pat="Linux ${ACCT}|${ACCT}@|${HMP}${ACCT}|${USP}${ACCT}|${_AR1}${_AR2}[0-9]+"
machine_hits="$(echo "$tracked" | xargs grep -nE "$machine_pat" 2>/dev/null || true)"
if [ -n "$machine_hits" ]; then
  # The project badge link (actions/workflows, no run id) cannot match the
  # run-id branch above, so no allowlist is needed here.
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
