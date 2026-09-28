import Foundation

/// Read-only per-source coverage readout (M13 Source Health and Coverage).
///
/// Pure derivation over the already-loaded `NormalizedUsage` set plus the
/// current `LoadReport` warnings/counters: no file I/O, no network, no
/// subprocess, no persistent state. `TokenBarStore.load` stays
/// file-reads-only; health is derived after source and date filtering in
/// the Aggregator / `DashboardSnapshot` layer.
///
/// Row scope is cross-source diagnostics: Codex, OpenCode (one sub-row
/// per exact sanitized origin label), and Claude rows render regardless
/// of the selected source chip. The selected date range still scopes each
/// row's current-range contribution; last-observed timestamps are lifetime
/// maxima over all already-loaded records, independent of source and
/// range selection. For Best, the contribution window is
/// `DashboardSnapshot.bestMonthKey` (the winning month selected under the
/// current source filter; a nil key means zero contributions).
///
/// Warning matching uses ONLY the allow-listed sanitized categories in
/// `classify`, applied after `ReportFormatter.sanitizeWarnings`. Raw
/// `Store.load` strings with absolute paths are never matched, and
/// arbitrary warning prose never alters health state (unknown strings
/// stay sanitized notices only).
public enum SourceHealthState: String, Codable, Hashable, Sendable, CaseIterable {
    case covered
    case zeroInRange
    case missing
    case unreadable
    case partial
    case noUsageObserved

    /// Dashboard label. Stable strings, no paths, no counts.
    public var label: String {
        switch self {
        case .covered: return "Covered"
        case .zeroInRange: return "Zero in range"
        case .missing: return "Missing"
        case .unreadable: return "Unreadable"
        case .partial: return "Partial"
        case .noUsageObserved: return "No usage observed"
        }
    }

    /// Compact-hint membership: these states mean the provider needs
    /// attention. `zeroInRange` and `noUsageObserved` are valid
    /// readouts, not attention states.
    var needsAttention: Bool {
        switch self {
        case .missing, .unreadable, .partial: return true
        case .covered, .zeroInRange, .noUsageObserved: return false
        }
    }
}

/// Sync freshness for the generic Remote inputs row only (section 5).
/// Never presented as belonging to a custom origin, and never derived
/// per-input: there are no per-input scan timestamps.
public enum SourceHealthSyncFreshness: Hashable, Sendable {
    case disabled
    case neverSynced
    case fresh
    case stale
    case failedKeptCache(message: String)

    /// Dashboard label. The failed message reuses the existing sanitized
    /// sync strings, never raw errors or paths.
    public var label: String {
        switch self {
        case .disabled: return "Sync off"
        case .neverSynced: return "Never synced"
        case .fresh: return "Synced"
        case .stale: return "Stale"
        case .failedKeptCache: return "Last good pull kept"
        }
    }

    /// Hint membership: enabled-sync never-synced/stale/failed-kept-cache
    /// states trigger the compact hint alongside row attention states.
    /// Never-synced is distinct and never classified as stale.
    var needsAttention: Bool {
        switch self {
        case .neverSynced, .stale, .failedKeptCache: return true
        case .disabled, .fresh: return false
        }
    }
}

/// Evaluated sync state behind the generic Remote inputs row.
public struct SourceHealthRemoteSync: Hashable, Sendable {
    public var enabled: Bool
    public var freshness: SourceHealthSyncFreshness
    public var lastSuccessAt: Date?
    /// Sanitized one-liner from `OpenCodeSyncStatus`, if any.
    public var lastError: String?

    public init(
        enabled: Bool,
        freshness: SourceHealthSyncFreshness,
        lastSuccessAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.enabled = enabled
        self.freshness = freshness
        self.lastSuccessAt = lastSuccessAt
        self.lastError = lastError
    }

