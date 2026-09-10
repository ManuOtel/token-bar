import Foundation

/// Per-1M-token USD rates (estimates, see README cost semantics).
public struct ModelPrice: Hashable, Sendable {
    public var inputPerMTok: Double
    public var outputPerMTok: Double
    public var cachedPerMTok: Double

    public init(inputPerMTok: Double, outputPerMTok: Double, cachedPerMTok: Double) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cachedPerMTok = cachedPerMTok
    }
}

public enum Pricing {
    /// Fallback for unknown models. Documented estimate, never blocks aggregation.
    public static let fallback = ModelPrice(inputPerMTok: 3.0, outputPerMTok: 12.0, cachedPerMTok: 1.5)

    /// Substring rules evaluated in order against the lowercased model name.
    /// Rates are approximate public-listing estimates, not live provider data.
    public static let table: [(match: String, price: ModelPrice)] = [
        ("gpt-4o-mini", ModelPrice(inputPerMTok: 0.15, outputPerMTok: 0.60, cachedPerMTok: 0.075)),
        ("gpt-4o", ModelPrice(inputPerMTok: 2.50, outputPerMTok: 10.0, cachedPerMTok: 1.25)),
        ("gpt-5-mini", ModelPrice(inputPerMTok: 0.25, outputPerMTok: 2.0, cachedPerMTok: 0.025)),
        ("gpt-5", ModelPrice(inputPerMTok: 1.25, outputPerMTok: 10.0, cachedPerMTok: 0.125)),
        ("o1-mini", ModelPrice(inputPerMTok: 1.10, outputPerMTok: 4.40, cachedPerMTok: 0.55)),
        ("o1", ModelPrice(inputPerMTok: 15.0, outputPerMTok: 60.0, cachedPerMTok: 7.50)),
        ("o3-mini", ModelPrice(inputPerMTok: 1.10, outputPerMTok: 4.40, cachedPerMTok: 0.55)),
        ("o3", ModelPrice(inputPerMTok: 2.0, outputPerMTok: 8.0, cachedPerMTok: 0.50)),
        ("claude-haiku", ModelPrice(inputPerMTok: 0.80, outputPerMTok: 4.0, cachedPerMTok: 0.08)),
        ("claude-sonnet", ModelPrice(inputPerMTok: 3.0, outputPerMTok: 15.0, cachedPerMTok: 0.30)),
        ("claude-opus", ModelPrice(inputPerMTok: 15.0, outputPerMTok: 75.0, cachedPerMTok: 1.50)),
        ("gemini-flash", ModelPrice(inputPerMTok: 0.35, outputPerMTok: 1.05, cachedPerMTok: 0.035)),
        ("gemini-pro", ModelPrice(inputPerMTok: 1.25, outputPerMTok: 10.0, cachedPerMTok: 0.125)),
    ]

    public static func price(forModel model: String) -> ModelPrice {
        let key = model.lowercased()
        for entry in table where key.contains(entry.match) {
            return entry.price
        }
        return fallback
    }

    /// Estimated cost. cached tokens are a subset of input (billed at the
    /// cached rate); reasoning tokens are a subset of output (billed at the
    /// output rate, never double-counted). total is never used for cost.
    public static func cost(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cachedTokens: Int
    ) -> Double {
        let price = price(forModel: model)
        let input = max(0, inputTokens)
        let output = max(0, outputTokens)
        let cached = min(max(0, cachedTokens), input)
        let fresh = input - cached
        return Double(fresh) / 1_000_000.0 * price.inputPerMTok
            + Double(cached) / 1_000_000.0 * price.cachedPerMTok
            + Double(output) / 1_000_000.0 * price.outputPerMTok
    }

    public static func cost(for record: NormalizedUsage) -> Double {
        cost(
            model: record.model,
            inputTokens: record.inputTokens,
            outputTokens: record.outputTokens,
            cachedTokens: record.cachedTokens
        )
    }
}
