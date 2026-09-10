import Foundation

/// One rendered usage section: a (preset, source) scope plus its stats.
///
/// All text produced from this type is privacy-safe by construction: it
/// carries only aggregated counts, model/source labels, and sanitized
/// warnings. It never carries file paths, prompt text, or message bodies.
public struct UsageSection: Codable, Hashable, Sendable {
    public var preset: DatePreset
    public var source: SourceFilter
    public var presetLabel: String
    public var stats: AggregatedStats
    /// Set only when `preset == .bestMonth` and a winning month exists.
    public var bestMonthKey: String?

    public init(preset: DatePreset, source: SourceFilter, stats: AggregatedStats, bestMonthKey: String? = nil) {
        self.preset = preset
        self.source = source
        self.presetLabel = ReportFormatter.presetLabel(for: preset)
        self.stats = stats
        self.bestMonthKey = bestMonthKey
    }
}

/// Privacy-safe terminal report builder. Pure and deterministic.
public enum ReportFormatter {
    // MARK: - Section construction

    /// Builds the stats section for one (preset, source) scope.
    /// `bestMonth` scopes resolve over the source-filtered lifetime set,
    /// mirroring `TokenBarApp` dashboard semantics.
    public static func section(
        records: [NormalizedUsage],
        source: SourceFilter,
        preset: DatePreset,
        now: Date,
        calendar: Calendar = .current
    ) -> UsageSection {
        if preset == .bestMonth {
            let lifetime = Aggregator.filter(records, source: source, preset: .lifetime, now: now, calendar: calendar)
            guard let best = Aggregator.bestMonth(lifetime, calendar: calendar) else {
                return UsageSection(preset: preset, source: source, stats: .empty)
            }
            return UsageSection(preset: preset, source: source, stats: best.stats, bestMonthKey: best.monthKey)
        }
        let scoped = Aggregator.filter(records, source: source, preset: preset, now: now, calendar: calendar)
        return UsageSection(preset: preset, source: source, stats: Aggregator.aggregate(scoped, calendar: calendar))
    }

    public static func presetLabel(for preset: DatePreset) -> String {
        switch preset {
        case .today: return "today"
        case .last24Hours: return "last 24h"
        case .last7Days: return "last 7d"
        case .last30Days: return "last 30d"
        case .bestMonth: return "best month"
        case .lifetime: return "lifetime"
        }
    }

    public static func sourceLabel(for source: SourceFilter) -> String {
        switch source {
        case .all: return "all"
        case .codex: return "codex"
        case .opencode: return "opencode"
        case .claude: return "claude"
        }
    }

    // MARK: - Warning sanitizing (no raw paths, no prompt text)

