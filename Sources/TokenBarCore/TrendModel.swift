import Foundation

/// Bucket grain for the adaptive dashboard trend.
public enum TrendGrain: String, Codable, Hashable, Sendable {
    case hour
    case day
    case month
}

/// One zero-fillable trend bucket for the dashboard chart.
///
/// Display-only rollup: `totalTokens` sums `NormalizedUsage.totalTokens`
/// only. Cached and reasoning tokens are subsets and are never added on
/// top. `label` is a short stable display string (`HH` for hours,
/// `yyyy-MM-dd` for days, `yyyy-MM` for months); the chart shows a sparse
/// subset plus the full first-last range so long histories stay readable.
public struct TrendBucket: Codable, Hashable, Sendable {
    public var start: Date
    public var label: String
    public var totalTokens: Int
    public var requests: Int

    public init(start: Date, label: String, totalTokens: Int, requests: Int) {
        self.start = start
        self.label = label
        self.totalTokens = totalTokens
        self.requests = requests
    }
}

/// Previous-period comparison for one chronological range.
///
/// Pure local/offline rollup over the same in-memory records as the
/// selected scope, with the same source filter. `nil` (returned only for
/// `.bestMonth` and `.lifetime`, which are not one fixed chronological
/// period) means no comparison applies. `hasBaseline == false` means the
/// previous window holds no records, so the UI must read "No prior-period
/// data" and never a fabricated 0 percent: `direction` and `percentChange`
/// are nil then. `percentChange` is also nil when the baseline total is
/// zero (percent undefined); `direction` still reads up/flat.
public struct TrendComparison: Codable, Hashable, Sendable {
    public enum Direction: String, Codable, Hashable, Sendable {
        case up
        case down
        case flat
    }

    public var currentTotalTokens: Int
    public var previousTotalTokens: Int
    public var currentRequests: Int
    public var previousRequests: Int
    public var direction: Direction?
    /// Percent change of current vs previous total, nil when there is no
    /// baseline or the baseline total is zero.
    public var percentChange: Double?
    public var hasBaseline: Bool
    /// Short previous-period name for UI copy ("yesterday",
    /// "previous 24 hours", "previous 7 days", "previous 30 days").
    public var previousLabel: String

    public init(
        currentTotalTokens: Int,
        previousTotalTokens: Int,
        currentRequests: Int,
        previousRequests: Int,
        direction: Direction?,
        percentChange: Double?,
        hasBaseline: Bool,
        previousLabel: String
    ) {
        self.currentTotalTokens = currentTotalTokens
        self.previousTotalTokens = previousTotalTokens
        self.currentRequests = currentRequests
        self.previousRequests = previousRequests
        self.direction = direction
        self.percentChange = percentChange
        self.hasBaseline = hasBaseline
        self.previousLabel = previousLabel
    }
}

/// Adaptive dashboard trend derivation. Pure and clock-injected; no file
/// access, no network, no pricing.
///
/// Grain per range: Today and Last 24H bucket by hour (including zero-token
/// hours), Last 7D / Last 30D / Best month bucket by day (including empty
/// days), Lifetime buckets by month (keeps long histories chartable).
/// Every range returns full coverage: hourly/daily/monthly buckets span the
/// whole selected range even when empty, so Today no longer renders one
/// bar and 7D/30D no longer hide empty days.
///
/// Filtering math is unchanged: callers pass the already-selected scope
/// (the `Aggregator.filter` result for the active source + preset), so
/// bucket counts always reconcile with the hero total. Display buckets are
/// calendar-aligned while the selected record predicate stays the existing
/// rolling predicate (Today is the local calendar day; 24H/7D/30D are
/// rolling windows ending at `now`). Rolling-window edge days therefore
/// show partial calendar-day buckets by design: only in-window records are
/// counted, and the chart never invents out-of-window tokens.
public enum TrendModel {
    // MARK: - Grain, titles, labels

    public static func grain(for preset: DatePreset) -> TrendGrain {
        switch preset {
        case .today, .last24Hours:
            return .hour
        case .last7Days, .last30Days, .bestMonth:
            return .day
        case .lifetime:
            return .month
        }
    }

    /// Adaptive chart title naming the active range and grain.
    public static func title(for preset: DatePreset) -> String {
        switch preset {
        case .today:
            return "TODAY BY HOUR"
        case .last24Hours:
            return "LAST 24H BY HOUR"
        case .last7Days:
            return "LAST 7D BY DAY"
        case .last30Days:
            return "LAST 30D BY DAY"
        case .bestMonth:
            return "BEST MONTH BY DAY"
        case .lifetime:
            return "ALL TIME BY MONTH"
        }
    }

