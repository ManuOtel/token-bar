# Changelog

Public release notes. Costs are estimates only, never a bill.

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
