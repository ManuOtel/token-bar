# Release Checklist (M6)

Docs-only gate for cutting a Token Bar release. No product behavior changes
here; the app stays local-first (file reads only, no accounts, no provider
APIs). The only network uses are strictly opt-in and user-initiated: the
pricing catalog GET and the remote SSH snapshot pull (both disabled by
default). This checklist is the per-release gate; the full ordered
feature-to-release lifecycle lives in `docs/RELEASE_PROCESS.md` (plan
feature, scoped worker branch, review, validation, merge to main,
version/changelog decision, exact tag, published-asset verification,
verified install). Work through top to bottom on a Mac for the build/sign steps;
the Linux mirror covers logic only.

## 1. Data sources and permissions

Current sources (read-only; see README "Data sources"):

| Source | Default location | Test override |
|---|---|---|
| Codex | `~/.codex/sessions/**/*.jsonl` | `TOKENBAR_CODEX_ROOT` |
| OpenCode | `~/.local/share/opencode/opencode.db` | `TOKENBAR_OPENCODE_DB` |
| OpenCode extras | extra read-only DB copies | `TOKENBAR_OPENCODE_DB_EXTRA` |
| OpenCode snapshot | sanitized snapshot files | `TOKENBAR_OPENCODE_USAGE_JSON` |
| OpenCode sync cache | `~/Library/Application Support/TokenBar/opencode-remote.json` (opt-in SSH pull; legacy `opencode-homeserver.json` read as fallback) | `TOKENBAR_OPENCODE_SYNC_CACHE` |
| Claude Code | `~/.claude/projects/**/*.jsonl` | `TOKENBAR_CLAUDE_ROOT` |

Sync config lives in `~/Library/Application Support/TokenBar/opencode-sync.json`
(override `TOKENBAR_OPENCODE_SYNC_CONFIG`; status beside it, override
`TOKENBAR_OPENCODE_SYNC_STATUS`). Ships disabled with blank host/path; the
config stores no password, key, or token.

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
- [ ] Popover contract: `./scripts/test-popover.sh` passes; visual changes
      carry Mac render evidence per `docs/SECURITY_AND_VISUAL_QA.md`
      section 3 (compact/expanded, light/dark, empty/zero/no-comparison,
      notices, accessibility, focus, clipping), built from synthetic
      fixtures with privacy-safe handling (no real-data screenshots, no
      environment dumps).

## 3. Versioned app build

Version source of truth: the `VERSION` file at the repo root (`x.y.z`
only, no prefixes; read it with `VERSION="$(tr -d ' \t\r\n' < VERSION)"`
so docs and commands never hardcode a release number).
`scripts/build-app.sh` defaults to it; `scripts/package-release.sh` falls
back to the built app's `Info.plist`, then to it.

- [ ] Pick the release version per the SemVer policy below and write it to
      `VERSION` (`x.y.z` only, no prefixes). Update `CHANGELOG.md` in the
      same release PR (new version section plus the estimate disclaimer
      on every dollar figure); the release PR touches `VERSION`,
      `CHANGELOG.md`, plus the synchronized public release markers in
      `site/index.html` only, never product or process code, unrelated
      docs, or assets unless the site contract later requires them. The
      site sync is required because `scripts/test-release.sh` runs
      `scripts/test-site.sh`, which enforces VERSION freshness.
- [ ] Every release PR updates `VERSION` and passes a bumped build number
      (`--build` / env `TOKENBAR_BUILD`); never reuse a build number.
      Note the split: a manual `--build` value is for local verification
      only. The published release build number comes from the tag
      workflow, which passes `GITHUB_RUN_NUMBER` as the build
      (`CFBundleVersion`); see `docs/RELEASE_PROCESS.md` step 8 and
      `docs/MACOS_PACKAGING.md`.
- [ ] Build with `./scripts/build-app.sh` (explicit `--version` /
      `TOKENBAR_VERSION` still override the file; optional `--bundle-id` /
      `TOKENBAR_BUNDLE_ID`).