    /// Previous-period short name for comparison copy. Nil for `.bestMonth`
    /// and `.lifetime`: they are not one fixed chronological period, so no
    /// comparison applies.
    public static func previousLabel(for preset: DatePreset) -> String? {
        switch preset {
        case .today:
            return "yesterday"
        case .last24Hours:
            return "previous 24 hours"
        case .last7Days:
            return "previous 7 days"
        case .last30Days:
            return "previous 30 days"
        case .bestMonth, .lifetime:
            return nil
        }
    }

    // MARK: - Buckets

    /// Zero-filled buckets over the selected range from the already-selected
    /// scope (the `Aggregator.filter` result, so the same source filter and
    /// the same rolling/calendar-day predicate as the hero total). The
    /// bucket-token sum always equals the scope token total. For
    /// `.bestMonth`, pass the winning month's records plus its `monthKey`
    /// (`yyyy-MM`); without a key (empty scope) there is nothing to cover
    /// and the result is empty. For `.lifetime`, an empty scope yields an
    /// empty result (no months to cover).
    public static func buckets(
        scoped: [NormalizedUsage],
        preset: DatePreset,
        now: Date,
        calendar: Calendar = .current,
        bestMonthKey: String? = nil
    ) -> [TrendBucket] {
        switch preset {
        case .today:
            return hourlyBucketsToday(scoped: scoped, now: now, calendar: calendar)
        case .last24Hours:
            return hourlyBucketsRolling(scoped: scoped, now: now, calendar: calendar)
        case .last7Days:
            return dailyBucketsRolling(scoped: scoped, days: 7, now: now, calendar: calendar)
        case .last30Days:
            return dailyBucketsRolling(scoped: scoped, days: 30, now: now, calendar: calendar)
        case .bestMonth:
            guard let key = bestMonthKey else { return [] }
            return dailyBucketsMonth(scoped: scoped, monthKey: key, calendar: calendar)
        case .lifetime:
            return monthlyBuckets(scoped: scoped, now: now, calendar: calendar)
        }
    }

    // MARK: - Comparison

    /// Previous-period comparison over the in-memory records with the same
    /// source filter as the selected scope. One unsorted pass, no file
    /// reads: current-window totals use the exact `Aggregator.filter`
    /// predicate (so the current total always equals the hero total), and
    /// the previous window is the same-length period immediately before it
    /// (previous local calendar day for Today; preceding rolling window for
    /// 24H/7D/30D, upper bound exclusive so a boundary record counts once).
    /// Returns nil for `.bestMonth` and `.lifetime`.
    public static func comparison(
        records: [NormalizedUsage],
        source: SourceFilter,
        preset: DatePreset,
        now: Date,
        calendar: Calendar = .current
    ) -> TrendComparison? {
        guard let label = previousLabel(for: preset) else { return nil }
        let current = window(for: preset, now: now, calendar: calendar)
        let previous = previousWindow(for: preset, now: now, calendar: calendar)
        var currentTokens = 0, currentRequests = 0
        var previousTokens = 0, previousRequests = 0
        for record in records {
            guard source.matches(record.source) else { continue }
            let ts = record.timestamp
            if ts >= current.start && ts <= current.end {
                currentTokens += record.totalTokens
                currentRequests += 1
            } else if ts >= previous.start && ts < previous.end {
                previousTokens += record.totalTokens
                previousRequests += 1
            }
        }
        let hasBaseline = previousRequests > 0
        guard hasBaseline else {
            return TrendComparison(
                currentTotalTokens: currentTokens,
                previousTotalTokens: 0,
                currentRequests: currentRequests,
                previousRequests: 0,
                direction: nil,
                percentChange: nil,
                hasBaseline: false,
                previousLabel: label
            )
        }
        let direction: TrendComparison.Direction
        if currentTokens > previousTokens {
            direction = .up
        } else if currentTokens < previousTokens {
            direction = .down
        } else {
            direction = .flat
        }
        let percent: Double? = previousTokens > 0
            ? Double(currentTokens - previousTokens) / Double(previousTokens) * 100
            : nil
        return TrendComparison(
            currentTotalTokens: currentTokens,
            previousTotalTokens: previousTokens,
            currentRequests: currentRequests,
            previousRequests: previousRequests,
            direction: direction,
            percentChange: percent,
            hasBaseline: true,
            previousLabel: label
        )
    }

    // MARK: - Windows (mirror Aggregator.filter bounds)

    private struct Window {
        var start: Date
        var end: Date
    }

