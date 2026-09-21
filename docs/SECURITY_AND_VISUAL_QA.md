# Security and Visual QA Gate

Scope: docs/process-only. This document defines worker, merge, and
release gates that prevent a repeat of the popover bare-material strip
regression (PR #65) and keep local usage data inside the machine. It
changes no source, tests, CI, packaging, or website behavior. It points
at existing contracts: `scripts/test-popover.sh`,
`scripts/check-privacy.sh`, `scripts/verify_logic.py`,
`docs/RELEASE_PROCESS.md`, `RELEASE_CHECKLIST.md`.

## 1. Threat model and privacy boundary

Assets: local usage histories (Codex JSONL, OpenCode SQLite, Claude
JSONL), sanitized snapshots and sync cache, prompts and message bodies,
file paths, credentials and SSH setup, process environment contents,
screenshots and logs that may embed any of the above, provider pricing
data (public, opt-in only).

Adversary: any party that can read a committed file, a PR artifact, a
log, or a screenshot. Assume PR diffs, CI logs, and release notes are
public. Assume local files outside the repo (histories, DBs, SSH
config, keychain) are sensitive by default.

Boundary rules:

- Usage data, prompts, message bodies, paths, credentials, cookies, and
  subscription sessions never leave the machine. Adapters open files
  read-only. Warnings and CLI/JSON output use generic labels only.
- The only network uses are strictly opt-in: the OpenRouter pricing
  catalog GET (`Sources/TokenBarCore/PricingService.swift` is the only
  file allowed to touch the network) and the remote-host SSH snapshot
  pull (`Sources/TokenBarCore/OpenCodeSync.swift` is the only file
  allowed to spawn a subprocess: system ssh/scp, argv arrays, never a
  shell, `BatchMode=yes`, no stored passwords or keys, no usage data
  sent). Default runs are fully offline.
- Env var names (`TOKENBAR_*`) are public config; env var values,
  process environments, and file contents are not. Never print, commit,
  or paste them.
- Screenshots of real usage data are local-only work notes. They are
  never committed, never attached to public PRs, issues, or releases.
- Provider data is limited to the public OpenRouter pricing GET plus
  the offline static fallback. No provider auth, no account APIs, no
  cookies or Authorization headers.

## 2. Worker evidence rules

- Committed or public rendered artifacts (screenshots, recordings,
  pasted popover text) must be built from synthetic fixtures under
  `Fixtures/` only. If an artifact cannot be reproduced from fixtures,
  describe it in words instead of attaching it.
- Real-data screenshots stay local and uncommitted. Never attach them
  to a PR, issue, release, or chat transcript that leaves the machine.
  When reporting a visual bug seen with real data, reproduce it with
  fixtures first, then file the fixture-based evidence.
- Never dump a process environment (`env`, `printenv`, IDE environment
  panels, crash reports with environment sections). When an override
  matters, name the variable (for example `TOKENBAR_CLAUDE_ROOT`) and
  give a redacted shape (set/unset, synthetic path), never the value
  from a real machine.
- Sanitize worker output: generic labels, neutral placeholders
  (`user@server.example`, `/path/to/opencode.db`), no absolute real
  paths, no hostnames, no run URLs with ids, no prompt or message text.
  Run `./scripts/check-privacy.sh` before requesting review; it scans
  tracked files only, so untracked local files are still the worker's
  responsibility.
- Never read, print, stage, commit, or expose real usage databases,
  session logs, snapshot files with real user data, SSH config, or
  credentials to reproduce a bug. Use `Fixtures/` plus the
  `TOKENBAR_*` overrides pointed at synthetic copies.

## 3. Visual regression matrix (Mac harness)

Run on a Mac with the built app against synthetic data. Cover compact
and expanded popover in both light and dark appearances:

- Compact (400pt, no scroll): hero total, estimated cost, source chips
  (All/Codex/OpenCode/Claude), range chips
  (Today/24H/7D/30D/Best/All), input/output comparison bars, source
  bar, adaptive mini trend with comparison line, Details action,
  updated/notices footer.
- Expanded Details (scrollable): metric cards, composition card,
  source rows with OpenCode local/remote sub-lines, top-5 models, full
  adaptive trend with grain caption and comparison, notices, Show less.
- States: empty store (no records), zero scoped count for the selected
  filter, no-comparison ranges (Best month, All time), long notice
  lists (must scroll inside expanded Details, not push the popover),
  stale-cache and loading banner on/off.
- Checks per state: accessibility tree exposes every control and chart
  with a label (no unlabeled image-only content); full keyboard focus
  order reaches chips, Details/Show less, and Settings controls with a
  visible focus ring; no clipped text, no wrapped controls, no
  horizontal overflow in compact; expanded scrolls vertically only.
- When the Mac harness supports them, also verify Reduce Transparency
  and Increase Contrast: no bare-material strip, no unreadable text,
  no missing focus indication. If the harness cannot set them, record
  that as a gap instead of claiming a pass.

Record per-state pass/fail plus the appearance used. A state that was
not rendered is a gap, not a pass.

## 4. Geometry and material contracts

These are the invariants PR #65 restored. `scripts/test-popover.sh`
asserts the static subset; the Mac render pass asserts the visible
subset.

- MenuBarExtra host: fixed 400pt content width, content-sized height,
  root padding 16. No forced outer height in `TokenBarApp.swift`, no
  competing height cap there. The Details `ScrollView` (expanded only,
  `.frame(minHeight: 280, maxHeight: 380)`) is the sole
  expanded-height owner. Compact has no vertical scroll region.
- Empty conditional slots are omitted from the hierarchy with a plain
  parent `if`, never rendered as an empty view: status banner (top
  slot below the divider, `showsStatusBanner` guard), notices (both
  placements, `hasNotices` guards), nil comparison line in both trend
  stacks (`if comparison != nil`). Rationale: a hidden child that
  stays in a `VStack` still consumes spacing, which reads as a bare
  window-material strip at the popover edge in light appearance.
- Single system host surface: the MenuBarExtra `.window` style owns
  the background. No `containerBackground` modifier in app sources
  (it is also absent from the macOS 14 SDK), no second material, no
  decorative blur, no popover-scale fixed height, no
  `scrollContentBackground` override, no animation that changes
  popover size.
- Liquid Glass lives only on functional controls (chips and actions
  in `LiquidGlass.swift`). Charts, cards, and text stay off custom
  glass (`glassEffect` must not appear in `TokenBarApp.swift` or
  `DashboardView.swift`).
- Any change to popover structure, conditional slots, heights, scroll
  ownership, materials, or glass usage must extend
  `scripts/test-popover.sh` in the same PR and re-run the section 3
  matrix on a Mac.

## 5. Merge and release gates

Merge gate (every PR touching the popover, Settings, sync, pricing, or
release docs):

- Exact-head match: the reviewed SHA is the SHA CI ran and the SHA
  merged. Re-verify `git log` and `git diff` after any rebase or push.
- Independent review before merge. Reviewer confirms scope (no source,
  test, CI, version, packaging, or site-behavior change on docs-only
  PRs) and confirms the evidence below.
- Green CI on the PR: macOS 14 job (`swift build` + `swift test`),
  Linux job (`verify_logic.py` mirror plus shell syntax), privacy-gate
  job (`URLSession` confined to `PricingService.swift`, `Process(`
  confined to `OpenCodeSync.swift`, catalog hosts allowlisted to
  `openrouter.ai`, no Cookie/Authorization headers, plus
  `scripts/check-privacy.sh`).
- Local Mac render evidence for visual changes: section 3 matrix
  results (states, appearances, gaps) recorded in the PR or linked
  issue, built from synthetic fixtures.
- Privacy-safe evidence handling: `./scripts/check-privacy.sh` green,
  `git diff --check` clean, no real paths, no environment dumps, no
  real-data screenshots attached.

Release gate (in addition to `docs/RELEASE_PROCESS.md` steps 5-9 and
`RELEASE_CHECKLIST.md` sections 2 and 8):

- Release-candidate install on a Mac from the built artifact, then
  smoke: `Info.plist` version matches `VERSION`, exactly one TokenBar
  process runs, dashboard loads local history with sanitized warnings
  only, compact and expanded popover render with no strip, no clip,
  and no overflow in the release appearance check (at minimum the
  appearance the release Mac uses, plus the other appearance when the
  harness allows it).
- Evidence recorded in the release PR or issue: release PR number,
  tagged `main` HEAD SHA, tag name, green tag workflow run,
  asset/checksum verification, installed-version verification, and
  the visual smoke result.

## 6. Incident response for a visual regression

1. Freeze: do not tag or publish on top of a suspected popover
   regression. File an issue with fixture-based reproduction steps,
   the states and appearances affected, and the last known good tag.
2. Reproduce on synthetic data on a Mac; confirm whether
   `scripts/test-popover.sh` catches it. If not, the fix PR must add
   the missing static assertion alongside the product fix.
3. Fix narrowly: restore the section 4 contract (parent-conditional
   slots, single host surface, scroll ownership, glass placement)
   with plain `if` and no material, height, blur, or animation change
   unless the issue explicitly scopes one.
4. Re-run the full section 3 matrix on a Mac plus `swift build`,
   `swift test`, `verify_logic.py`, shell syntax checks,
   `check-privacy.sh`, and the contract scripts. Record results in
   the fix PR.
5. Release only through the normal path: reviewed fix PR, green PR CI,
   merge to `main`, then the version/changelog decision, exact tag,
   and verified install. Never silently overwrite a published asset.

## 7. Security checks for boundaries and artifacts

- Network boundary: `URLSession` appears only in `PricingService.swift`;
  catalog hosts are allowlisted to `openrouter.ai`; no Cookie or
  Authorization headers; pricing refresh stays opt-in with offline
  fallback; sync sends no usage data.
- Process boundary: `Process(` appears only in `OpenCodeSync.swift`;
  system ssh/scp via argv arrays, never a shell; `BatchMode=yes`
  always; blank host/path rejects without spawning; no credential
  fields exist in config or cache.
- File boundary: adapters open histories read-only; extra paths are
  comma- or newline-separated with missing entries warning only; sync
  validates the snapshot before replacing the cache (decodable token
  rows or empty, size cap) with temp-then-atomic write and last-good
  fallback; all parsers degrade to empty plus a sanitized warning.
- Release artifacts: package after signing/stapling on the manual
  path; publish each artifact plus its `.sha256`; verify checksums and
  the DMG layout before install; rollback re-tags/re-publishes the
  previous versioned artifact, never overwrites silently.
- Commands: `PYTHONDONTWRITEBYTECODE=1 python3 -B
  scripts/verify_logic.py`, `bash -n scripts/*.sh`, `sh -n
  scripts/*.sh`, `./scripts/check-privacy.sh`, `git diff --check`,
  plus the contract scripts touched by the change
  (`scripts/test-popover.sh`, `scripts/test-versioning.sh`,
  `scripts/test-release.sh`, `scripts/test-site.sh`). On a Mac,
  `swift build` and `swift test` remain the source of truth.
