# Changelog

Public release notes. Costs are estimates only, never a bill.

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
