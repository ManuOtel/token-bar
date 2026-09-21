# Settings-Initiated Auto-Update Proposal

Scope: docs/planning-only. This document is the dedicated auto-update
proposal that PLAN.md M11 calls for. It changes no source, tests, CI,
VERSION, CHANGELOG, packaging, website behavior, or release artifacts.
M11 text stays intact; acceptance of this written plan is separate
from any implementation, which would land only under a later worker
milestone with fixtures, tests, and docs. Docs-only changes here do
not bump `VERSION` and do not create a release.

## 1. Current state: no updater, download-only releases

The current app has no updater. Releases are download-only through
the published GitHub Release assets: versioned zip and dmg plus
checksums, with stable latest-asset aliases beside them (see
`docs/MACOS_PACKAGING.md` and `docs/RELEASE_PROCESS.md` steps 8 to 9).
The user downloads the chosen artifact, verifies the checksum,
quits the running app, installs the new bundle, and verifies the
installed version. Automated packaging in CI is unsigned and not
notarized (no credentials in CI), so Gatekeeper warns on first
launch and that is expected. There is no background check, no
background download, and no silent install in any current release.

## 2. Proposal: GitHub Releases updater with safe automatic checks

Evaluate Sparkle 2 (or an equivalent maintained signed updater)
before any custom mechanism, and prefer the maintained option unless
a follow-up proposal documents why it cannot fit the sandbox and
signing path. No custom download-and-replace mechanism lands under
this proposal.

Requirements (all must hold in any implementation PR):

- GitHub Releases is the sole update channel. The app reads the
  stable latest-release metadata for the public Token Bar repository
  over HTTPS; draft and pre-release entries are ignored. The endpoint
  and asset names are fixed in the app; users cannot configure an
  arbitrary feed or download host.
- The updater supports both an explicit Settings `Check for Updates`
  action and an opt-in automatic metadata check. The automatic check
  only discovers and reports an available version. Download and
  installation always require a separate explicit user action, and the
  running app stays intact until the user confirms replacement.
- HTTPS public release metadata only, with conditional requests and
  bounded retry/backoff. No shell commands, cookies, credentials,
  authorization headers, private repository access, or unsigned
  channels.
- Version comparison uses the repository SemVer value. A same or newer
  installed version is a no-op, and a draft or pre-release never becomes
  an update candidate.
- Signature and notarization verification before any replacement.
  Every downloaded artifact is verified (maintained-updater
  signature check plus Apple notarization and Gatekeeper standing
  for the shipped bundle) before any file is replaced. Failed
  verification aborts with no change to the installed app.
- Safe atomic replacement with rollback. Installation replaces the
  bundle atomically and keeps a path back to the previous versioned
  artifact; a failed or aborted install leaves the running version
  usable. Published assets are never silently overwritten (release
  rollback re-tags and re-publishes the previous versioned artifact
  plus checksums per `docs/RELEASE_PROCESS.md` step 10).
- Current and latest version display plus release notes before
  confirmation. Settings shows the installed version, the available
  version, and the release notes (with the estimate disclaimer on
  every dollar figure) before the user confirms. No update proceeds
  from a version number alone.
- Cancel, retry, and error states that leave the running app
  intact. Cancellation stops the flow with no partial replacement;
  transient failures (offline, timeout, bad checksum, failed
  verification) surface one sanitized message with retry and keep
  the current install running.
- Settings preservation across update. Sync config, pricing cache,
  chart style preference, and login-item state survive the update;
  no settings reset. Cached login-item state follows the existing
  bundle-id behavior (a bundle-id change resets the login item and
  the user toggles it off and on once).
- No credentials, prompts, message bodies, paths, or usage data
  leaving the machine. The check sends no account data, no file
  paths, no usage values, and no credentials; there are no stored
  passwords, keys, or tokens in the updater config or cache. The
  existing privacy boundaries stay unchanged: the pricing GET stays
  owned by `PricingService.swift` and subprocess use stays owned by
  `OpenCodeSync.swift`.
- The Settings view shows the installed version, latest stable version,
  release title and notes, verification status, and `Update` action.
  When current, it shows `Up to date` and does not download an artifact.

Non-goals for this proposal: no silent auto-install mode, no
Windows or Linux updater target, no provider auth or account APIs,
no cookies or Authorization headers, no new usage persistence, and
no real-data screenshots in public artifacts (synthetic fixtures
under `Fixtures/` only, per `docs/SECURITY_AND_VISUAL_QA.md`
section 2).

## 3. Why the updater cannot ship on the current release path

The current tag-driven release path publishes unsigned and
unnotarized artifacts (see `docs/RELEASE_PROCESS.md` step 8 and
`docs/MACOS_PACKAGING.md`). That is acceptable for manual
download-only installs, where the user verifies checksums and
Gatekeeper warns on first launch. It is not a safe base for an
in-app updater: without signatures, the updater cannot prove that
downloaded bytes came from the publisher and were not modified in
transit or on the host, so a check-then-replace loop would trade a
user-verified manual step for machine-trusted unsigned bytes. That
failure mode is worse than no updater.

Infrastructure that must change first (all required, in order):

1. Paid Apple Developer account with a Developer ID Application
   certificate, plus a notarization credential held only on the
   release Mac (for example a local keychain profile, never
   committed).
2. Signed and notarized release path: build, sign, submit for
   notarization, staple, then package so checksums cover the final
   artifact (manual path in `docs/MACOS_PACKAGING.md`). CI stays
   unsigned (no credentials in CI); the signed path runs on the
   release Mac.
3. Updater signing keys generated and stored separately from the
   repo (for example the maintained updater EdDSA key pair, public
   key embedded in the app, private key offline on the release
   Mac). The public release metadata carries per-artifact
   signatures over HTTPS; the app verifies before replacing.
4. Feed and hosting discipline: one HTTPS metadata feed pointing
   only at versioned signed artifacts plus checksums, with stable
   latest aliases updated only after verification. Never overwrite
   a published asset; failed feeds fail closed with the running app
   unchanged.
5. Implementation milestone with fixtures, tests, and docs: updater
   state machine tests (disabled default, check, download, verify,
   install, cancel, retry, rollback, settings preservation),
   privacy tests (no credentials or usage data in the check), Mac
   render pass over the Settings updater surface per
   `docs/SECURITY_AND_VISUAL_QA.md` section 3, contract scripts
   (`test-popover.sh` if Settings structure changes, plus
   `verify_logic.py`, shell syntax, `check-privacy.sh`,
   `git diff --check`), and `swift build` plus `swift test` green
   on a Mac.
6. Release path for the updater itself: reviewed feature PR, green
   PR CI, merge to `main`, then the normal version and release
   path (release PR with `VERSION` plus `CHANGELOG.md` only, exact
   tag, published-asset verification, verified install). Until
   steps 1 to 5 are done, the roadmap candidate stays a candidate
   and releases stay download-only.

Generic example shapes only: a Settings updater row names the fixed
GitHub Releases channel and a version pair (such as installed version
and available version) with redacted values; it never prints file
contents, environment values, host names, credentials, or usage data.

(End of file)