    /// Pure evaluation from the existing `OpenCodeSyncStatus`
    /// (`lastSuccessAt`, `lastAttemptAt`, sanitized `lastError`) with the
    /// configured interval and timeout. No new sync metadata.
    public static func evaluate(
        config: OpenCodeSyncConfig?,
        status: OpenCodeSyncStatus?,
        now: Date
    ) -> SourceHealthRemoteSync {
        guard let config, config.enabled else {
            // Disabled sync renders "Sync off" with no error: a stale
            // persisted lastError from a previously-enabled sync must not
            // propagate into health state.
            return SourceHealthRemoteSync(
                enabled: false, freshness: .disabled,
                lastSuccessAt: status?.lastSuccessAt, lastError: nil)
        }
        guard let lastSuccess = status?.lastSuccessAt else {
            return SourceHealthRemoteSync(
                enabled: true, freshness: .neverSynced,
                lastSuccessAt: nil, lastError: status?.lastError)
        }
        if let error = status?.lastError, !error.isEmpty {
            return SourceHealthRemoteSync(
                enabled: true, freshness: .failedKeptCache(message: error),
                lastSuccessAt: lastSuccess, lastError: error)
        }
        let window = Double(config.pollIntervalSeconds + config.timeoutSeconds)
        if now.timeIntervalSince(lastSuccess) > window {
            return SourceHealthRemoteSync(
                enabled: true, freshness: .stale,
                lastSuccessAt: lastSuccess, lastError: status?.lastError)
        }
        return SourceHealthRemoteSync(
            enabled: true, freshness: .fresh,
            lastSuccessAt: lastSuccess, lastError: nil)
    }
}

/// One health row: a provider group (Codex, one OpenCode origin, Claude)
/// or the generic Remote inputs diagnostic.
public struct SourceHealthRow: Hashable, Sendable {
    public var provider: UsageSource
    /// Display title: "Codex", "Claude", "OpenCode - <origin>", or
    /// "Remote inputs". Origin labels are sanitized allowlist values only.
    public var title: String
    /// Exact sanitized OpenCode origin behind this row; nil for
    /// Codex/Claude/Remote-inputs rows.
    public var origin: String?
    /// True only for the generic Remote inputs diagnostic row.
    public var isRemoteInputs: Bool
    public var state: SourceHealthState
    /// Lifetime maximum over all already-loaded records for the group,
    /// independent of source and range selection. Nil when the group has
    /// no lifetime records (the label renders without a timestamp, never
    /// a fabricated value).
    public var lastObserved: Date?
    /// Current-range contribution: record count plus token sum under the
    /// dashboard temporal preset (Best uses `bestMonthKey`).
    public var rangeRecords: Int
    public var rangeTokens: Int
    /// Sync freshness; set only on the generic Remote inputs row.
    public var sync: SourceHealthRemoteSync?

    public init(
        provider: UsageSource,
        title: String,
        origin: String? = nil,
        isRemoteInputs: Bool = false,
        state: SourceHealthState,
        lastObserved: Date? = nil,
        rangeRecords: Int = 0,
        rangeTokens: Int = 0,
        sync: SourceHealthRemoteSync? = nil
    ) {
        self.provider = provider
        self.title = title
        self.origin = origin
        self.isRemoteInputs = isRemoteInputs
        self.state = state
        self.lastObserved = lastObserved
        self.rangeRecords = rangeRecords
        self.rangeTokens = rangeTokens
        self.sync = sync
    }
}

/// Derived health for one dashboard scope.
public struct SourceHealthReport: Hashable, Sendable {
    /// Fixed provider order: Codex, OpenCode (origin sub-rows in
    /// lifetime-tokens desc, key asc, then the conditional Remote inputs
    /// row), Claude.
    public var rows: [SourceHealthRow]
    /// Unique providers needing attention (Codex, OpenCode, Claude;
    /// OpenCode local and remote-input issues count once).
    public var providersNeedingAttention: Int
    /// One-line compact footer hint, nil when every provider is covered.
    /// Counted at provider level across all displayed sources,
    /// independent of the selected source chip.
    public var compactHint: String?

    public init(
        rows: [SourceHealthRow] = [],
        providersNeedingAttention: Int = 0,
        compactHint: String? = nil
    ) {
        self.rows = rows
        self.providersNeedingAttention = providersNeedingAttention
        self.compactHint = compactHint
    }
}

/// Pure health derivation (section 5 decision table).
public enum SourceHealth {
    // MARK: - Allow-listed sanitized warning categories

