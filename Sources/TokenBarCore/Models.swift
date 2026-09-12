import Foundation

/// Origin of a normalized usage record.
public enum UsageSource: String, Codable, Hashable, Sendable, CaseIterable {
    case codex
    case opencode
    case claude
}

/// Dashboard source filter.
public enum SourceFilter: String, Codable, Hashable, Sendable, CaseIterable {
    case all
    case codex
    case opencode
    case claude

    public func matches(_ source: UsageSource) -> Bool {
        switch self {
        case .all: return true
        case .codex: return source == .codex
        case .opencode: return source == .opencode
        case .claude: return source == .claude
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
///
/// `origin` is the host label for OpenCode multi-machine merge: `"local"`
/// for the Mac database, `"homeserver"` (or a custom label from a sanitized
/// snapshot) for imported rows. Codex/Claude rows are always `"local"`.
/// Old encoded records without the key decode with the `"local"` default so
/// prior reports keep loading. `source` stays `.opencode` for both local
/// and homeserver OpenCode rows; origin never changes source routing.
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
    public var origin: String

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
        requestId: String,
        origin: String = "local"
    ) {
        self.id = id
        self.source = source
        self.timestamp = timestamp
        self.model = model.isEmpty ? "unknown" : model
        let trimmedOrigin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        self.origin = trimmedOrigin.isEmpty ? "local" : trimmedOrigin
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        // Cached is a subset of input by construction: clamp adversarial
        // counts (e.g. negative input beside positive cached) so the
        // invariant holds for every record. No-op for real provider data,
        // where parsers already fold cache into input.
        self.cachedTokens = min(max(0, cachedTokens), self.inputTokens)
        self.reasoningTokens = max(0, reasoningTokens)
        // total is authoritative when positive, otherwise input + output.
        // cached/reasoning are subsets and never added on top.
        let clampedInput = max(0, inputTokens)
        let clampedOutput = max(0, outputTokens)
        let computed = clampedInput + clampedOutput
        self.totalTokens = totalTokens > 0 ? totalTokens : max(0, computed)
        self.sessionId = sessionId
        self.requestId = requestId
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case timestamp
        case model
        case inputTokens
        case outputTokens
        case cachedTokens
        case reasoningTokens
        case totalTokens
        case sessionId
        case requestId
        case origin
    }

    /// Decodes records written before `origin` existed: the key defaults to
    /// `"local"` instead of failing. Encoding always writes the key.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        source = try container.decode(UsageSource.self, forKey: .source)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        let rawModel = try container.decode(String.self, forKey: .model)
        model = rawModel.isEmpty ? "unknown" : rawModel
        let rawInput = try container.decode(Int.self, forKey: .inputTokens)
        let rawOutput = try container.decode(Int.self, forKey: .outputTokens)
        let rawCached = try container.decode(Int.self, forKey: .cachedTokens)
        let rawReasoning = try container.decode(Int.self, forKey: .reasoningTokens)
        let rawTotal = try container.decode(Int.self, forKey: .totalTokens)
        inputTokens = max(0, rawInput)
        outputTokens = max(0, rawOutput)
        cachedTokens = min(max(0, rawCached), inputTokens)
        reasoningTokens = max(0, rawReasoning)
        let computed = inputTokens + outputTokens
        totalTokens = rawTotal > 0 ? rawTotal : max(0, computed)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        requestId = try container.decode(String.self, forKey: .requestId)
        let rawOrigin = try container.decodeIfPresent(String.self, forKey: .origin) ?? "local"
        let trimmed = rawOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        origin = trimmed.isEmpty ? "local" : trimmed
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
///
/// `byOrigin` groups by `"source/origin"` (for example `"opencode/local"`,
/// `"opencode/homeserver"`, `"codex/local"`), tokens desc then key asc.
/// Single-origin scopes carry one entry; multi-origin scopes carry one per
/// present pair. Old payloads without the key decode with an empty list.
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
    public var byOrigin: [BreakdownEntry]
    public var dailyTrend: [DailyBucket]

    public static var empty: AggregatedStats {
        AggregatedStats(
            totalTokens: 0, inputTokens: 0, outputTokens: 0,
            cachedTokens: 0, reasoningTokens: 0,
            requests: 0, sessions: 0, estimatedCostUSD: 0,
            lastUpdated: nil, byModel: [], bySource: [], byOrigin: [], dailyTrend: []
        )
    }

    private enum CodingKeys: String, CodingKey {
        case totalTokens
        case inputTokens
        case outputTokens
        case cachedTokens
        case reasoningTokens
        case requests
        case sessions
        case estimatedCostUSD
        case lastUpdated
        case byModel
        case bySource
        case byOrigin
        case dailyTrend
    }

    public init(
        totalTokens: Int, inputTokens: Int, outputTokens: Int,
        cachedTokens: Int, reasoningTokens: Int,
        requests: Int, sessions: Int, estimatedCostUSD: Double,
        lastUpdated: Date?, byModel: [BreakdownEntry], bySource: [BreakdownEntry],
        byOrigin: [BreakdownEntry] = [], dailyTrend: [DailyBucket]
    ) {
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.reasoningTokens = reasoningTokens
        self.requests = requests
        self.sessions = sessions
        self.estimatedCostUSD = estimatedCostUSD
        self.lastUpdated = lastUpdated
        self.byModel = byModel
        self.bySource = bySource
        self.byOrigin = byOrigin
        self.dailyTrend = dailyTrend
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalTokens = try container.decode(Int.self, forKey: .totalTokens)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        cachedTokens = try container.decode(Int.self, forKey: .cachedTokens)
        reasoningTokens = try container.decode(Int.self, forKey: .reasoningTokens)
        requests = try container.decode(Int.self, forKey: .requests)
        sessions = try container.decode(Int.self, forKey: .sessions)
        estimatedCostUSD = try container.decode(Double.self, forKey: .estimatedCostUSD)
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated)
        byModel = try container.decode([BreakdownEntry].self, forKey: .byModel)
        bySource = try container.decode([BreakdownEntry].self, forKey: .bySource)
        byOrigin = try container.decodeIfPresent([BreakdownEntry].self, forKey: .byOrigin) ?? []
        dailyTrend = try container.decode([DailyBucket].self, forKey: .dailyTrend)
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
    public var skippedClaudeLines: Int
    public var warnings: [String]

    public init(
        records: [NormalizedUsage],
        skippedCodexLines: Int,
        skippedOpenCodeRows: Int,
        warnings: [String],
        skippedClaudeLines: Int = 0
    ) {
        self.records = records
        self.skippedCodexLines = skippedCodexLines
        self.skippedOpenCodeRows = skippedOpenCodeRows
        self.skippedClaudeLines = skippedClaudeLines
        self.warnings = warnings
    }

    private enum CodingKeys: String, CodingKey {
        case records
        case skippedCodexLines
        case skippedOpenCodeRows
        case skippedClaudeLines
        case warnings
    }

    /// Decodes reports written before `skippedClaudeLines` existed: the key
    /// defaults to zero instead of failing. Encoding is unchanged.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        records = try container.decode([NormalizedUsage].self, forKey: .records)
        skippedCodexLines = try container.decode(Int.self, forKey: .skippedCodexLines)
        skippedOpenCodeRows = try container.decode(Int.self, forKey: .skippedOpenCodeRows)
        skippedClaudeLines = try container.decodeIfPresent(Int.self, forKey: .skippedClaudeLines) ?? 0
        warnings = try container.decode([String].self, forKey: .warnings)
    }
}

public enum StoreError: Error, Sendable {
    case missingRoot(String)
    case sqliteUnavailable
    case sqliteOpenFailed(String)
}
