# Release Process: Feature to Verified Install

Single ordered lifecycle for Token Bar changes, from feature plan to a
verified local install of the published release. Read this before opening
a feature PR or cutting a release. Details live in `RELEASE_CHECKLIST.md`
(per-release gate) and `docs/MACOS_PACKAGING.md` (build/package/install
mechanics). Historical records (`PLAN.md`, `RELEASE_EXECUTION_PLAN.md`)
stay untouched; this document describes the process going forward.

Two PR kinds, kept separate:

- Feature PR: implements one scoped change (product fix/feature or
  docs-only change). Merges to `main` after review and green checks.
  It never creates a tag or a release.
- Release PR: bumps `VERSION` plus `CHANGELOG.md` plus the synchronized
  public release markers in `site/index.html` only (no product or process
  code, no unrelated docs, no assets unless the site contract later
  requires them). `site/index.html` is a required synchronized release
  surface because `scripts/test-release.sh` runs `scripts/test-site.sh`,
  which enforces VERSION freshness (`v<VERSION>` plus JSON-LD
  `softwareVersion`). After it merges to `main`, the maintainer tags
  `main` HEAD and the tag workflow publishes the release.

## 1. Scope and acceptance criteria first

Before any implementation, write down in the issue or PR description:

- What changes and what explicitly does not (narrow scope, one concern).
- Acceptance criteria: observable behavior or document outcome, plus
  which checks prove it (Swift tests, `verify_logic.py`, shell syntax,
  privacy scan, contract scripts).
- Whether it is docs-only/process-only (no `VERSION` bump, no release)
  or a product change intended for a release (needs a version decision;
  see step 6).

## 2. Worker branch and worktree

- `git fetch origin`; confirm `origin/main` HEAD before starting.
- Create a separate branch from `origin/main` and a separate worktree;
  do all work inside that worktree.
- Keep scope narrow: one branch, one concern. Do not mix product
  changes, process changes, and release bumps in one PR.
- Synthetic fixtures only under `Fixtures/`. Never read, print, stage,
  commit, or expose real usage databases, session logs, snapshot files
  with real user data, SSH config, or credentials. Keep examples generic
  (`user@server.example`, `/path/to/opencode.db`).

## 3. Implementation and local checks

- Product semantics live in `TokenBarCore`; App and CLI stay thin
  renderers. Update tests when touching `TokenBarCore` semantics.
- Run the checks appropriate to the change; at minimum for any PR:
  `git diff --check`, `./scripts/check-privacy.sh`,
  `PYTHONDONTWRITEBYTECODE=1 python3 -B scripts/verify_logic.py`,
  `bash -n` / `sh -n` on touched scripts, plus the relevant contract
  scripts (`scripts/test-popover.sh`, `scripts/test-release.sh`,
  `scripts/test-site.sh`,
  `scripts/test-versioning.sh`).
- On a Mac, `swift build` and `swift test` are the source of truth;
  `verify_logic.py` is a mirror only.
- Visual and security evidence follows
  `docs/SECURITY_AND_VISUAL_QA.md`: popover, Settings, sync, pricing,
  and release-doc PRs record a Mac render pass over the section 3
  matrix (built from synthetic fixtures) and keep all evidence
  privacy-safe (no real-data screenshots, no environment dumps, no
  real paths).

## 4. Independent review and exact-head verification

- Every PR needs independent review before merge. Address review
  findings in the worker branch and re-run the affected checks.
- Before merge, verify the PR head is exactly what was reviewed and
  what CI ran: `git log`, `git diff`, and the CI run tied to that head
  SHA. Never merge a head whose checks you have not seen.

## 5. PR CI: the full pre-tag gate

Required green CI on the PR (`.github/workflows/ci.yml`):

- macOS 14 job: `swift build` + `swift test`. This proves the product
  builds and the full Swift suite passes on the release platform.
- Linux job: `verify_logic.py` mirror plus shell syntax checks.
- Privacy-gate job: `URLSession` confined to `PricingService.swift`,
  `Process(` confined to `OpenCodeSync.swift`, catalog hosts allowlisted
  to `openrouter.ai`, no Cookie/Authorization headers, plus
  `scripts/check-privacy.sh` over tracked files only.

The tag workflow (`release.yml`) re-runs build, test, and packaging on
the tagged commit, but it is a publish step, not a review step. Its
macOS 26 runner compiles the conditional Liquid Glass branch into the
downloadable binary while the deployment target remains macOS 14.
PR CI remains the full pre-tag quality gate: nothing reaches a tag
without a reviewed, green PR merge.