    // Exact sanitized strings only (post-`sanitizeWarnings`). Raw Store
    // strings with absolute paths must never be matched here; they are
    // sanitized by the caller before classification.
    static let codexNotFound =
        "Codex sessions not found (checked default location or TOKENBAR_CODEX_ROOT)."
    static let claudeNotFound =
        "Claude sessions not found (checked default location or TOKENBAR_CLAUDE_ROOT)."
    static let opencodeDBNotFound =
        "OpenCode database not found (checked default location or TOKENBAR_OPENCODE_DB)."
    static let opencodeDBUnreadable =
        "OpenCode database unreadable; others still load."
    static let opencodeDBNoSQLite =
        "OpenCode database present but SQLite module unavailable in this build."
    static let opencodeExtraNotFound =
        "OpenCode extra database not found (checked TOKENBAR_OPENCODE_DB_EXTRA)."
    static let opencodeExtraNoSQLite =
        "OpenCode extra database skipped: SQLite module unavailable in this build."
    static let opencodeExtraUnreadable =
        "OpenCode extra database unreadable; others still load."
    static let opencodeSnapshotNotFound =
        "OpenCode usage snapshot not found (checked TOKENBAR_OPENCODE_USAGE_JSON)."
    static let opencodeSnapshotUnreadable =
        "OpenCode snapshot unreadable; others still load."
    static let opencodeSyncCacheUnreadable =
        "OpenCode remote sync cache unreadable; others still load."

    enum WarningTarget {
        case codex
        case opencodeLocal
        case remoteInputs
        case claude
    }

    enum IssueKind {
        case missing
        case unreadable
    }

    /// Maps one sanitized warning to its affected group and issue class.
    /// Skipped-row shapes, the extra-fields notice, and every unknown
    /// string return nil (notice only, never a state change). Skipped
    /// handling reads the explicit `LoadReport` counters, never prose.
    static func classify(_ sanitized: String) -> (WarningTarget, IssueKind)? {
        switch sanitized {
        case codexNotFound: return (.codex, .missing)
        case claudeNotFound: return (.claude, .missing)
        case opencodeDBNotFound: return (.opencodeLocal, .missing)
        case opencodeDBUnreadable: return (.opencodeLocal, .unreadable)
        case opencodeDBNoSQLite: return (.opencodeLocal, .unreadable)
        case opencodeExtraNotFound: return (.remoteInputs, .missing)
        case opencodeExtraNoSQLite: return (.remoteInputs, .unreadable)
        case opencodeExtraUnreadable: return (.remoteInputs, .unreadable)
        case opencodeSnapshotNotFound: return (.remoteInputs, .missing)
        case opencodeSnapshotUnreadable: return (.remoteInputs, .unreadable)
        case opencodeSyncCacheUnreadable: return (.remoteInputs, .unreadable)
        default: return nil
        }
    }

    // MARK: - State resolution

    /// Resolves one group's state from its lifetime/range counts, mapped
    /// missing/unreadable flags, and provider skipped counter.
    /// Precedence: skipped-partial first, then partial-with-records, then
    /// covered, then zero-in-range, then unreadable over missing with no
    /// records, else no-usage-observed.
    static func resolveState(
        lifetimeCount: Int,
        rangeCount: Int,
        hasMissing: Bool,
        hasUnreadable: Bool,
        skippedCount: Int
    ) -> SourceHealthState {
        if skippedCount > 0 { return .partial }
        if lifetimeCount > 0, hasMissing || hasUnreadable { return .partial }
        if lifetimeCount > 0, rangeCount > 0 { return .covered }
        if lifetimeCount > 0 { return .zeroInRange }
        if hasUnreadable { return .unreadable }
        if hasMissing { return .missing }
        return .noUsageObserved
    }

    // MARK: - Derivation

