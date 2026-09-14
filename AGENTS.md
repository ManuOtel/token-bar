# AGENTS.md - Token Bar

Authoritative worker instructions for this repository. Short on purpose. Follow this file first; README, ARCHITECTURE, and `docs/` carry details.

## Project description

Token Bar is a macOS 14+ SwiftUI MenuBarExtra utility aggregating local Codex, OpenCode, and Claude Code usage. It reads local history files read-only, plus offline multi-machine OpenCode file/snapshot merge, plus one strictly opt-in public OpenRouter pricing GET. No accounts, no provider APIs, no cookies.

Costs are estimates only, never a bill. Subscription use is not an API invoice.

## Current product scope

In scope: local token totals, source/range filters, per-source and per-model breakdowns, daily trend, best-month, sanitized warnings, startup cache, launch-at-login toggle, opt-in pricing refresh with offline static fallback.

Out of scope: live sync, cloud dashboard, provider auth, prompt/message storage, auto-updater, Windows/Linux app target, new agent sources without a dedicated proposal plus fixtures plus tests plus docs.

Do not invent integrations, pricing sources, or product scope.

## Repository layout and architecture

```
Package.swift
Sources/TokenBarCore/   # pure logic, Foundation only
  Models, CodexParser, ClaudeParser, OpenCodeStore, Aggregator,
  Pricing, PricingCatalog, PricingService, Store, StartupReportCache, Report
Sources/TokenBarCLI/    # thin --preset/--source/--all-presets/--json/--refresh-pricing front end
Sources/TokenBarApp/    # SwiftUI menu-bar shell (macOS 14+)
  TokenBarApp, DashboardView, SettingsView, PricingController, LaunchAtLoginController
Tests/TokenBarCoreTests/  # parsers, aggregator, report, pricing catalog
Fixtures/               # synthetic samples only
scripts/                # show-usage, run-token-bar, build-app, package-release,
                        # export-opencode-usage, verify_logic
docs/                   # PRICING, MACOS_PACKAGING, PERFORMANCE
```

Rules: all semantics live in `TokenBarCore`. App and CLI are thin renderers. `PricingService.swift` is the only file allowed to touch the network. See ARCHITECTURE.md for the data flow.

## Current UI behavior

Dashboard popover is 400pt, dark, compact first, no scroll. Compact shows hero total, estimated cost, Source chips (All/Codex/OpenCode/Claude), Range chips (Today/24H/7D/30D/Best/All), composition ring, source bar, 14-day mini trend, Details action, and an updated/notices footer.

Expanded Details is scrollable: metric cards, composition card, source rows with OpenCode local/homeserver sub-lines, top-5 models, full trend, notices, Show less to collapse.

Launch-at-login and pricing controls are behind Settings: the gear button in the dashboard header opens the Settings popover (`SettingsView`). Usage filters and details remain in the dashboard, never in Settings.

## Data sources and environment overrides

| Source | Default | Override |
|---|---|---|
| Codex | `~/.codex/sessions/**/*.jsonl` | `TOKENBAR_CODEX_ROOT` |
| OpenCode | `~/.local/share/opencode/opencode.db` | `TOKENBAR_OPENCODE_DB` |
| OpenCode extras | extra read-only DB copies | `TOKENBAR_OPENCODE_DB_EXTRA` |
| OpenCode snapshot | sanitized token-only JSON | `TOKENBAR_OPENCODE_USAGE_JSON` |
| Claude | `~/.claude/projects/**/*.jsonl` | `TOKENBAR_CLAUDE_ROOT` |
| Pricing cache | `~/Library/Application Support/TokenBar/pricing-catalog.json` | `TOKENBAR_PRICING_CACHE` |

Multi-machine merge is offline file copy only. The user copies the snapshot; the app never fetches it. Extra paths are comma- or newline-separated; missing extras warn only. Export with `scripts/export-opencode-usage.py`. Full semantics in README.

## Privacy boundary

Usage data, prompts, message bodies, paths, credentials, cookies, and subscription sessions never leave the machine. All adapters open files read-only. Warnings and CLI/JSON output are sanitized to generic labels, never absolute paths.

The only network call is the strictly opt-in pricing refresh: one `GET https://openrouter.ai/api/v1/models`, no body, no query, no auth/cookie headers, no usage data sent. Triggered only by the Settings Update pricing button or CLI `--refresh-pricing`. Default runs are fully offline.

## Development and test commands

Mac (source of truth, Xcode 15+, macOS 14 SDK):

```sh
swift build
swift test
swift run TokenBarCLI --preset lifetime --source all
swift run TokenBarApp
./scripts/show-usage.sh --preset lifetime --source all
./scripts/run-token-bar.sh
```

Linux (this worker host has no Swift toolchain):

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B scripts/verify_logic.py
bash -n scripts/*.sh && sh -n scripts/*.sh
git diff --check
```

## CI source of truth

`.github/workflows/ci.yml` runs on `main` and PRs: macOS 14 job (`swift build` + `swift test`), Linux job (`verify_logic.py` plus `bash -n`/`sh -n` shell syntax), privacy-gate job (URLSession confined to `PricingService.swift`, catalog hosts allowlisted to `openrouter.ai`, no Cookie/Authorization headers). macOS `swift test` is the source of truth; the Python script is a mirror only.

## Release and package commands

```sh
./scripts/build-app.sh --version 0.1.0            # dist/TokenBar.app
./scripts/package-release.sh --version 0.1.0 --format zip
(cd dist && shasum -a 256 -c TokenBar-0.1.0-macos.zip.sha256)
```

Sign, notarize, and staple before packaging. Full path: `docs/MACOS_PACKAGING.md`, `RELEASE_CHECKLIST.md`.

## Worker contribution rules

1. Inspect current `origin/main` before starting (`git fetch origin`, `git log`, read the files you will touch). Use a separate branch and worktree, keep scope narrow.
2. Do not rewrite PLAN.md history. Do not change source, tests, CI, pricing, or behavior on docs tasks. Do not add boilerplate or unsupported claims. Use clear technical language.
3. Add synthetic fixtures only under `Fixtures/`. Update tests when touching `TokenBarCore` semantics. Conventional commits (`feat:`, `fix:`, `docs:`, `test:`, `chore:`).
4. Never read, print, stage, commit, or expose local usage databases, session logs, snapshot files containing real user data, or credentials. Never touch `~/.config/tokenbar/opencode-homeserver.json` or any real usage snapshot. Keep examples synthetic.
5. Before merge: run the relevant tests plus the full docs-appropriate checks (`verify_logic.py`, `bash -n`/`sh -n`, `git diff --check`, privacy scan), self-review the final diff for stale wording, secrets, paths, and scope, require independent review, and require exact green CI.
