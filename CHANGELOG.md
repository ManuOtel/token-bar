# Changelog

Public release notes. Costs are estimates only, never a bill.

## 0.4.4

Focused compact input/output visualization fix. No change to token math,
pricing, source semantics, privacy boundaries, or sync behavior. macOS 14
stays the deployment target.

- The compact dashboard now uses paired input/output bars with a labeled
  log scale and a 6% visibility floor, so output remains discoverable
  when input dominates.
- Exact input/output counts remain visible, and sub-1% shares show one
  decimal. Cached and reasoning tokens remain subsets of input/output,
  and expanded Details keeps the composition ring.

## 0.4.3

Focused Details-popover fix. No change to token math, source semantics,
privacy boundaries, sync behavior, or pricing behavior. macOS 14 stays
the deployment target.

- Pressing Show details renders the full breakdown again instead of only
  the notices card: the expanded ScrollView now owns a nonzero viewport
  (280pt minimum, 380pt maximum, plain frame, macOS 14-safe) because a
  ScrollView has no intrinsic vertical size and a maxHeight-only cap
  resolves to approximately 0pt in the content-sized MenuBarExtra window.
  No forced outer window height is reintroduced.
- Notices moved inside the expanded scroll content, so the first viewport
  shows details and long notice lists scroll with them. Notices stay
  outside the scroll region only for the empty and no-scope states.
  Compact mode, filters, Details/Show less, keyboard/Escape behavior,
  accessibility labels, and sanitized warning rendering are unchanged.

## 0.4.2

Focused popover-window fix. No change to token math, source semantics,
privacy boundaries, sync behavior, or pricing behavior. macOS 14 stays
the deployment target.

- The menu-bar popover no longer forces a fixed expanded height: the
  window sizes to its compact/expanded content, so the thin transparent
  bands above and below the dashboard are gone. The details ScrollView
  keeps its 380pt cap as the sole expanded-height owner; compact mode,
  filters, Details/Show less, and keyboard/Escape behavior are unchanged.
- The window has no explicit background owner: the MenuBarExtra
  `.window` style keeps its system material, and no `containerBackground`
  is applied because `ContainerBackgroundPlacement.window` is absent from
  the macOS 14 SDK (referencing it breaks the macOS 14 CI build). A
  second material would also compete with the system surface. Charts,
  metric cards, and text stay off custom glass, as before. No ScrollView
  gutter override was needed.

## 0.4.1

Adaptive system appearance for the menu-bar app. No change to token
math, source semantics, privacy boundaries, sync behavior, or pricing
behavior. macOS 14 stays the deployment target.

- The popover no longer forces dark: it follows the system appearance,
  so a normal light appearance renders clean, bright, and legible while
  dark remains fully supported. Content surfaces, text, dividers, and
  chart tracks use semantic SwiftUI colors; source colors (Codex green,
  OpenCode blue, Claude orange) and estimate-only labels are unchanged.
- Liquid Glass stays a restrained functional layer on macOS 26 and
  later (header actions, source/range chips, primary Details action)
  behind the existing compile/runtime gates, with the macOS 14 fallback.
  Charts, metric cards, and explanatory text stay on readable standard
  surfaces.
- Compact/expanded modes, keyboard focus, VoiceOver labels, Escape to
  collapse, Reduce Transparency and Increase Contrast handling, Settings,
  refresh/loading states, and OpenCode local/remote rows are unchanged.

## 0.4.0

Native Liquid Glass adoption for the menu-bar app. No change to token
math, source semantics, privacy boundaries, sync behavior, or pricing
behavior. macOS 14 stays the deployment target.

- Functional glass surfaces on macOS 26 and later: header actions use
  the system glass button style, source/range chips share one glass
  container with an interactive tinted effect for the active chip, and
  the primary Details action uses a restrained blue-tinted glass. Newer
  APIs are guarded with `#available`, centralized in one compatibility
  file, and fall back to the existing Material/system-color layout on
  macOS 14/15.
- The fallback stays legible with Reduce Transparency (glass off,
  opaque surfaces) and Increase Contrast (stronger control strokes).
  Charts, metric cards, and explanatory text stay on standard content
  surfaces; source colors (Codex green, OpenCode blue, Claude orange)
  and estimate-only labels are unchanged.
- Compact/expanded modes, keyboard focus, VoiceOver labels, Escape to
  collapse, Settings, refresh/loading states, and OpenCode local/remote
  rows are unchanged.

## 0.3.4

Focused dashboard default-range fix. No change to token math, source
semantics, privacy boundaries, sync behavior, or pricing behavior. All
range chips stay available.

- Initial dashboard range is now the rolling last 7 days (`7D`) instead of
  the narrow calendar-day `Today`, so the menu-bar popover opens on the
  recent week rather than reading empty most mornings. CLI default stays
  lifetime.
- Clearer empty/source-filter state: it now names that records may exist
  outside the selected range and offers the most useful one-tap wider
  range (last 30 days from Today/24H/7D, lifetime from 30D/Best) alongside
  the existing All-sources shortcut. Accessibility labels and the compact
  400pt layout are unchanged.

Release hygiene: unsigned and not notarized, as before; Gatekeeper
first-launch note still applies.

## 0.3.3

Focused dashboard readability pass for the menu-bar popover. No change
to token math, source semantics, privacy boundaries, sync behavior, or
pricing behavior. Compact-first dark layout and the gear-hidden Settings
surface are unchanged.

- Calmer header: Refresh and Settings only, with larger hit areas and a
  one-line view caption (`All · Today` style) naming the active source
  and range. Expand/collapse moved into the content flow where the eye
  already is.
- Easier-to-scan controls: larger source/range chips with stronger
  active states and VoiceOver selected-state traits; short section
  labels stay single-line at the 400pt width.
- Clearer status communication: the stale-cache line reads as a calm
  status pill, manual refreshes show an updating line plus the header
  spinner, and the empty and no-scope states pair an icon with focused
  retry shortcuts.
- Navigable Details: an explicit Details header with the active view
  plus Show less at the top, a second Show less at the bottom, carded
  notices with counts, and Escape to collapse.
- Accessibility labels, hints, and header traits improved across the
  dashboard; no new network calls, telemetry, accounts, provider auth,
  or prompt storage.

Release hygiene: unsigned and not notarized, as before; Gatekeeper
first-launch note still applies.

## 0.3.2

Patch release for the remote OpenCode snapshot sync. No behavior change
except the empty-snapshot handling below. No workflow change.

- Valid-but-empty remote snapshot protection: a sync pull that returns a
  valid empty snapshot (`[]`) while the local sync cache already holds
  records keeps the last good cache instead of wiping history. A genuine
  empty first sync (no prior synced records) is still accepted as empty.
- Sanitized retry notice: the kept-cache case reports one generic line
  (`Remote snapshot empty; kept previous data. Retry sync later.`) with
  no paths or host details. Re-run sync after the remote recovers
  (Sync Now button or CLI `--sync-now`).
- Legacy-cache coverage: the empty-snapshot guard also applies to the
  legacy fallback location when no cache exists at the primary path.
- Bounded cache reads: the prior-cache history check reuses the capped
  read path, so an oversized local cache is not fully buffered during
  an empty sync.