    /// Derives the full report in one linear pass over the already-loaded
    /// records. `warnings` are raw `LoadReport` strings (sanitized here
    /// before matching). `bestMonthKey` scopes Best contributions to the
    /// winning month (nil key means zero contributions). Sync freshness
    /// attaches to the generic Remote inputs row only.
    public static func derive(
        records: [NormalizedUsage],
        warnings: [String] = [],
        skippedCodexLines: Int = 0,
        skippedOpenCodeRows: Int = 0,
        skippedClaudeLines: Int = 0,
        preset: DatePreset = .lifetime,
        bestMonthKey: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current,
        syncConfig: OpenCodeSyncConfig? = nil,
        syncStatus: OpenCodeSyncStatus? = nil
    ) -> SourceHealthReport {
        var codexMissing = false, codexUnreadable = false
        var localMissing = false, localUnreadable = false
        var remoteMissing = false, remoteUnreadable = false
        var claudeMissing = false, claudeUnreadable = false
        for warning in ReportFormatter.sanitizeWarnings(warnings) {
            guard let (target, kind) = classify(warning) else { continue }
            switch (target, kind) {
            case (.codex, .missing): codexMissing = true
            case (.codex, .unreadable): codexUnreadable = true
            case (.opencodeLocal, .missing): localMissing = true
            case (.opencodeLocal, .unreadable): localUnreadable = true
            case (.remoteInputs, .missing): remoteMissing = true
            case (.remoteInputs, .unreadable): remoteUnreadable = true
            case (.claude, .missing): claudeMissing = true
            case (.claude, .unreadable): claudeUnreadable = true
            }
        }

        struct Accumulator {
            var lifetimeCount = 0
            var lifetimeTokens = 0
            var lifetimeMax: Date?
            var rangeCount = 0
            var rangeTokens = 0
        }
        var codex = Accumulator()
        var claude = Accumulator()
        var origins: [String: Accumulator] = [:]

        let inRange: (NormalizedUsage) -> Bool = { record in
            if preset == .bestMonth {
                guard let key = bestMonthKey else { return false }
                return Aggregator.monthKey(for: record.timestamp, calendar: calendar) == key
            }
            return DashboardSnapshot.dateMatches(
                record.timestamp, preset: preset, now: now, calendar: calendar)
        }

        for record in records {
            let hit = inRange(record)
            switch record.source {
            case .codex:
                codex.lifetimeCount += 1
                codex.lifetimeTokens += record.totalTokens
                let ts = record.timestamp
                if codex.lifetimeMax == nil || ts > codex.lifetimeMax! {
                    codex.lifetimeMax = ts
                }
                if hit {
                    codex.rangeCount += 1
                    codex.rangeTokens += record.totalTokens
                }
            case .claude:
                claude.lifetimeCount += 1
                claude.lifetimeTokens += record.totalTokens
                let ts = record.timestamp
                if claude.lifetimeMax == nil || ts > claude.lifetimeMax! {
                    claude.lifetimeMax = ts
                }
                if hit {
                    claude.rangeCount += 1
                    claude.rangeTokens += record.totalTokens
                }
            case .opencode:
                let origin = OpenCodeStore.sanitizeOriginLabel(
                    record.origin, fallback: OpenCodeSync.defaultOrigin)
                var acc = origins[origin] ?? Accumulator()
                acc.lifetimeCount += 1
                acc.lifetimeTokens += record.totalTokens
                let ts = record.timestamp
                if acc.lifetimeMax == nil || ts > acc.lifetimeMax! {
                    acc.lifetimeMax = ts
                }
                if hit {
                    acc.rangeCount += 1
                    acc.rangeTokens += record.totalTokens
                }
                origins[origin] = acc
            }
        }

        var rows: [SourceHealthRow] = []
        rows.append(SourceHealthRow(
            provider: .codex, title: "Codex",
            state: resolveState(
                lifetimeCount: codex.lifetimeCount, rangeCount: codex.rangeCount,
                hasMissing: codexMissing, hasUnreadable: codexUnreadable,
                skippedCount: skippedCodexLines),
            lastObserved: codex.lifetimeMax,
            rangeRecords: codex.rangeCount, rangeTokens: codex.rangeTokens))

        // OpenCode origin sub-rows: lifetime tokens desc, key asc (same
        // order contract as the `byOrigin` breakdown). Remote-input
        // warnings never map to a custom origin; only local default-DB
        // issues map to the local row. The provider skipped counter
        // degrades otherwise-covered/zero origin rows to partial without
        // naming an origin as the cause.
        for (origin, acc) in origins.sorted(by: { left, right in
            if left.value.lifetimeTokens != right.value.lifetimeTokens {
                return left.value.lifetimeTokens > right.value.lifetimeTokens
            }
            return left.key < right.key
        }) {
            let isLocal = origin == "local"
            rows.append(SourceHealthRow(
                provider: .opencode, title: "OpenCode - \(origin)", origin: origin,
                state: resolveState(
                    lifetimeCount: acc.lifetimeCount, rangeCount: acc.rangeCount,
                    hasMissing: isLocal && localMissing,
                    hasUnreadable: isLocal && localUnreadable,
                    skippedCount: skippedOpenCodeRows),
                lastObserved: acc.lifetimeMax,
                rangeRecords: acc.rangeCount, rangeTokens: acc.rangeTokens))
        }
        if origins.isEmpty {
            // Single local placeholder row; names no presence. Provider
            // skipped rows surface here at provider level only.
            rows.append(SourceHealthRow(
                provider: .opencode, title: "OpenCode - local", origin: "local",
                state: resolveState(
                    lifetimeCount: 0, rangeCount: 0,
                    hasMissing: localMissing, hasUnreadable: localUnreadable,
                    skippedCount: skippedOpenCodeRows)))
        } else if (localMissing || localUnreadable) && origins["local"] == nil {
            // Remote-only origins: a local default-DB warning would
            // otherwise drop with no local row to map to. Insert a
            // zero-count local row so the missing/unreadable state stays
            // visible alongside the remote origin rows.
            rows.append(SourceHealthRow(
                provider: .opencode, title: "OpenCode - local", origin: "local",
                state: resolveState(
                    lifetimeCount: 0, rangeCount: 0,
                    hasMissing: localMissing, hasUnreadable: localUnreadable,
                    skippedCount: skippedOpenCodeRows)))
        }

        // Generic Remote inputs diagnostic: appears only when a
        // remote-input warning maps to it or sync is enabled. Never under
        // a guessed custom label. Sync freshness renders here only.
        let sync = SourceHealthRemoteSync.evaluate(
            config: syncConfig, status: syncStatus, now: now)
        let showsRemote = remoteMissing || remoteUnreadable || (syncConfig?.enabled == true)
        if showsRemote {
            rows.append(SourceHealthRow(
                provider: .opencode, title: "Remote inputs", isRemoteInputs: true,
                state: resolveState(
                    lifetimeCount: 0, rangeCount: 0,
                    hasMissing: remoteMissing, hasUnreadable: remoteUnreadable,
                    skippedCount: 0),
                rangeRecords: 0, rangeTokens: 0, sync: sync))
        }

        rows.append(SourceHealthRow(
            provider: .claude, title: "Claude",
            state: resolveState(
                lifetimeCount: claude.lifetimeCount, rangeCount: claude.rangeCount,
                hasMissing: claudeMissing, hasUnreadable: claudeUnreadable,
                skippedCount: skippedClaudeLines),
            lastObserved: claude.lifetimeMax,
            rangeRecords: claude.rangeCount, rangeTokens: claude.rangeTokens))

        // Compact hint: unique providers needing attention. OpenCode
        // local and remote-input issues count once.
        var codexAttention = false, opencodeAttention = false, claudeAttention = false
        for row in rows {
            switch row.provider {
            case .codex:
                codexAttention = codexAttention || row.state.needsAttention
            case .opencode:
                let remoteSyncAttention = row.isRemoteInputs && (row.sync?.freshness.needsAttention == true)
                opencodeAttention = opencodeAttention || row.state.needsAttention || remoteSyncAttention
            case .claude:
                claudeAttention = claudeAttention || row.state.needsAttention
            }
        }
        let providers = [codexAttention, opencodeAttention, claudeAttention].filter { $0 }.count
        let hint: String? = providers == 0 ? nil
            : providers == 1 ? "1 source needs attention - see Details"
            : "\(providers) sources need attention - see Details"
        return SourceHealthReport(
            rows: rows, providersNeedingAttention: providers, compactHint: hint)
    }
}