- [ ] Confirm output `dist/TokenBar.app` (git-ignored) with `Info.plist`
      (`LSUIElement=true`, `LSMinimumSystemVersion=14.0`,
      `CFBundleShortVersionString` matching `VERSION`) and the
      `MenuBarExtra` UI. Full path: `docs/MACOS_PACKAGING.md`.
- [ ] Confirm dev loop still needs no bundle: `./scripts/run-token-bar.sh`.
- [ ] Run `./scripts/test-versioning.sh` (default/env/flag precedence,
      no Swift toolchain needed).

### Version policy (SemVer)

- Patch (`x.y.Z`): product fixes, including fixes without user-visible
  behavior change.
- Minor (`x.Y.0`): backward-compatible user-visible features
  (new filters, views, settings, sync behavior, pricing coverage).
- Major (`X.0.0`): breaking changes (storage paths, CLI output shape,
  dropped OS support, removed flags).
- Docs-only and process-only changes do not bump `VERSION` and do not
  create a release. `VERSION` moves only for product changes intended
  for a release per the policy above.
- Docs and examples never hardcode a release number as the default: use
  the bare scripts (they read `VERSION`) or derive it with
  `VERSION="$(tr -d ' \t\r\n' < VERSION)"`. Historical records (for
  example the 0.1.0 evidence log in `RELEASE_EXECUTION_PLAN.md`) stay
  untouched.

## 3b. Merge, tag from main, publish (release PR only)

- [ ] Merge the release PR to `main` only after independent review and
      green PR CI (macOS build+test, Linux verify, privacy gate).
      Feature PRs merge first; the release PR carries the version
      decision last.
- [ ] After merge, verify `main` HEAD (`git fetch origin`, `git log`,
      confirm the release merge is HEAD), then create and push the exact
      tag from `main`: `git tag "v$VERSION"` plus
      `git push origin "v$VERSION"`. Never tag a worker branch or a
      stale HEAD. Full order: `docs/RELEASE_PROCESS.md` steps 7-8.
- [ ] Confirm the tag workflow (`.github/workflows/release.yml`) is green
      for that exact tag. It re-runs `swift build` + `swift test`,
      builds with `VERSION` plus `GITHUB_RUN_NUMBER`, packages zip and
      dmg plus checksums, verifies the DMG layout, and publishes all
      eight assets (versioned plus latest aliases). PR CI stays the full
      pre-tag gate; the tag run is the publish step.
- [ ] Post-publish checks before any install: the GitHub Release holds
      all eight files (`TokenBar-<version>-macos.zip`/`.dmg` plus their
      `.sha256` files plus the `TokenBar-latest-macos.zip`/`.dmg` aliases
      plus their `.sha256` files); the stable latest download URLs
      resolve and their checksums verify with `shasum -a 256 -c`.
      Install only the verified release: stop the previous app first,
      then verify the installed `Info.plist` version and exactly one
      running app (ordered steps in `docs/RELEASE_PROCESS.md` step 9).

## 4. Optional signing and notarization (Developer ID, Mac only, manual)

The automated tag workflow never signs: CI carries no credentials, so
published GitHub Release artifacts are unsigned and not notarized
(Gatekeeper warns on first launch; that is expected). Signing is an
optional manual path on a release Mac with a Developer ID Application
certificate, done before the final package step of a manual build only:

- [ ] `codesign --deep --force --verify --verbose --sign "Developer ID Application: Your Name (TEAMID)" dist/TokenBar.app`,
      then `codesign --verify --deep --strict` and `spctl -a -vvv -t install`.
- [ ] Zip, `xcrun notarytool submit ... --wait`, `xcrun stapler staple`,
      `xcrun stapler validate`, re-check `spctl`.
- [ ] Never commit credentials; `notarytool` uses a local keychain profile.
- [ ] Unsigned local builds keep working for dev and show the expected
      unbundled toggle state (step 6).

## 5. Package checksum / DMG

