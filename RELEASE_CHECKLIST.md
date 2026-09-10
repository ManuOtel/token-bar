# Release Checklist (M6)

Docs-only gate for cutting a Token Bar release. No product behavior changes
here; the app stays local-only (file reads only, no accounts, no network,
no auth). Work through top to bottom on a Mac for the build/sign steps;
the Linux mirror covers logic only.

## 1. Data sources and permissions

Current sources (read-only; see README "Data sources"):

| Source | Default location | Test override |
|---|---|---|
| Codex | `~/.codex/sessions/**/*.jsonl` | `TOKENBAR_CODEX_ROOT` |
| OpenCode | `~/.local/share/opencode/opencode.db` | `TOKENBAR_OPENCODE_DB` |
| Claude Code | `~/.claude/projects/**/*.jsonl` | `TOKENBAR_CLAUDE_ROOT` |

- [ ] Confirm adapters open files read-only and missing roots/tables degrade
      to empty + sanitized warning (never a crash, never a raw path).
- [ ] Confirm test overrides above still redirect all adapters.
- [ ] Confirm no new filesystem entitlements beyond read-only history
      plus the login item (see `docs/MACOS_PACKAGING.md`).

## 2. Local, mirror, and CI checks

- [ ] Mac (source of truth): `swift build` green, `swift test` green
      (Xcode 15+, macOS 14 SDK).
- [ ] Linux mirror: `PYTHONDONTWRITEBYTECODE=1 python3 -B scripts/verify_logic.py`
      passes (same semantics, no Swift required).
- [ ] Shell syntax: `bash -n` / `sh -n` clean on `scripts/*.sh`
      (CI also asserts the scripts are executable).
- [ ] CI green on the release PR: macOS build+test job, Linux verify job,
      privacy-gate job (`.github/workflows/ci.yml`).

## 3. Versioned app build

- [ ] Bump the version (`./scripts/build-app.sh --version <x.y.z>`,
      optional `--build` / `--bundle-id`; env equivalents
      `TOKENBAR_VERSION`, `TOKENBAR_BUILD`, `TOKENBAR_BUNDLE_ID`).
- [ ] Confirm output `dist/TokenBar.app` (git-ignored) with `Info.plist`
      (`LSUIElement=true`, `LSMinimumSystemVersion=14.0`) and the
      `MenuBarExtra` UI. Full path: `docs/MACOS_PACKAGING.md`.
- [ ] Confirm dev loop still needs no bundle: `./scripts/run-token-bar.sh`.

## 4. Optional signing and notarization (Developer ID, Mac only, manual)

CI never signs (no credentials). Only on a release Mac with a
Developer ID Application certificate:

- [ ] `codesign --deep --force --verify --verbose --sign "Developer ID Application: Your Name (TEAMID)" dist/TokenBar.app`,
      then `codesign --verify --deep --strict` and `spctl -a -vvv -t install`.
- [ ] Zip, `xcrun notarytool submit ... --wait`, `xcrun stapler staple`,
      `xcrun stapler validate`, re-check `spctl`.
- [ ] Never commit credentials; `notarytool` uses a local keychain profile.
- [ ] Unsigned local builds keep working for dev and show the expected
      unbundled toggle state (step 6).

## 5. Package checksum / DMG

- [ ] Package *after* signing/stapling so the checksum covers the final
      artifact: `./scripts/package-release.sh --version <x.y.z> --format zip`
      (DMG via `--format dmg`, macOS only).
- [ ] Publish the artifact plus its `.sha256`; verify with
      `(cd dist && shasum -a 256 -c TokenBar-<x.y.z>-macos.zip.sha256)`.

## 6. Launch-at-login validation

- [ ] Bundled app in `/Applications`: toggle registers/unregisters
      `SMAppService.mainApp`; state also visible under System Settings,
      Login Items. No helper tool, no extra entitlements.
- [ ] Unbundled (`swift run`): toggle stays disabled with dev-run copy;
      no system call attempted.
- [ ] Unsigned/ad-hoc bundles may be refused by the system; toggle stays
      off with a sanitized error and the app keeps working.

## 7. Privacy and credential scan

- [ ] `grep -rniE 'URLSession|http|cookie' Sources/` returns nothing
      except the documented local-only comment in
      `Sources/TokenBarCore/Store.swift` (`No auth, no cookies, no network`).
- [ ] CLI/JSON output contains no absolute paths, prompt text, or message
      bodies (sanitized warnings only; covered by `ReportTests` + smoke).
- [ ] No secrets committed: synthetic fixtures only under `Fixtures/`;
      never real session logs, DBs, or `.env*` (see `.gitignore`).
- [ ] Release notes carry the estimate disclaimer: every dollar figure is
      labelled `Estimated cost ... (estimate only; static table, not a bill;
      subscription use is not an API invoice)`. Static table drifts from
      provider price lists; subscription use is not an API invoice.

## 8. User smoke test

- [ ] `./scripts/show-usage.sh --preset lifetime --source all` prints totals,
      source splits, top models, estimated cost, last updated, sanitized
      warnings only.
- [ ] `./scripts/show-usage.sh --all-presets`, each `--preset`
      (`today|24h|7d|30d|best-month|lifetime`), each `--source`
      (`all|codex|opencode|claude`), and `--preset lifetime --json` all work.
- [ ] Dashboard: source/preset filters, totals, breakdowns, trend, empty and
      no-scope states, sanitized warnings, launch-at-login toggle.
- [ ] Missing-data hints point at the `TOKENBAR_*` overrides without
      leaking paths (see README troubleshooting).

## 9. Rollback

- [ ] App rollback: toggle launch at login off, quit from the menu bar,
      delete `/Applications/TokenBar.app`. The app writes no data files,
      so nothing else needs cleaning; cached login-item state clears on
      unregister.
- [ ] Release rollback: re-tag/re-publish the previous versioned artifact
      + checksum; note that a bundle-id change resets the login item
      (toggle off/on once).

## 10. Future sources (tracked, not built)

Per `PLAN.md` M6, additional coding agents (for example Gemini CLI,
Copilot, Cursor, other JSONL/SQLite histories) are follow-up work, not
part of this release. Do not invent integrations here. Each candidate
needs its own issue and, before merge, all of:

- Default local path (+ test override env var) and record shape observed
  on a Mac (generic default only, synthetic fixtures under `Fixtures/`).
- Token-field map, cache semantics (fold-in vs already-included),
  `total` rule, and dedupe key (`source:requestId`, earliest wins).
- Privacy review: read-only access, sanitized warnings, no paths, prompts,
  message bodies, credentials, or network calls.
- Parser + aggregator tests, `verify_logic.py` mirror, README source table,
  troubleshooting, and semantics updates.