## 6. Version and changelog decision

Merge feature PRs first; decide the version only when cutting a release.

- Patch (`x.y.Z`): product fixes, including fixes without user-visible
  behavior change.
- Minor (`x.Y.0`): backward-compatible user-visible features (new
  filters, views, settings, sync behavior, pricing coverage).
- Major (`X.0.0`): breaking changes (storage paths, CLI output shape,
  dropped OS support, removed flags).
- Docs-only and process-only changes do not bump `VERSION` and do not
  create a release. `VERSION` moves only for product changes intended
  for a release (per the policy above).
- The release PR updates `VERSION` and `CHANGELOG.md` together, plus the
  synchronized public release markers in `site/index.html` only, in the
  same PR. No product or process code, no unrelated docs, and no assets
  unless the site contract later requires them. The site sync is required
  because `scripts/test-release.sh` runs `scripts/test-site.sh`, which
  fails a version bump whose page still names the old VERSION. Every dollar figure in release notes
  carries the estimate disclaimer (estimate only; static table, not a
  bill; subscription use is not an API invoice).

## 7. Merge to main, then tag the exact VERSION

Order matters: merge first, tag second, always from `main`.

```sh
git fetch origin
git checkout main
git pull --ff-only origin main
git log --oneline -3   # confirm the release PR merge is HEAD
VERSION="$(tr -d ' \t\r\n' < VERSION)"
git tag "v$VERSION"
git push origin "v$VERSION"
```

Rules: the tag is exactly `v<VERSION>` from the `VERSION` file at `main`
HEAD. Never tag a worker branch, never tag behind `main`, never reuse a
version. If `main` moved after the release PR, re-verify HEAD before
tagging.

## 8. What the tag workflow publishes

Pushing the exact tag triggers `.github/workflows/release.yml`
(macOS 26 release toolchain, macOS 14 deployment target), which:

1. Fails unless the tag is exactly `v<VERSION>`.
2. Re-runs `swift build` and `swift test`, then rejects a toolchain whose
   SDK is not macOS 26.
3. Builds the app with the `VERSION` value and the monotonic workflow
   build number (`GITHUB_RUN_NUMBER` as `CFBundleVersion`).
4. Packages zip and dmg with `scripts/package-release.sh`, verifies both
   checksums, and verifies the DMG layout with `scripts/verify-dmg.sh`.
5. Stages stable `TokenBar-latest-macos.zip` / `.dmg` aliases (plus
   checksums) beside the versioned assets and creates the GitHub Release
   with all eight files.

Automated packaging is unsigned and not notarized (no credentials in
CI); Gatekeeper warns on first launch and that is expected. Signed and
notarized builds are an optional manual path on a release Mac
(see `docs/MACOS_PACKAGING.md`); manual `--build` numbers are for local
verification only and never override the workflow `CFBundleVersion`.

## 9. Post-release verification, then install

Install only the verified release. In order:

1. Confirm the tag workflow run is green for the exact tag.
2. On the GitHub Release page, confirm all eight assets exist:
   versioned zip + `.sha256`, versioned dmg + `.sha256`, latest zip +
   `.sha256`, latest dmg + `.sha256`.
3. Download through the stable latest URLs and verify checksums:
   `shasum -a 256 -c TokenBar-latest-macos.<zip|dmg>.sha256`.
4. Stop the previous app first: turn launch at login off, quit TokenBar
   from the menu bar, confirm no TokenBar process remains.
5. Install the verified artifact (dmg: drag `TokenBar.app` onto
   Applications; zip: unzip, move to `/Applications`).
6. Verify the install: `Info.plist` `CFBundleShortVersionString`
   matches `VERSION`, exactly one TokenBar app process runs, and the
   dashboard loads local history with sanitized warnings only.
   Release candidates also pass the `docs/SECURITY_AND_VISUAL_QA.md`
   section 5 smoke (compact and expanded popover with no strip, no
   clip, and no overflow).

## 10. Rollback and evidence

- App rollback: toggle launch at login off, quit from the menu bar,
  delete `/Applications/TokenBar.app`. The app writes no data files.
  To fully disconnect sync, turn sync off in Settings and optionally
  delete the sync cache file. A bundle-id change resets the login item
  (toggle off/on once).
- Release rollback: re-tag/re-publish the previous versioned artifact
  plus checksums; never silently overwrite a published asset.
- Record as evidence for every release: the release PR number, the
  `main` HEAD SHA that was tagged, the tag name, the green tag workflow
  run, the post-publish asset/URL check results, and the installed
  version verification. Keep it in the release PR or issue thread.

(End of file)