    /// Current-window bounds for a preset (inclusive on both ends, matching
    /// `Aggregator.filter`; `.bestMonth`/`.lifetime` have no window).
    private static func window(for preset: DatePreset, now: Date, calendar: Calendar) -> Window {
        switch preset {
        case .today:
            return Window(start: calendar.startOfDay(for: now), end: now)
        case .last24Hours:
            return Window(start: now.addingTimeInterval(-24 * 3600), end: now)
        case .last7Days:
            return Window(start: now.addingTimeInterval(-7 * 24 * 3600), end: now)
        case .last30Days:
            return Window(start: now.addingTimeInterval(-30 * 24 * 3600), end: now)
        case .bestMonth, .lifetime:
            return Window(start: .distantPast, end: now)
        }
    }

    /// Previous-window bounds: same length immediately before the current
    /// window, upper bound exclusive so a record on the shared boundary
    /// counts in the current window only.
    private static func previousWindow(for preset: DatePreset, now: Date, calendar: Calendar) -> Window {
        let current = window(for: preset, now: now, calendar: calendar)
        switch preset {
        case .today:
            let dayStart = calendar.startOfDay(for: now)
            let prevStart = calendar.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart.addingTimeInterval(-24 * 3600)
            return Window(start: prevStart, end: dayStart)
        case .last24Hours, .last7Days, .last30Days:
            let length = current.end.timeIntervalSince(current.start)
            return Window(start: current.start.addingTimeInterval(-length), end: current.start)
        case .bestMonth, .lifetime:
            return Window(start: .distantPast, end: .distantPast)
        }
    }

    // MARK: - Hourly buckets

    /// Today: one bucket per local hour from the calendar-day start through
    /// the current hour (inclusive), including zero-token hours. Placement
    /// uses the record's calendar local hour so spring-forward/fall-back
    /// transitions label records with the correct local hour; bucket starts
    /// stay on stable `Calendar.date(byAdding: .hour ...)` coverage.
    private static func hourlyBucketsToday(
        scoped: [NormalizedUsage],
        now: Date,
        calendar: Calendar
    ) -> [TrendBucket] {
        let dayStart = calendar.startOfDay(for: now)
        let currentHour = max(0, calendar.component(.hour, from: now))
        var totals = Array(repeating: 0, count: currentHour + 1)
        var counts = Array(repeating: 0, count: currentHour + 1)
        for record in scoped {
            guard record.timestamp >= dayStart, record.timestamp <= now else { continue }
            let hour = calendar.component(.hour, from: record.timestamp)
            guard hour >= 0, hour <= currentHour else { continue }
            totals[hour] += record.totalTokens
            counts[hour] += 1
        }
        return (0...currentHour).map { hour in
            let start = calendar.date(byAdding: .hour, value: hour, to: dayStart) ?? dayStart
            return TrendBucket(
                start: start,
                label: String(format: "%02d", hour),
                totalTokens: totals[hour],
                requests: counts[hour]
            )
        }
    }

    /// Last 24 hours: 24 rolling hourly buckets covering
    /// `[now - 24h, now]`, including zero-token hours. Bucket `i` covers
    /// `[windowStart + i hours, windowStart + (i + 1) hours)`; a record at
    /// exactly `now` lands in the final bucket, and a record at exactly
    /// `windowStart` lands in bucket 0. Out-of-window records are skipped.
    private static func hourlyBucketsRolling(
        scoped: [NormalizedUsage],
        now: Date,
        calendar: Calendar
    ) -> [TrendBucket] {
        let windowStart = now.addingTimeInterval(-24 * 3600)
        var totals = Array(repeating: 0, count: 24)
        var counts = Array(repeating: 0, count: 24)
        for record in scoped {
            guard record.timestamp >= windowStart, record.timestamp <= now else { continue }
            let elapsed = record.timestamp.timeIntervalSince(windowStart)
            guard elapsed >= 0, elapsed <= 24 * 3600 else { continue }
            var index = Int(elapsed / 3600)
            if index == 24 { index = 23 }
            guard index >= 0, index < 24 else { continue }
            totals[index] += record.totalTokens
            counts[index] += 1
        }
        return (0..<24).map { offset in
            let start = windowStart.addingTimeInterval(Double(offset) * 3600)
            let hour = calendar.component(.hour, from: start)
            return TrendBucket(
                start: start,
                label: String(format: "%02d", hour),
                totalTokens: totals[offset],
                requests: counts[offset]
            )
        }
    }

    // MARK: - Daily buckets

