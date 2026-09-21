# Configurable chart styles proposal

Scope: docs/process-only. This document proposes configurable trend
chart styles for the next Token Bar release. It changes no source,
tests, CI, VERSION, CHANGELOG, packaging, or website behavior. The
implementation lands only under a later milestone (PLAN.md M12) with
fixtures, tests, and docs. This proposal is grounded in the current
product: a 400pt macOS MenuBarExtra popover, the adaptive `TrendModel`
grain per range, and `DashboardSnapshot` as the single render input.

References (Apple only):

- Human Interface Guidelines, Charts: https://developer.apple.com/design/human-interface-guidelines/charts
- Swift Charts documentation: https://developer.apple.com/documentation/charts
- Creating a chart using Swift Charts: https://developer.apple.com/documentation/charts/creating-a-chart-using-swift-charts

## 1. Context and problem

The dashboard renders one adaptive trend today: zero-filled buckets
from `TrendModel` with a previous-period comparison line for
chronological ranges. Grain is fixed per range: hour for Today and
24H, day for 7D, 30D, and Best month, month for All time. Titles name
the range and grain (for example TODAY BY HOUR, LAST 7D BY DAY, ALL
TIME BY MONTH). The compact popover shows an adaptive mini trend and
Details shows the full trend with a grain caption.

One fixed bar rendering fits small comparisons but reads poorly in
two cases: long sparse histories where most buckets are zero, and
time trends where the reader wants continuity across buckets rather
than per-bucket comparison. The popover is small (400pt, compact
first, no scroll in compact), so any added choice must keep compact
compact, keep Details readable, and reuse the same data model.

## 2. Recommendation

Add a chart style control with four options. Default is Automatic.

- Automatic (default): the view picks Bars or Line with points from
  the active range and grain. Hourly and short daily ranges default
  to Bars. Longer or sparse ranges default to Line with points.
  Section 4 defines the exact mapping.
- Bars: discrete per-bucket comparison. Best for hourly buckets,
  daily buckets over 7D and 30D, sparse buckets with many zeros, and
  Best month daily views where single-day spikes matter.
- Line with points: time trend continuity. Best for 30D daily series
  with dense data, Best month shape, and All time monthly series.
  Points stay visible at the 400pt width so single-record days are
  not lost on the line. The previous-period comparison stays a thin
  line in all styles.
- Area: total-volume shape only. One unstacked area for the selected
  total-token series. No stacked multi-source areas in this release:
  stacked areas imply part-to-whole math the trend does not carry
  (the trend sums `totalTokens` only; cached and reasoning are
  subsets and are never added on top).

What does not change:

- The source bar stays a separate visualization with
  percent-of-total shares. The trend never replaces it and never
  stacks per-source series.
- The input/output comparison stays a separate visualization. The
  compact paired log-scaled bars with exact counts and the expanded
  input-vs-output ring keep their current semantics. The trend shows
  total tokens only and never splits input vs output per bucket.
- Top-5 models stay bar rows with percent-of-total shares. Trend
  style selection does not restyle them.

Future heatmap idea: a calendar heatmap for day-level density is
explicitly out of scope for this release. It stays a possible later
proposal with its own fixtures, tests, and accessibility plan. No
heatmap code, preference, or control lands under this proposal.

## 3. Interaction model

- Location: a Chart style menu in expanded Details only, next to the
  full trend title and grain caption. Compact has no style control.
- Options: Automatic, Bars, Line with points, Area. One selection
  applies to all ranges. There is no per-range memory in this
  release, which keeps the preference model small and testable.
- Persisted preference: stored as a single user default (for example
  one string key read through `AppStorage`), applied at launch
  before first render. An unknown or missing value falls back to
  Automatic. Reset is explicit (a Reset control or defaults delete),
  never a silent migration.
