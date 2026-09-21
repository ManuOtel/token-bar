# Release Roadmap

Scope: docs/planning-only. This document maps shipped and candidate
releases to milestones. It changes no source, tests, CI, VERSION,
CHANGELOG, packaging, website behavior, or release artifacts. Version
decisions happen only in a release PR per `docs/RELEASE_PROCESS.md`
step 6; version numbers below marked planned or candidate are targets,
not shipped releases. Docs-only changes here do not bump `VERSION`
and do not create a release.

Normative planning sources: `PLAN.md` milestones, `docs/RELEASE_PROCESS.md`
lifecycle (feature PR then release PR, exact `v<VERSION>` tag from
`main` HEAD), `RELEASE_CHECKLIST.md` per-release gate, and
`docs/SECURITY_AND_VISUAL_QA.md` merge and release gates.

## Release mapping

- v0.5.1 (baseline, shipped): focused popover fix. Empty conditional
  slots stay out of the layout instead of rendering blank gaps, so
  hidden status, notice, and comparison rows no longer leave bare
  strips. No change to token math, pricing, source semantics, privacy
  boundaries, or sync behavior. macOS 14 stays the deployment target.
  See `CHANGELOG.md` section 0.5.1.
- v0.6.0 (shipped): M12 configurable chart styles plus Liquid
  Glass QA evidence. Scope is the accepted
  `docs/CHART_STYLE_PROPOSAL.md` only: Automatic (default), Bars,
  Line with points, and Area over the existing adaptive
  `TrendModel` and `DashboardSnapshot`, with the Chart style menu
  in expanded Details, a persisted preference, compact kept
  compact, per-range visual rules, zero-filled buckets, linear
  trend scale, comparison annotations, tooltips, keyboard and
  focus behavior, VoiceOver labels with Audio Graph support where
  the platform provides it, Reduce Transparency and Increase
  Contrast handling, render from snapshot only with no extra
  scans, and the proposal test list. Calendar heatmap,
  per-source and per-model trend series, stacked areas, per-range
  style memory, and log-scaled trend axis stayed out of scope. No
  updater work shipped in this release. Shipped through feature
  PR #70 merged at
  `7b00d39993e19b6e7b5d90e467964940c055c478` and release PR #71
  merged at `0f6d83dd0dbddbd3ea4111faa364c1d3561a9ddc`, tag
  `v0.6.0`, release workflow `35620597510` success, Pages
  workflow `35620449707` success, and a local verified install of
  `0.6.0`. Visual evidence, stated exactly with no full-matrix
  claim: the synthetic macOS 26 local candidate showed the
  compiler/runtime Liquid Glass path; the public macOS 14 CI
  artifact and the installed release used the documented adaptive
  fallback. Compact and expanded light release smoke passed with
  no clipping/overflow/extra in-popover bands. The chart-style
  menu exposed Automatic/Bars/Line with points/Area and
  persistence was exercised. Dark appearance, Reduce
  Transparency, and Increase Contrast states not rendered in the
  release smoke are explicit follow-up gaps, not passes. See
  `CHANGELOG.md` section 0.6.0 and `PLAN.md` M12.
- Following candidate (candidate only, v0.7.0): Settings-initiated
  updater after security and signing requirements are met. Scope
  is the dedicated `docs/AUTO_UPDATE_PROPOSAL.md` only, and only
  after its acceptance plus the signing and notarization
  infrastructure it requires. There was no updater work in v0.6.0.
  Until that infrastructure exists, all releases stay
  download-only (see the proposal section 1).

Feature and release PRs stay separate: a feature PR implements one
scoped change and merges to `main` after review and green checks; it
never creates a tag or a release. A release PR bumps `VERSION` plus
`CHANGELOG.md` only. The maintainer tags `main` HEAD as exactly
`v<VERSION>` and the tag workflow publishes the release.

## Liquid Glass deployment (current app)

Short accurate statement of how Liquid Glass ships today. Normative
implementation detail lives in `Sources/TokenBarApp/LiquidGlass.swift`;
visual and merge gates live in `docs/SECURITY_AND_VISUAL_QA.md`
sections 3 to 5.

- macOS 26 SDK and runtime path: Apple Liquid Glass APIs
  (`glassEffect`, `GlassEffectContainer`, glass button styles) are
  available only on the Xcode 26 toolchain (Swift 6.2, macOS 26 SDK)
  behind the compile gate `#if compiler(>=6.2)`, and only at runtime
  on macOS 26 and later behind `if #available(macOS 26, *)`. Older
  toolchains (for example the macOS 14 CI runner) compile only the
  fallback branch, so `swift build` and `swift test` keep passing
  there.
- macOS 14 fallback path: the package deploys to macOS 14, and a
  binary built with the newer SDK still runs on macOS 14 and 15
  through the fallback. The fallback is adaptive pre-glass visuals
  (semantic opacities over the system popover material, accent-blue
  active chips), so the popover renders clean and legible under both
  light and dark appearances without glass.
- Functional-only glass boundary: glass applies only to functional
  controls (header icon actions, the source and range chip rows, and
  the primary Details and collapse actions). Charts, metric cards,
  hero totals, and explanatory text never sit inside glass. The
  `MenuBarExtra` window keeps its single system material with no
  explicit background owner, no morphing view-hierarchy effect, and
  no decorative or size-changing animation.
- Accessibility handling: custom glass surfaces are skipped when
  Reduce Transparency is on (opaque fallback instead), and Increase
  Contrast strengthens the fallback strokes. The system glass button
  style adapts to both on its own.
- Required Mac visual QA matrix: every popover or glass change
  records a Mac render pass built from synthetic fixtures under
  `Fixtures/` only (never real usage data, never committed
  screenshots of real data), covering compact and expanded popover in
  light and dark appearances across empty store, zero scoped count,
  no-comparison ranges (Best month, All time), long notice lists,
  stale-cache and loading banner states, keyboard focus order with a
  visible focus ring, VoiceOver labels, clipping and overflow checks,
  plus explicit Reduce Transparency and Increase Contrast states. A
  state that was not rendered is a gap, not a pass. Popover structure
  changes extend `scripts/test-popover.sh` in the same PR.

(End of file)