    private static func dayLabelFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// Rolling N-day range: one calendar-day bucket per day from the
    /// calendar day holding `now - N days` through today, including empty
    /// days. Calendar-aligned display over the rolling predicate: the first
    /// bucket may be partial (only in-window records count), never padded.
    private static func dailyBucketsRolling(
        scoped: [NormalizedUsage],
        days: Int,
        now: Date,
        calendar: Calendar
    ) -> [TrendBucket] {
        let formatter = dayLabelFormatter(calendar: calendar)
        let windowStart = now.addingTimeInterval(-Double(days) * 24 * 3600)
        let firstDay = calendar.startOfDay(for: windowStart)
        let todayStart = calendar.startOfDay(for: now)
        let span = max(0, calendar.dateComponents([.day], from: firstDay, to: todayStart).day ?? 0)
        var totals = Array(repeating: 0, count: span + 1)
        var counts = Array(repeating: 0, count: span + 1)
        for record in scoped {
            let day = calendar.startOfDay(for: record.timestamp)
            let index = calendar.dateComponents([.day], from: firstDay, to: day).day ?? 0
            guard index >= 0, index <= span else { continue }
            totals[index] += record.totalTokens
            counts[index] += 1
        }
        return (0...span).map { offset in
            let start = calendar.date(byAdding: .day, value: offset, to: firstDay) ?? firstDay
            return TrendBucket(
                start: start,
                label: formatter.string(from: start),
                totalTokens: totals[offset],
                requests: counts[offset]
            )
        }
    }

    /// Best month: one bucket per calendar day of the winning `monthKey`
    /// (`yyyy-MM`), including empty days. Only records whose calendar
    /// month matches `monthKey` are counted, so unfiltered callers cannot
    /// leak another month's same-day records into these buckets.
    private static func dailyBucketsMonth(
        scoped: [NormalizedUsage],
        monthKey: String,
        calendar: Calendar
    ) -> [TrendBucket] {
        let parts = monthKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return [] }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = 1
        let monthCalendar = calendar
        guard let monthStart = monthCalendar.date(from: components),
              let dayCount = monthCalendar.range(of: .day, in: .month, for: monthStart)?.count else {
            return []
        }
        let formatter = dayLabelFormatter(calendar: monthCalendar)
        var totals = Array(repeating: 0, count: dayCount)
        var counts = Array(repeating: 0, count: dayCount)
        for record in scoped {
            guard Aggregator.monthKey(for: record.timestamp, calendar: monthCalendar) == monthKey else { continue }
            let day = monthCalendar.component(.day, from: record.timestamp)
            let index = day - 1
            guard index >= 0, index < dayCount else { continue }
            totals[index] += record.totalTokens
            counts[index] += 1
        }
        return (0..<dayCount).map { offset in
            let start = calendar.date(byAdding: .day, value: offset, to: monthStart) ?? monthStart
            return TrendBucket(
                start: start,
                label: formatter.string(from: start),
                totalTokens: totals[offset],
                requests: counts[offset]
            )
        }
    }

    // MARK: - Monthly buckets

    /// Lifetime: one bucket per calendar month from the earliest record's
    /// month through the current month, including empty months. Keeps long
    /// histories chartable where daily buckets would not fit.
    private static func monthlyBuckets(
        scoped: [NormalizedUsage],
        now: Date,
        calendar: Calendar
    ) -> [TrendBucket] {
        guard let earliest = scoped.map(\.timestamp).min() else { return [] }
        let startMonth = monthStart(for: earliest, calendar: calendar)
        let endMonth = monthStart(for: now, calendar: calendar)
        let span = monthDistance(from: startMonth, to: endMonth, calendar: calendar)
        guard span >= 0 else { return [] }
        var totals = Array(repeating: 0, count: span + 1)
        var counts = Array(repeating: 0, count: span + 1)
        for record in scoped {
            let index = monthDistance(
                from: startMonth,
                to: monthStart(for: record.timestamp, calendar: calendar),
                calendar: calendar)
            guard index >= 0, index <= span else { continue }
            totals[index] += record.totalTokens
            counts[index] += 1
        }
        return (0...span).map { offset in
            let start = calendar.date(byAdding: .month, value: offset, to: startMonth) ?? startMonth
            let components = calendar.dateComponents([.year, .month], from: start)
            let label = String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
            return TrendBucket(
                start: start,
                label: label,
                totalTokens: totals[offset],
                requests: counts[offset]
            )
        }
    }

    private static func monthStart(for date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? calendar.startOfDay(for: date)
    }

    private static func monthDistance(from start: Date, to end: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.month], from: start, to: end)
        return components.month ?? 0
    }
}