- Compact view remains compact: compact always renders the Automatic
  mapping at mini size with no control, no horizontal overflow, and
  no added height. A user selection of Line or Area affects Details
  only in the sense that compact keeps the Automatic pick; compact
  never grows a picker or a legend.
- Automatic adapts to grain and range: changing the range chip
  re-evaluates the Automatic pick from the same `DashboardSnapshot`
  (preset, grain, bucket count, sparsity). No reload, no rescan.
- Source and range chips keep working as today: the trend and the
  comparison use the active source filter and preset from the same
  snapshot. Switching source re-renders the same style with new
  values.

## 4. Visual rules per range

Automatic mapping (default when the user picks Automatic):

- Today by hour: Bars. Hourly comparisons with frequent zeros read
  best as discrete bars. Zero buckets render as gaps on the axis,
  never as omitted slots.
- Last 24H by hour: Bars. Same reason as Today. The 24 rolling
  hourly buckets keep fixed order and stable hour labels.
- Last 7D by day: Bars. Seven to eight daily buckets fit the 400pt
  width as bars with exact-count tooltips.
- Last 30D by day: Automatic picks Bars when the series is sparse
  (many zero days) and Line with points when dense. The exact
  sparsity threshold is set at implementation time and recorded in
  the implementation PR; the proposal requires one documented rule,
  not two competing heuristics.
- Best month by day: Bars by default under Automatic, Line with
  points as a valid manual pick. Daily spikes inside one month are
  comparison reads first, shape reads second.
- All time by month: Line with points under Automatic. Monthly
  lifetime series are long and often sparse at the tail; a line
  preserves continuity while points keep single-record months
  visible. Bars remain available as a manual pick for short
  lifetimes (for example two to three months).

Rules shared by all styles and ranges:

- Zero-filled buckets: every range renders full coverage from
  `TrendModel` (hours from day start through current hour for
  Today, 24 rolling hours for 24H, calendar days for 7D/30D/Best,
  calendar months for All time). Empty buckets are visible gaps on
  the axis, never hidden. Bucket-token sums equal the hero total.
- Axes and labels: x axis shows a sparse subset of bucket labels
  plus the full first-to-last range in the caption so long histories
  stay readable. Y axis starts at zero and scales to the peak
  bucket. No truncated y axis. Exact counts appear in tooltips and
  accessibility labels, never only as bar height.
- Comparison annotations: chronological ranges (Today, 24H, 7D, 30D)
  keep the thin previous-period line plus the existing direction
  copy (up, down, flat, or "No prior-period data" with no direction
  and no percent when there is no baseline). Best month and All
  time have no comparison line, in any style. The comparison line
  never becomes bars or area.
- Area limits: single total-token area only, with the line edge in
  the same series color. No stacked areas, no per-source areas, no
  input/output split areas. Opacity must pass Increase Contrast
  (section 6).
- Color and series semantics: one series color for the current
  total-token series across all styles; one distinct thin style for
  the comparison line. Source colors, model bar colors, and the
  input/output blue/orange pair are unchanged and are never reused
  for the trend series in a way that implies they share a scale.

## 5. Log-scale handling for extreme input/output imbalance

The trend itself stays linear in all styles. Log scaling applies
only to the existing input/output comparison, which already handles
cases like multi-billion input against multi-million output with
labeled log-scaled bars, exact counts, a single 6 percent visibility
floor, and a scale footnote. Zero stays zero there.

This proposal adds no log-scaled trend axis because a log trend axis
hides the zero-filled gaps that section 4 requires (log of zero is
undefined) and it compresses the spikes that Bars are meant to show.
When input/output imbalance is the question, the answer stays the
input/output comparison view, not the trend. The trend answers a
different question: total volume over time.

## 6. Source and model detail views

- Source rows and the source bar are unchanged. Selecting a source
  filter re-renders the trend for that source with the same style;
  the trend never shows multiple source series at once.
- OpenCode local/remote sub-lines stay text rows under the combined
  OpenCode row. They do not become chart series.
