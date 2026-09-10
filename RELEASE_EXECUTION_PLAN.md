# Release Execution Plan - Token Bar

Base: `origin/main` at merged head `323ee30` (PR #9, feat/release-readiness).
Branch: `feat/release-execution`.
Scope: execute `RELEASE_CHECKLIST.md` (M6 gate) using existing scripts/docs only.
No product behavior changes. No network integration. No provider credentials.
Local-only app (file reads only, no accounts, no network, no auth).

## Task 1 - Clean checkout at 323ee30

Steps:
- `git fetch origin main`
- `git rev-parse origin/main` equals `323ee30d0abb58aae759178d94d20f6bcccde03f`
- Work on branch `feat/release-execution` from that head.
- `git status --short` clean before edits (except new plan file).

Acceptance evidence:
- Pasted `git rev-parse HEAD` + `git status --short` output in status log.

## Task 2 - Full tests (Mac truth + Linux mirror + shell syntax + CI)

Steps (per README / RELEASE_CHECKLIST 2 / CI):
- Mac source of truth: `swift build` green, `swift test` green (Xcode 15+, macOS 14 SDK).
- Linux mirror (this host): `PYTHONDONTWRITEBYTECODE=1 python3 -B scripts/verify_logic.py` passes.
- Shell syntax: `bash -n` / `sh -n` clean on `scripts/*.sh`, plus executable-bit check (mirrors CI).
- CI green on release PR: macOS build+test job, Linux verify job, privacy-gate job (`.github/workflows/ci.yml`).

Acceptance evidence:
- Full `verify_logic.py` tail output, shell-check outputs, `swift build` / `swift test` output when on Mac.
- On Linux without Swift: record `swift: command not found` as blocked-with-evidence, mirror still required.

## Task 3 - Local CLI smoke (no menu bar)

Steps (per RELEASE_CHECKLIST 8, README Direct terminal usage):
- `./scripts/show-usage.sh --preset lifetime --source all`
- `./scripts/show-usage.sh --all-presets`
- Each `--preset today|24h|7d|30d|best-month|lifetime`, each `--source all|codex|opencode|claude`
- `--preset lifetime --json`
- Confirm: totals, source splits, top models, estimated cost label, last updated, sanitized warnings only, no absolute paths.

Acceptance evidence:
- Command outputs or Swift-missing block note. On Linux without Swift, `show-usage.sh` cannot run (it execs `swift run TokenBarCLI`); record exact error.

## Task 4 - Native menu-bar app build / launch / quit smoke (Mac only, reversible)

Steps (per docs/MACOS_PACKAGING.md, RELEASE_CHECKLIST 3/6):
- `./scripts/run-token-bar.sh` dev-loop check OR built app check.
- `./scripts/build-app.sh --version <x.y.z>` produces `dist/TokenBar.app` with `Info.plist` (`LSUIElement=true`, `LSMinimumSystemVersion=14.0`) and `MenuBarExtra` UI.
- Reversible smoke: `open dist/TokenBar.app`, confirm menu-bar process starts (`pgrep -af TokenBar`), confirm UI, then quit via `osascript -e 'quit app "TokenBar"'` or Activity quit. No install to /Applications required.
- Launch-at-login toggle state check: bundled vs unbundled copy per docs.

Acceptance evidence:
- `ls dist/TokenBar.app/Contents`, `Info.plist` keys, process-start log, quit confirmation.
- On Linux: record `swift` / macOS SDK missing as blocked-with-evidence. Do not fake a bundle.

## Task 5 - Versioned app packaging

Steps (per docs/MACOS_PACKAGING.md, RELEASE_CHECKLIST 5):
- Package *after* signing/stapling: `./scripts/package-release.sh --version <x.y.z> --format zip` (DMG via `--format dmg`, macOS only).
- Record artifact name `dist/TokenBar-<x.y.z>-macos.zip` (+ `.dmg` if built).

Acceptance evidence:
- `ls -lh dist/` output showing artifact. On Linux without a built `.app`, record `app bundle missing` block note.

## Task 6 - Checksum

Steps:
- `./scripts/package-release.sh` writes `.sha256` beside artifact.
- Verify with `(cd dist && shasum -a 256 -c TokenBar-<x.y.z>-macos.zip.sha256)` (or `sha256sum` fallback on Linux).

Acceptance evidence:
- Pasted checksum file contents + verify `OK` line, or blocked note if no artifact.

## Task 7 - Optional Developer ID signing (Mac only, manual, never commit credentials)

Steps (per docs/MACOS_PACKAGING.md, RELEASE_CHECKLIST 4):
- Presence/status check only, no secret printing:
  - `command -v codesign`
  - `security find-identity -v -p codesigning` (presence of Developer ID Application identity: yes/no, no full identity print beyond safe status)
  - `env` presence check for signing/notary vars (names only, values redacted)
- If credentials available: `codesign --deep --force --verify --verbose --sign "Developer ID Application: Your Name (TEAMID)" dist/TokenBar.app`, then `codesign --verify --deep --strict` and `spctl -a -vvv -t install`.
- Unsigned local builds remain valid for dev.

Acceptance evidence:
- Tool presence + identity presence (yes/no), sign/verify outputs if signed, or exact external prerequisite if not available.

## Task 8 - Optional notarization / stapling (Mac only, manual)

Steps (per docs/MACOS_PACKAGING.md):
- `ditto -c -k --sequesterRsrc --keepParent dist/TokenBar.app dist/TokenBar-<x.y.z>-macos.zip`
- `xcrun notarytool submit ... --keychain-profile "TOKENBAR-NOTARY" --wait` (keychain profile, never commit)
- `xcrun stapler staple dist/TokenBar.app`, `xcrun stapler validate`, re-check `spctl`.
- Re-package stapled app before checksum.

Acceptance evidence:
- `notarytool` submission status, `stapler validate` output, or blocked note with exact prerequisite (paid Apple Developer account + keychain profile + Mac).

## Task 9 - Final release artifact verification + privacy / credential scan

Steps (per RELEASE_CHECKLIST 5/7/9):
- `ls -lh dist/` + `shasum -c` re-verify covers final (signed/stapled) artifact.
- Privacy gate: `grep -rniE 'URLSession|http|cookie' Sources/` returns nothing except documented `No auth, no cookies, no network` in `Sources/TokenBarCore/Store.swift`.
- CLI/JSON output contains no absolute paths, prompt text, message bodies (covered by `ReportTests` + smoke).
- No secrets committed: synthetic fixtures only under `Fixtures/`; never real logs, DBs, `.env*` (see `.gitignore`). `git status` shows no credentials.
- Release notes carry estimate disclaimer: `Estimated cost ... (estimate only; static table, not a bill; subscription use is not an API invoice)`.
- Rollback path noted: toggle off, quit, delete app; re-tag/re-publish previous artifact.

Acceptance evidence:
- Pasted `ls`, `shasum -c`, privacy-grep output, `git status --short`.

---

## Status log (dated, append-only)

### 2026-09-10 - Plan created, execution starts

- Base confirmed: `origin/main` = `323ee30d0abb58aae759178d94d20f6bcccde03f`.
- Worktree: `/tmp/opencode/token-bar-release-execution` on branch `feat/release-execution`.
- Host for this run: Linux (`Linux manuotel 6.17.0-40-generic`, no `sw_vers`, no Swift toolchain). Mac-only tasks will be attempted and recorded as blocked-with-evidence where the OS/SDK is missing.
- Signing/notary policy: presence/status checks only, values redacted, never commit credentials.
- Next: run Tasks 1-9 in order, update below with evidence.

### 2026-09-10 - Execution results (Linux host)

- Task 1 clean checkout: PASS. `git rev-parse HEAD` = `323ee30d0abb58aae759178d94d20f6bcccde03f`, matches `origin/main`. `git status --short` shows only `?? RELEASE_EXECUTION_PLAN.md` (this plan file). Branch `feat/release-execution` tracks `origin/main`.
- Task 2 full tests: PARTIAL (Linux possible subset PASS, Mac subset blocked).
  - `PYTHONDONTWRITEBYTECODE=1 python3 -B scripts/verify_logic.py`: PASS, `All verify_logic checks passed` (Python 3.13.7).
  - Shell syntax: PASS. `bash -n` + `sh -n` clean on all four `scripts/*.sh`; executable bits set (`-rwxr-xr-x` on build-app, package-release, run-token-bar, show-usage).
  - `swift build` / `swift test`: BLOCKED locally on Linux (`swift: command not found`; requires Mac Xcode 15+ / macOS 14 SDK). CI macOS job is source of truth - see 2026-09-10 CI update below.
- Task 2 CI update 2026-09-10: PASS on PR #10. `macOS build + test` pass (18s), `Linux verify + shell syntax` pass (6s), `Privacy gate` pass (5s). Run https://github.com/ManuOtel/token-bar/actions/runs/34516816265.
- Task 3 local CLI smoke: BLOCKED (needs Swift). `./scripts/show-usage.sh --preset lifetime --source all` fails with `./scripts/show-usage.sh: 22: exec: swift: not found` (script execs `swift run TokenBarCLI`). Requires Mac with Swift 5.9+. No product output invented.
- Task 4 menu-bar app build/launch/quit smoke: BLOCKED (needs Mac). `./scripts/build-app.sh --version 0.1.0` prints `Building TokenBar 0.1.0 (1) id=com.manuotel.TokenBar` then `./scripts/build-app.sh: 103: swift: not found`. No `dist/TokenBar.app` produced; no fake bundle created. Reversible smoke (`open dist/TokenBar.app`, `pgrep -af TokenBar`, quit) requires macOS 14+; launch-at-login toggle check requires bundled app per `docs/MACOS_PACKAGING.md`.
- Task 5 versioned packaging: BLOCKED (needs built .app). `./scripts/package-release.sh --version 0.1.0 --format zip` fails with `Error: app bundle missing at dist/TokenBar.app. Run ./scripts/build-app.sh first.` Requires Mac build first, then package after signing/stapling per docs. `dist/` absent (git-ignored, expected).
- Task 6 checksum: BLOCKED (no artifact to checksum). `shasum 6.04` and `sha256sum` present on host, but no `dist/TokenBar-*-macos.zip` exists. Verify command for Mac release: `(cd dist && shasum -a 256 -c TokenBar-<x.y.z>-macos.zip.sha256)`.
- Task 7 Developer ID signing: NOT AVAILABLE (external prerequisite). Presence-only check, no secrets printed: `codesign` missing, `xcrun` missing, no `TOKENBAR/DEVELOPER/NOTARY/APPLE/SIGN` env vars present. Exact prerequisite for signed release: Mac with Developer ID Application certificate (`codesign --deep --force --verify --verbose --sign "Developer ID Application: Your Name (TEAMID)" dist/TokenBar.app`, then `codesign --verify --deep --strict` + `spctl -a -vvv -t install`), per `docs/MACOS_PACKAGING.md`. Unsigned local builds remain valid for dev. No credentials added or committed.
- Task 8 notarization/stapling: NOT AVAILABLE (external prerequisite). `xcrun` missing, `ditto` missing (zip fallback would apply on Linux), `hdiutil` missing (DMG needs Mac). Exact prerequisite: paid Apple Developer account + local keychain profile `TOKENBAR-NOTARY` + Mac (`xcrun notarytool submit ... --wait`, `xcrun stapler staple/validate`, re-package, re-checksum). Never commit credentials.
- Task 9 final verification + privacy: PARTIAL PASS.
  - Privacy gate: PASS. `grep -rniE 'URLSession|http|cookie' Sources/` empty except documented `No auth, no cookies, no network` in `Sources/TokenBarCore/Store.swift:8`.
  - Estimate disclaimer: PASS. Present in `Sources/TokenBarCore/Report.swift:133`, `Sources/TokenBarApp/DashboardView.swift:83`, README, RELEASE_CHECKLIST.
  - Fixtures: PASS. Only `synthetic-claude-sample.jsonl`, `synthetic-codex-sample.jsonl` under `Fixtures/`; `git status --short` shows only this plan file; no `.env*`, DBs, or real logs.
  - Artifact `ls`/`shasum -c`: BLOCKED (no `dist/` artifact on Linux; must re-verify final signed/stapled artifact on Mac).
- `RELEASE_CHECKLIST.md`: no edit needed. Checklist remains the M6 gate; this plan records Linux evidence + exact Mac prerequisites without changing checklist semantics.
- Rollback: app writes no data files; toggle login off, quit from menu bar, delete `/Applications/TokenBar.app`; re-tag/re-publish previous artifact + checksum.
