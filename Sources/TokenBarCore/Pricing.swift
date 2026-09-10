import Foundation

/// Per-1M-token USD rates (static estimates only, never a bill, see README cost semantics).
/// Subscription / flat-rate usage is not an API invoice.
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
    /// Fallback for unknown models. Documented static estimate, never zero,
    /// never a billing claim. Unknown models stay visible at this rate.
    public static let fallback = ModelPrice(inputPerMTok: 3.0, outputPerMTok: 12.0, cachedPerMTok: 1.5)

    /// Exact normalized `provider/model` matches, checked BEFORE the
    /// family/substring table below. Keys are `normalizedKey` form:
    /// trimmed + lowercased, provider prefix included.
    ///
    /// Static estimates only, never a billing claim. Subscription or
    /// flat-rate usage (Copilot, Luna, Muse Spark contributor) is NOT an
    /// API invoice; these entries are clearly labeled approximations that
    /// reuse the nearest public family rate already in this project so there
    /// is one place to bump rates.
    public static let exact: [String: ModelPrice] = [
        // Approximation based on the GPT-5 family. Copilot subscription
        // use is flat-rate, not metered API billing.
        "github-copilot/gpt-5.6-sol": ModelPrice(inputPerMTok: 1.25, outputPerMTok: 10.0, cachedPerMTok: 0.125),
        // Approximation based on the GPT-5 family. Internal codename with
        // no public price list; static estimate only, not an invoice.
        "openai/gpt-5.6-luna": ModelPrice(inputPerMTok: 1.25, outputPerMTok: 10.0, cachedPerMTok: 0.125),
        // Approximation based on the Claude Sonnet family. Contributor /
        // subscription agentic use is not Anthropic API billing.
        "opencode-go/muse-spark-1.3-contributor": ModelPrice(inputPerMTok: 3.0, outputPerMTok: 15.0, cachedPerMTok: 0.30),
    ]

    /// Substring/family rules evaluated in order against the normalized
    /// model key, AFTER exact `provider/model` matches. Rates are
    /// approximate public-listing static estimates, not live provider data,
    /// not a bill. One place to bump rates.
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

    /// Normalized lookup key: trimmed + lowercased, provider prefix kept.
    /// Case-insensitive by construction (`OPENAI/GPT-...` == `openai/gpt-...`).
    public static func normalizedKey(forModel model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Splits a normalized key into provider + model on the first `/`.
    /// No-provider strings return `("", key)`. Pure helper for explicit
    /// provider-aware handling; pricing still keys on the full string.
    public static func providerAndModel(forModel model: String) -> (provider: String, name: String) {
        let key = normalizedKey(forModel: model)
        guard let slash = key.firstIndex(of: "/") else { return ("", key) }
        let provider = String(key[..<slash])
        let name = String(key[key.index(after: slash)...])
        return (provider, name)
    }

    /// True when the model hits the exact provider-aware table (before any
    /// family/substring rule). Used by tests + docs to show determinism.
    public static func isExactMatch(forModel model: String) -> Bool {
        exact[normalizedKey(forModel: model)] != nil
    }

    /// Resolution order (documented, deterministic, case-insensitive):
    /// 1. exact normalized `provider/model` match, 2. family/substring
    /// match in table order, 3. fallback. Never zero, never a bill.
    public static func price(forModel model: String) -> ModelPrice {
        let key = normalizedKey(forModel: model)
        if let hit = exact[key] {
            return hit
        }
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
