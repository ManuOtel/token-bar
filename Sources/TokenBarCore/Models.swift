import Foundation

/// Origin of a normalized usage record.
public enum UsageSource: String, Codable, Hashable, Sendable, CaseIterable {
    case codex
    case opencode
}

/// Dashboard source filter.
public enum SourceFilter: String, Codable, Hashable, Sendable, CaseIterable {
    case all
    case codex
    case opencode

    public func matches(_ source: UsageSource) -> Bool {
        switch self {
        case .all: return true
        case .codex: return source == .codex
        case .opencode: return source == .opencode
        }
    }
}

/// Date presets with exact documented semantics (all upper bounds are `now` inclusive).
///
/// - today: local calendar day, [startOfDay(now), now]
/// - last24Hours: rolling window, [now - 24h, now]
/// - last7Days: rolling window, [now - 7*24h, now]
/// - last30Days: rolling window, [now - 30*24h, now]
/// - bestMonth: calendar month (local) with max total tokens over the filtered lifetime set
/// - lifetime: no date filtering
public enum DatePreset: String, Codable, Hashable, Sendable, CaseIterable {
    case today
    case last24Hours
    case last7Days
    case last30Days
    case bestMonth
    case lifetime
}

/// One normalized usage event from either adapter.
public struct NormalizedUsage: Codable, Hashable, Sendable {
    public var id: String
    public var source: UsageSource
    public var timestamp: Date
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedTokens: Int
    public var reasoningTokens: Int
    public var totalTokens: Int
    public var sessionId: String
    public var requestId: String

    public init(
        id: String,
        source: UsageSource,
        timestamp: Date,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cachedTokens: Int,
        reasoningTokens: Int,
        totalTokens: Int,
        sessionId: String,
        requestId: String
    ) {
        self.id = id
        self.source = source
        self.timestamp = timestamp
        self.model = model.isEmpty ? "unknown" : model
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cachedTokens = max(0, cachedTokens)
        self.reasoningTokens = max(0, reasoningTokens)
        // total is authoritative when positive, otherwise input + output.
        // cached/reasoning are subsets and never added on top.
        let computed = inputTokens + outputTokens
        self.totalTokens = totalTokens > 0 ? totalTokens : max(0, computed)
        self.sessionId = sessionId
        self.requestId = requestId
    }
}

/// Per-model or per-source rollup.
public struct BreakdownEntry: Codable, Hashable, Sendable {
    public var key: String
    public var totalTokens: Int
    public var requests: Int
    public var estimatedCostUSD: Double
}

/// One calendar-day bucket for the trend chart.
public struct DailyBucket: Codable, Hashable, Sendable {
    public var dayStart: Date
    public var dayLabel: String // yyyy-MM-dd local
    public var totalTokens: Int
    public var requests: Int
}

/// Aggregated stats for the current filter/preset scope.
public struct AggregatedStats: Codable, Hashable, Sendable {
    public var totalTokens: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedTokens: Int
    public var reasoningTokens: Int
    public var requests: Int
    public var sessions: Int
    public var estimatedCostUSD: Double
    public var lastUpdated: Date?
    public var byModel: [BreakdownEntry]
    public var bySource: [BreakdownEntry]
    public var dailyTrend: [DailyBucket]

    public static var empty: AggregatedStats {
        AggregatedStats(
            totalTokens: 0, inputTokens: 0, outputTokens: 0,
            cachedTokens: 0, reasoningTokens: 0,
            requests: 0, sessions: 0, estimatedCostUSD: 0,
            lastUpdated: nil, byModel: [], bySource: [], dailyTrend: []
        )
    }
}

/// Best calendar month result.
public struct BestMonth: Codable, Hashable, Sendable {
    public var monthKey: String // yyyy-MM local
    public var stats: AggregatedStats
}

/// Report from a load pass: records plus malformed-line accounting.
public struct LoadReport: Codable, Hashable, Sendable {
    public var records: [NormalizedUsage]
    public var skippedCodexLines: Int
    public var skippedOpenCodeRows: Int
    public var warnings: [String]
}

public enum StoreError: Error, Sendable {
    case missingRoot(String)
    case sqliteUnavailable
    case sqliteOpenFailed(String)
}
