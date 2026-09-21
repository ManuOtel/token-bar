# Pull request

Delete the sections that do not apply. Product behavior changes need
tests; docs-only changes need a clean docs gate. Full lifecycle:
`docs/RELEASE_PROCESS.md`. Per-release gate: `RELEASE_CHECKLIST.md`.

## What kind of PR is this?

- [ ] Feature/fix PR (one scoped change; merges to `main`; never tags or releases)
- [ ] Release PR (`VERSION` plus `CHANGELOG.md` plus synchronized public release markers in `site/index.html` only; no product or process code, no unrelated docs, no assets unless the site contract later requires them; site sync required because `test-release.sh`/`test-site.sh` enforce VERSION freshness)
- [ ] Docs-only/process-only PR (no `VERSION` bump, no release)

## Scope and acceptance criteria

- Scope (what changes / what explicitly does not):
- Acceptance criteria (observable outcome + which checks prove it):

## Worker branch and worktree

- [ ] Branched from current `origin/main`, worked in a separate worktree
- [ ] Narrow scope: one concern, no mixed product/process/release changes
- [ ] Fixtures are synthetic under `Fixtures/` only (no real usage data)

## Tests and checks

- [ ] `git diff --check` clean
- [ ] `./scripts/check-privacy.sh` passes
- [ ] `PYTHONDONTWRITEBYTECODE=1 python3 -B scripts/verify_logic.py` passes
- [ ] `bash -n` / `sh -n` clean on touched scripts
- [ ] Relevant contract scripts pass (`test-release.sh`, `test-site.sh`, `test-versioning.sh`)
- [ ] Mac source of truth: `swift build` / `swift test` green (or N/A with reason)

## Independent review

- [ ] Independent review requested; findings addressed in this branch
- [ ] Merge head is exactly the reviewed, CI-green head SHA

## Version, changelog, release readiness (release PRs only)

- [ ] `VERSION` bump follows SemVer (patch/minor/major); `CHANGELOG.md`
      updated in the same PR with the estimate disclaimer on dollar figures
- [ ] Docs-only change: confirms no `VERSION` bump and no release
- [ ] Post-merge plan stated: verify `main` HEAD, push exact `v<VERSION>`
      tag, confirm tag workflow green, verify assets/URLs before install

## Personal-data safety

- [ ] No real usage databases, session logs, snapshots, SSH config,
      credentials, or personal paths read, printed, staged, or committed
- [ ] Examples use generic placeholders (`user@server.example`,
      `/path/to/opencode.db`)
