# macOS Packaging, Signing, Install, Launch at Login

Local-only menu bar app. No network, no accounts, no updater. This doc is the
M5 release path: build a versioned `TokenBar.app`, optionally sign + notarize
it on a Mac, package a zip/DMG with a checksum, install, uninstall, and use
the launch-at-login toggle. Nothing here needs secrets to read; signing and
notarization need a paid Apple Developer account and run only on a Mac.

## Build (unsigned, reproducible, no credentials)

On a Mac with Xcode 15+ (macOS 14 SDK):

```sh
./scripts/build-app.sh --version 0.1.0 --build 1
./scripts/build-app.sh --version 0.2.0 --bundle-id com.manuotel.TokenBar
```

Env equivalents: `TOKENBAR_VERSION`, `TOKENBAR_BUILD`, `TOKENBAR_BUNDLE_ID`
(default bundle id `com.manuotel.TokenBar`). Output is
`dist/TokenBar.app` (ignored by git):

```text
dist/TokenBar.app/Contents/
  MacOS/TokenBar            # swift build -c release --product TokenBarApp
  Info.plist                # CFBundleIdentifier, version, LSUIElement
  Resources/
```

`Info.plist` notes: `LSUIElement=true` keeps the app accessory-only
(menu bar, no Dock icon); `LSMinimumSystemVersion=14.0`; `MenuBarExtra`
hosts the UI. Dev loop needs no bundle:

```sh
./scripts/run-token-bar.sh   # swift run TokenBarApp (unbundled)
```

## Package (zip default, DMG optional) + checksum

```sh
./scripts/package-release.sh --version 0.1.0 --format zip
./scripts/package-release.sh --version 0.1.0 --format dmg   # macOS only
```

This writes `dist/TokenBar-<version>-macos.zip` (or `.dmg`) plus
`dist/TokenBar-<version>-macos.zip.sha256`. Publish both files. Users verify
with:

```sh
(cd dist && shasum -a 256 -c TokenBar-0.1.0-macos.zip.sha256)
```

Zip uses `ditto -c -k --sequesterRsrc --keepParent` on macOS (falls back to
`zip -qry` elsewhere). DMG uses `hdiutil` and fails loudly off-Mac. Package
*after* signing/stapling so the checksum covers the final artifact.

## Install / uninstall

Install (zip): unzip, drag `TokenBar.app` to `/Applications`, double-click
(or right-click Open on first run for unsigned builds). Install (DMG): open
the DMG, drag to Applications, eject. First launch loads local history only
(`~/.codex/sessions`, OpenCode db, `~/.claude/projects`, read-only).

Uninstall: quit TokenBar from the menu bar, turn launch at login off (so the
login item unregisters), delete `/Applications/TokenBar.app`. TokenBar writes
no data files, so nothing else to clean. Cached login-item state lives with
the OS and clears on unregister.

## Launch at login (SMAppService, toggle in dashboard)

Implementation: `Sources/TokenBarCore/LaunchAtLogin.swift` (pure policy,
tested) + `Sources/TokenBarApp/LaunchAtLoginController.swift` (thin
`SMAppService.mainApp` wrapper, macOS 13+ API). The dashboard shows a
"Launch at login" toggle with status copy.

Behavior:

- Bundled (`TokenBar.app` in Applications): toggle registers/unregisters
  `SMAppService.mainApp`. State also visible in System Settings under
  Login Items. No helper tool, no extra entitlements.
- Unbundled (`swift run TokenBarApp`): toggle is disabled with dev-run copy
  ("launch at login needs TokenBar.app in Applications"). No system call is
  attempted. Build the bundle with `scripts/build-app.sh` to try the real
  path.
- macOS under 13: API unavailable; UI reports "unavailable on this macOS
  version" (app minimum is macOS 14, so this is a fallback only).
- Errors are sanitized (no paths) via `ReportFormatter`.

Entitlements: none added. Login items via `SMAppService.mainApp` need no
special entitlement; no filesystem or network entitlements are requested.
Reads stay read-only history files.

## Signed + notarized path (Mac only, manual, needs Developer ID)

CI never signs (no credentials). On a release Mac with a Developer ID
Application certificate and an App Store Connect API key (or Apple ID):

```sh
# 1. Build, then sign the bundle (replace TEAMID / identity name).
codesign --deep --force --verify --verbose \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  dist/TokenBar.app
codesign --verify --deep --strict dist/TokenBar.app
spctl -a -vvv -t install dist/TokenBar.app   # local Gatekeeper check

# 2. Zip the signed app, submit to Apple, wait, staple.
ditto -c -k --keepParent dist/TokenBar.app dist/TokenBar-0.1.0-macos.zip
xcrun notarytool submit dist/TokenBar-0.1.0-macos.zip \
  --keychain-profile "TOKENBAR-NOTARY" --wait
xcrun stapler staple dist/TokenBar.app
xcrun stapler validate dist/TokenBar.app
spctl -a -vvv -t install dist/TokenBar.app

# 3. Re-package the stapled app and publish the checksum.
/scripts/package-release.sh --version 0.1.0 --format zip
```

Notes: `notarytool` stores credentials in the local keychain profile; never
commit them. Stapling only applies to the `.app`/DMG on disk, so staple
before the final package step. Unsigned local builds keep working for dev
(`swift run` / `./scripts/run-token-bar.sh`) and show the unbundled toggle
state.

## Troubleshooting

- `app bundle missing at dist/TokenBar.app`: run `build-app.sh` first.
- `hdiutil not found`: DMG needs macOS; use `--format zip`.
- Toggle disabled with dev-run copy: expected under `swift run`; move a
  built `TokenBar.app` to Applications and relaunch.
- Gatekeeper warning on unsigned build: expected; right-click Open, or use
  the signed release path above.
- Toggle error after signing change: bundle id change resets the login item;
  toggle off/on once.