- Top-5 model bars are unchanged. The trend does not gain a
  per-model mode in this release. A per-model trend would need its
  own proposal (series limit, color scale, accessibility plan) and
  is out of scope here.
- Empty and zero states: an empty store renders the existing empty
  copy with no chart frame. A zero scoped count for the selected
  filter renders the existing zero copy plus the wider-range hint;
  the chart area renders axes with zero buckets and an explicit
  "No data in this view" label, never an empty bordered box.

## 7. Comparison annotations, tooltips, keyboard, and focus

- Comparison annotation: the direction and percent copy sits with
  the grain caption (for example "LAST 7D BY DAY, daily buckets,
  vs previous 7 days: up 12 percent"). No-baseline reads
  "No prior-period data" with no arrow and no percent. Exact
  current and previous totals are available in the tooltip and the
  accessibility label.
- Tooltips: every bucket exposes its label, exact token count, and
  request count on hover. Comparison tooltips expose current total,
  previous total, direction, and percent (or the no-baseline note).
  Tooltips show exact counts; they never show rounded-only values.
- Keyboard and focus behavior: the Chart style menu is a native
  menu control reachable by Tab with a visible focus ring. Chart
  content itself is not a tab stop per bucket; instead one focusable
  chart region exposes the full series summary (title, grain, range,
  current total, comparison) and each bucket value is available
  through VoiceOver navigation and the tooltip path. Focus never
  traps inside the chart. `Details` and `Show less` keep their
  current focus behavior.
- No hover-only meaning: every value available on hover is also
  available in the accessibility label and in the keyboard-focusable
  region summary.

## 8. VoiceOver, accessibility labels, and Audio Graph support

Follow the Apple Charts guidance above: every chart needs a label,
and data values need accessible equivalents, not color-only meaning.

- Each trend chart exposes one accessibility label with the title,
  grain, range, bucket count, current total tokens, and comparison
  summary (for example "Last 7 days by day, 8 daily buckets, current
  total 1.2 million tokens, up 12 percent vs previous 7 days" or
  "Best month by day, 31 daily buckets, no comparison for this
  range"). Empty and no-baseline states have explicit labels.
- Buckets expose per-bucket values (label, exact tokens, requests)
  through the accessibility tree so VoiceOver users can review the
  series step by step.
- Audio Graph support: when the implementation uses Swift Charts,
  it adopts the framework audio graph support for the trend so the
  series is explorable as sound where the platform provides it. If a
  custom renderer is kept for any style, the proposal requires an
  equivalent accessible series summary plus per-bucket values; a
  custom view with no accessible series equivalent is not accepted.
- Dynamic Type: labels, captions, tooltips, and the style menu
  respect larger text sizes with no clipped text. The chart drawing
  area may compress but axis labels must not overlap into
  unreadable runs; sparse labeling (section 4) is the mechanism.
- Reduce Transparency and Increase Contrast: the trend must pass
  both with no unreadable text, no missing comparison line, and no
  invisible area fill. The area fill keeps a contrast-safe opacity
  floor and a visible line edge. The Mac render pass records both
  settings explicitly (section 10).

## 9. Performance

- Render `DashboardSnapshot` only. Style selection changes the view
  renderer, never the data derivation. No extra file scans, no extra
  filter passes, no per-bucket queries. The snapshot already carries
  `trendBuckets`, `trendGrain`, `trendTitle`, and `comparison`; all
  styles read those stored values.
- Automatic evaluation is constant time over the stored buckets
  (count plus zero-bucket share). No sorting, no re-aggregation.
- No decorative animation. Style switches render the new marks
  immediately with no transition that changes popover size. The
  existing popover size contract holds: 400pt content width,
  content-sized height, compact has no scroll, Details scrolls
  vertically only.
- No added persistence cost: one string preference read per launch
  plus one write per user change.

## 10. Privacy

Usage data, prompts, message bodies, paths, credentials, and
subscription sessions never leave the machine. Chart styles change
rendering only; they add no network use, no subprocess, no file
write beyond the single style preference, and no new persistence of
usage values. The pricing GET and the SSH snapshot pull keep their
existing opt-in boundaries and owners.

Evidence rules for the implementation PR:

- Screenshots with real usage values remain local work notes. They
  are never committed and never attached to public PRs, issues, or
  releases.
- Public artifacts (screenshots, recordings, pasted popover text)
  are built from synthetic fixtures under `Fixtures/` only. If an
  artifact cannot be reproduced from fixtures, describe it in words.
- Never print, commit, or paste environment contents, database
  contents, snapshot contents, SSH config, or credentials. Name a
  variable (for example the chart style default key) and give a
  redacted shape, never a live value.

## 11. Implementation boundaries

- One shared trend data model: `TrendModel` plus
  `DashboardSnapshot` trend fields stay the single source of truth.
  No per-style bucket derivation, no second trend path.
- Renderer selection at the view layer: the style preference picks
  a renderer (Bars, Line with points, Area) over the stored
  buckets. Filtering, aggregation, pricing, and comparison math do
  not branch on style.
- Stable color and series semantics: one trend series color, one
  comparison line treatment, unchanged source/model/input/output
  colors (section 4). No per-style color inventions.
- No decorative animation: no transitions, no size-changing effects.
- No extra glass or material surface: the MenuBarExtra window style
  stays the single host surface. Chart styles add no material, no
  blur, no `glassEffect` on charts, cards, or text. Functional
  control styling for the style menu follows the existing control
  treatment only.
- macOS 14 availability: any Swift Charts API used must exist in
  the macOS 14 SDK. If a needed mark, annotation, or audio graph
  API is newer, the implementation documents the gap and ships the
  closest macOS 14 equivalent rather than raising the floor.
- Geometry contracts hold: popover structure, conditional slots,
  heights, scroll ownership, and material rules from
  `docs/SECURITY_AND_VISUAL_QA.md` section 4 are unchanged. The
  implementation PR extends `scripts/test-popover.sh` only if it
  touches structure, slots, heights, scroll ownership, materials,
  or glass placement.

## 12. Tests required (implementation PR, not this proposal)

- Renderer selection: Automatic picks the documented style per
  range and grain (Today/24H Bars, 7D Bars, All time Line with
  points, sparse vs dense 30D rule), and explicit Bars, Line, Area
  selections render the requested marks for the same snapshot.
- Accessibility labels: every style exposes the series summary
  label; empty and no-baseline states expose their explicit labels;
  per-bucket values are reachable; no chart is an unlabeled image.
- Empty and no-baseline states: empty store, zero scoped count,
  Best/All with nil comparison, and no-baseline chronological
  ranges each render the specified copy with no direction and no
  percent.
- Chart style persistence: default is Automatic when unset; unknown
  stored values fall back to Automatic; a change persists across
  relaunch; reset returns to Automatic.
- Bucket coverage: zero-filled coverage per range is unchanged by
  style (bucket count, order, labels, and token sums equal the hero
  total in every style).
- Visual geometry contracts: `scripts/test-popover.sh` plus a Mac
  render pass over compact and expanded, light and dark, empty,
  zero, no-comparison, notices, Reduce Transparency, and Increase
  Contrast states, built from synthetic fixtures. Record gaps as
  gaps, never as passes.

## 13. Acceptance for the implementation milestone

The implementation PR closes only when it delivers the style menu,
the three renderers plus Automatic, persistence, the section 4
mapping, accessibility labels with Audio Graph support where the
platform provides it, the section 10 privacy evidence rules, and
the section 12 tests, with `swift build` plus `swift test` green on
a Mac and the Linux mirror plus privacy and contract scripts green.
Docs-only changes under this proposal do not bump VERSION and do
not create a release.