- [ ] Package *after* signing/stapling so the checksum covers the final
      artifact (manual path): derive the version, never hardcode it:
      `VERSION="$(tr -d ' \t\r\n' < VERSION)"`,
      then `./scripts/package-release.sh --version "$VERSION" --format zip`
      plus `./scripts/package-release.sh --version "$VERSION" --format dmg`
      (macOS only, drag-and-drop layout with the Applications shortcut).
- [ ] Publish each artifact plus its `.sha256`; verify with
      `(cd dist && shasum -a 256 -c "TokenBar-$VERSION-macos.zip.sha256")` and
      `(cd dist && shasum -a 256 -c "TokenBar-$VERSION-macos.dmg.sha256")`,
      then `./scripts/verify-dmg.sh --dmg "dist/TokenBar-$VERSION-macos.dmg"`
      (macOS only). For tag-driven releases this packaging and
      verification runs inside `release.yml`; the manual commands here
      are for local verification and optional signed builds.

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
      except the documented opt-in pricing GET in
      `Sources/TokenBarCore/PricingService.swift` (`URLSession` confined
      there), the documented opt-in SSH pull in
      `Sources/TokenBarCore/OpenCodeSync.swift` (`Process(` confined there;
      no shell, discrete argv, `BatchMode=yes`), the documented
      local-only comment in `Sources/TokenBarCore/Store.swift`
      (usage loading never touches the network), and the documented
      `privacy-denylist` forbidden-field names in
      `Sources/TokenBarCore/OpenCodeStore.swift` (sanitizer denylist only,
      never transmitted).
- [ ] CLI/JSON output contains no absolute paths, prompt text, or message
      bodies (sanitized warnings only; covered by `ReportTests` + smoke).
- [ ] No secrets committed: synthetic fixtures only under `Fixtures/`;
      never real session logs, DBs, or `.env*` (see `.gitignore`).
      Run `./scripts/check-privacy.sh` (tracked files only; also runs in CI).
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
      `--preset lifetime --json` carries `byOrigin` (`source/origin` pairs).
- [ ] Remote workflows: `python3 scripts/export-opencode-usage.py --db
      <copy> --out <snapshot> --origin <label>` emits token-only JSON
      (no prompts/paths/credentials); user-copied snapshot loads via
      `TOKENBAR_OPENCODE_USAGE_JSON` with combined OpenCode total plus
      local/remote split in CLI (`By origin`) and dashboard. With sync
      configured, `Sync Now` / `--sync-now` pulls the same shape over SSH
      (validates before replacing the cache; failures keep the last good
      cache and warn only) with identical combined totals.
- [ ] Dashboard: source/preset filters, totals, breakdowns (OpenCode local
      vs remote sub-lines, combined total kept), trend, empty and
      no-scope states, sanitized warnings, launch-at-login toggle, sync
      status line in Settings (off by default; enabling with a blank host
      is rejected with a short message, never a subprocess).
- [ ] Release-candidate visual smoke per `docs/SECURITY_AND_VISUAL_QA.md`
      section 5: installed build renders compact and expanded popover
      with no bare-material strip, no clipped text, and no overflow;
      record the result with the release evidence (step 9).
- [ ] Missing-data hints point at the `TOKENBAR_*` overrides without
      leaking paths (see README troubleshooting).

## 9. Rollback

- [ ] App rollback: toggle launch at login off, quit from the menu bar,
      delete `/Applications/TokenBar.app`. The app writes no data files,
      so nothing else needs cleaning; cached login-item state clears on
      unregister. To fully disconnect sync, turn the toggle off in
      Settings (in-flight pulls cancel) and optionally delete
      `~/Library/Application Support/TokenBar/opencode-remote.json` (plus
      legacy `opencode-homeserver.json` if present from an older version).
- [ ] Release rollback: re-tag/re-publish the previous versioned artifact
      + checksum; note that a bundle-id change resets the login item
      (toggle off/on once). Never silently overwrite a published asset.
- [ ] Record the release evidence (release PR number, tagged `main` HEAD
      SHA, tag name, green tag workflow run, asset/URL check results,
      installed version verification) in the release PR or issue thread.

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
