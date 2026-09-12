import Foundation

/// Deterministic filtering + aggregation over normalized records.
///
/// All functions are pure and take an explicit `now` + `calendar` so unit
/// tests are hermetic. Sort order is always (timestamp, id) ascending;
/// breakdowns sort by totalTokens descending, then key ascending.
public enum Aggregator {
    public static func filter(
        _ records: [NormalizedUsage],
        source: SourceFilter,
        preset: DatePreset,
        now: Date,
        calendar: Calendar = .current
    ) -> [NormalizedUsage] {
        let scoped = records.filter { source.matches($0.source) }
        switch preset {
        case .lifetime, .bestMonth:
            return sorted(scoped)
        case .today:
            let start = calendar.startOfDay(for: now)
            return sorted(scoped.filter { $0.timestamp >= start && $0.timestamp <= now })
        case .last24Hours:
            let start = now.addingTimeInterval(-24 * 3600)
            return sorted(scoped.filter { $0.timestamp >= start && $0.timestamp <= now })
        case .last7Days:
            let start = now.addingTimeInterval(-7 * 24 * 3600)
            return sorted(scoped.filter { $0.timestamp >= start && $0.timestamp <= now })
        case .last30Days:
            let start = now.addingTimeInterval(-30 * 24 * 3600)
            return sorted(scoped.filter { $0.timestamp >= start && $0.timestamp <= now })
        }
    }

    public static func aggregate(
        _ records: [NormalizedUsage],
        calendar: Calendar = .current
    ) -> AggregatedStats {
        aggregate(records, snapshot: nil, calendar: calendar)
    }

    /// Catalog-aware aggregation. A nil snapshot keeps the deterministic
    /// offline static path (CLI default). A supplied snapshot prices every
    /// record via `Pricing.resolve`, so dynamic/cached catalog entries win
    /// over the static table while unknown models still fall back visibly.
    public static func aggregate(
        _ records: [NormalizedUsage],
        snapshot: CatalogSnapshot?,
        calendar: Calendar = .current
    ) -> AggregatedStats {
        guard !records.isEmpty else { return .empty }
        var total = 0, input = 0, output = 0, cached = 0, reasoning = 0
        var cost = 0.0
        var sessions = Set<String>()
        var lastUpdated: Date?
        var modelGroups: [String: (tokens: Int, requests: Int, cost: Double)] = [:]
        var sourceGroups: [String: (tokens: Int, requests: Int, cost: Double)] = [:]
        var originGroups: [String: (tokens: Int, requests: Int, cost: Double)] = [:]

        for record in records {
            total += record.totalTokens
            input += record.inputTokens
            output += record.outputTokens
            cached += record.cachedTokens
            reasoning += record.reasoningTokens
            let recordCost = Pricing.cost(for: record, snapshot: snapshot)
            cost += recordCost
            if !record.sessionId.isEmpty { sessions.insert(record.sessionId) }
            if lastUpdated == nil || record.timestamp > lastUpdated! {
                lastUpdated = record.timestamp
            }
            var model = modelGroups[record.model] ?? (0, 0, 0)
            model.tokens += record.totalTokens
            model.requests += 1
            model.cost += recordCost
            modelGroups[record.model] = model
            let sourceKey = record.source.rawValue
            var group = sourceGroups[sourceKey] ?? (0, 0, 0)
            group.tokens += record.totalTokens
            group.requests += 1
            group.cost += recordCost
            sourceGroups[sourceKey] = group
            let originLabel = record.origin.trimmingCharacters(in: .whitespacesAndNewlines)
            let originKey = "\(record.source.rawValue)/\(originLabel.isEmpty ? "local" : originLabel)"
            var originGroup = originGroups[originKey] ?? (0, 0, 0)
            originGroup.tokens += record.totalTokens
            originGroup.requests += 1
            originGroup.cost += recordCost
            originGroups[originKey] = originGroup
        }

        return AggregatedStats(
            totalTokens: total,
            inputTokens: input,
            outputTokens: output,
            cachedTokens: cached,
            reasoningTokens: reasoning,
            requests: records.count,
            sessions: sessions.count,
            estimatedCostUSD: cost,
            lastUpdated: lastUpdated,
            byModel: breakdown(modelGroups),
            bySource: breakdown(sourceGroups),
            byOrigin: breakdown(originGroups),
            dailyTrend: dailyTrend(records, calendar: calendar)
        )
    }

    /// Groups the (already source-filtered) lifetime set by local calendar
    /// month and returns the month with max total tokens. Ties break toward
    /// the earliest month. Nil when the input is empty.
    public static func bestMonth(
        _ records: [NormalizedUsage],
        calendar: Calendar = .current
    ) -> BestMonth? {
        bestMonth(records, snapshot: nil, calendar: calendar)
    }

    /// Catalog-aware best-month. Cost basis follows the snapshot; the winner
    /// is still purely max total tokens, earliest on ties.
    public static func bestMonth(
        _ records: [NormalizedUsage],
        snapshot: CatalogSnapshot?,
        calendar: Calendar = .current
    ) -> BestMonth? {
        guard !records.isEmpty else { return nil }
        var groups: [String: [NormalizedUsage]] = [:]
        for record in records {
            groups[monthKey(for: record.timestamp, calendar: calendar), default: []].append(record)
        }
        var winner: String?
        var winnerTotal = -1
        for key in groups.keys.sorted() { // sorted => earliest wins ties
            let monthTotal = groups[key]!.reduce(0) { $0 + $1.totalTokens }
            if monthTotal > winnerTotal {
                winnerTotal = monthTotal
                winner = key
            }
        }
        guard let winner else { return nil }
        return BestMonth(monthKey: winner, stats: aggregate(groups[winner]!, snapshot: snapshot, calendar: calendar))
    }

    public static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    public static func dailyTrend(
        _ records: [NormalizedUsage],
        calendar: Calendar = .current
    ) -> [DailyBucket] {
        var groups: [String: (start: Date, tokens: Int, requests: Int)] = [:]
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        for record in records {
            let start = calendar.startOfDay(for: record.timestamp)
            let label = formatter.string(from: start)
            var bucket = groups[label] ?? (start, 0, 0)
            bucket.tokens += record.totalTokens
            bucket.requests += 1
            groups[label] = bucket
        }
        return groups.map { DailyBucket(dayStart: $0.value.start, dayLabel: $0.key, totalTokens: $0.value.tokens, requests: $0.value.requests) }
            .sorted { $0.dayLabel < $1.dayLabel }
    }

    // MARK: - Private

    private static func sorted(_ records: [NormalizedUsage]) -> [NormalizedUsage] {
        records.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id < $1.id
        }
    }

    private static func breakdown(_ groups: [String: (tokens: Int, requests: Int, cost: Double)]) -> [BreakdownEntry] {
        groups.map { BreakdownEntry(key: $0.key, totalTokens: $0.value.tokens, requests: $0.value.requests, estimatedCostUSD: $0.value.cost) }
            .sorted {
                if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
                return $0.key < $1.key
            }
    }
}