    /// Replaces absolute filesystem paths with generic location labels so
    /// terminal output never leaks usernames or directory layouts.
    public static func sanitizeWarning(_ warning: String) -> String {
        var result = warning
        // Known Store messages carry " at <absolute path>." — collapse them.
        if result.contains("Codex sessions not found") {
            return "Codex sessions not found (checked default location or TOKENBAR_CODEX_ROOT)."
        }
        if result.contains("OpenCode database not found") {
            return "OpenCode database not found (checked default location or TOKENBAR_OPENCODE_DB)."
        }
        if result.contains("Claude sessions not found") {
            return "Claude sessions not found (checked default location or TOKENBAR_CLAUDE_ROOT)."
        }
        // Generic fallback: redact tokens that look like absolute paths.
        // Keep the message deterministic: one fixed placeholder.
        let tokens = result.split(separator: " ", omittingEmptySubsequences: true)
        let redacted = tokens.map { token -> String in
            let word = String(token)
            let stripped = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;()[]\"'"))
            if stripped.hasPrefix("/") || stripped.hasPrefix("~") || stripped.contains("/.codex/") || stripped.contains("/opencode") {
                return "<path>"
            }
            return word
        }
        result = redacted.joined(separator: " ")
        return result
    }

    public static func sanitizeWarnings(_ warnings: [String]) -> [String] {
        warnings.map(sanitizeWarning)
    }

    // MARK: - Human-readable rendering

    private static func isoString(_ date: Date?) -> String {
        guard let date else { return "never" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func costString(_ usd: Double) -> String {
        String(format: "$%.4f", usd)
    }

    /// Renders one section. Deterministic field order; no paths, no prompts.
    public static func render(section: UsageSection, warnings: [String] = []) -> String {
        let stats = section.stats
        var lines: [String] = []
        lines.append("Token Bar -- \(section.presetLabel) / \(sourceLabel(for: section.source))")
        if section.preset == .bestMonth, let key = section.bestMonthKey {
            lines.append("Best month: \(key)")
        }
        lines.append("Total tokens: \(stats.totalTokens)")
        lines.append("Input tokens: \(stats.inputTokens)")
        lines.append("Output tokens: \(stats.outputTokens)")
        lines.append("Cached tokens: \(stats.cachedTokens) (subset of input)")
        lines.append("Reasoning tokens: \(stats.reasoningTokens) (subset of output)")
        lines.append("Requests: \(stats.requests)")
        lines.append("Sessions: \(stats.sessions)")
        lines.append("Estimated cost: \(costString(stats.estimatedCostUSD)) USD (estimate, static price table)")
        lines.append("Last updated: \(isoString(stats.lastUpdated))")
        if stats.bySource.isEmpty {
            lines.append("By source: none")
        } else {
            lines.append("By source:")
            for entry in stats.bySource {
                lines.append("  \(entry.key): \(entry.totalTokens) tokens, \(entry.requests) requests, \(costString(entry.estimatedCostUSD)) est.")
            }
        }
        if !stats.byModel.isEmpty {
            lines.append("By model (top 5):")
            for entry in stats.byModel.prefix(5) {
                lines.append("  \(entry.key): \(entry.totalTokens) tokens, \(entry.requests) requests, \(costString(entry.estimatedCostUSD)) est.")
            }
        }
        let clean = sanitizeWarnings(warnings)
        if !clean.isEmpty {
            lines.append("Warnings (\(clean.count)):")
            for warning in clean {
                lines.append("  - \(warning)")
            }
        }
        if stats.requests == 0 {
            lines.append("No usage records in this scope. Try --preset lifetime --source all.")
        }
        return lines.joined(separator: "\n")
    }

    /// Renders several sections (used by `--all-presets`), separated by a
    /// deterministic divider. Warnings print once at the end.
    public static func renderAll(sections: [UsageSection], warnings: [String] = []) -> String {
        var parts: [String] = []
        for (index, section) in sections.enumerated() {
            // Warnings attach to the final block only so output stays scannable.
            if index == sections.count - 1 {
                parts.append(render(section: section, warnings: warnings))
            } else {
                parts.append(render(section: section))
            }
        }
        return parts.joined(separator: "\n---\n")
    }

    // MARK: - JSON rendering

    public struct JSONReport: Codable, Hashable, Sendable {
        public var preset: String
        public var source: String
        public var bestMonth: String?
        public var totalTokens: Int
        public var inputTokens: Int
        public var outputTokens: Int
        public var cachedTokens: Int
        public var reasoningTokens: Int
        public var requests: Int
        public var sessions: Int
        public var estimatedCostUSD: Double
        public var lastUpdated: String?
        public var bySource: [BreakdownEntry]
        public var byModel: [BreakdownEntry]
        public var warnings: [String]
    }

    public static func jsonReports(sections: [UsageSection], warnings: [String]) -> [JSONReport] {
        let clean = sanitizeWarnings(warnings)
        return sections.map { section in
            JSONReport(
                preset: section.presetLabel,
                source: sourceLabel(for: section.source),
                bestMonth: section.bestMonthKey,
                totalTokens: section.stats.totalTokens,
                inputTokens: section.stats.inputTokens,
                outputTokens: section.stats.outputTokens,
                cachedTokens: section.stats.cachedTokens,
                reasoningTokens: section.stats.reasoningTokens,
                requests: section.stats.requests,
                sessions: section.stats.sessions,
                estimatedCostUSD: section.stats.estimatedCostUSD,
                lastUpdated: section.stats.lastUpdated.map { isoString($0) },
                bySource: section.stats.bySource,
                byModel: section.stats.byModel,
                warnings: clean
            )
        }
    }

    /// Deterministic JSON: sorted keys + pretty printed.
    public static func encodeJSON(sections: [UsageSection], warnings: [String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = jsonReports(sections: sections, warnings: warnings)
        let data = try encoder.encode(payload)
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
