import Foundation

/// Where one per-1M USD rate came from. Every cost stays an estimate;
/// the origin only tells the user which table won, never a billing claim.
public enum PriceOrigin: String, Codable, Hashable, Sendable {
    /// Entry came from a catalog fetched over the network this session.
    case dynamicCatalog
    /// Entry came from a previously persisted catalog on disk.
    case cachedCatalog
    /// Entry came from the static exact/family table in `Pricing.swift`.
    case staticEstimate
    /// No catalog or static entry matched; the documented fallback rate.
    case fallback

    public var label: String {
        switch self {
        case .dynamicCatalog: return "dynamic catalog"
        case .cachedCatalog: return "cached catalog"
        case .staticEstimate: return "static estimate"
        case .fallback: return "fallback"
        }
    }
}

/// One normalized catalog rate: USD per 1M tokens, same units as `ModelPrice`.
public struct CatalogEntry: Codable, Hashable, Sendable {
    public var model: String
    public var inputPerMTok: Double
    public var outputPerMTok: Double
    public var cachedPerMTok: Double

    public init(model: String, inputPerMTok: Double, outputPerMTok: Double, cachedPerMTok: Double) {
        self.model = model
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cachedPerMTok = cachedPerMTok
    }
}

/// Persisted dynamic pricing catalog (pluggable normalized format, version 1).
///
/// The file on disk is the contract other sources plug into: any future
/// provider decoder normalizes into this shape before persistence, so
/// resolution and the app/CLI never parse provider JSON directly.
public struct PricingCatalog: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var sourceURL: String
    public var fetchedAt: Date
    public var entries: [CatalogEntry]

    public init(version: Int = currentVersion, sourceURL: String, fetchedAt: Date, entries: [CatalogEntry]) {
        self.version = version
        self.sourceURL = sourceURL
        self.fetchedAt = fetchedAt
        self.entries = entries
    }

    /// Normalized exact-match index: trimmed + lowercased full id first.
    func index() -> [String: CatalogEntry] {
        var map: [String: CatalogEntry] = [:]
        map.reserveCapacity(entries.count)
        for entry in entries {
            map[Pricing.normalizedKey(forModel: entry.model)] = entry
        }
        return map
    }

    /// Deterministic suffix fallback: a bare usage model like `gpt-4o`
    /// matches the lexically smallest catalog id whose `/`-suffix equals it
    /// (for example `openai/gpt-4o`). Full exact matches always win first;
    /// this only widens coverage for provider-prefixed catalog ids.
    func suffixMatch(forKey key: String) -> CatalogEntry? {
        guard !key.contains("/") else { return nil }
        var best: (id: String, entry: CatalogEntry)?
        for entry in entries {
            let normalized = Pricing.normalizedKey(forModel: entry.model)
            let suffix = normalized.split(separator: "/").last.map(String.init) ?? normalized
            guard suffix == key else { continue }
            if best == nil || normalized < best!.id {
                best = (normalized, entry)
            }
        }
        return best?.entry
    }
}

/// A catalog plus whether it was fetched live this session (`true`) or
/// loaded from the on-disk cache (`false`). Cost math is identical either
/// way; only the exposed `PriceOrigin` label differs.
public struct CatalogSnapshot: Hashable, Sendable {
    public var catalog: PricingCatalog
    public var isFresh: Bool

    public init(catalog: PricingCatalog, isFresh: Bool) {
        self.catalog = catalog
        self.isFresh = isFresh
    }
}

public enum PricingCatalogError: Error, Sendable {
    case tooLarge(Int)
    case malformed(String)
    case unsupportedVersion(Int)
    case invalidRate(String)
}

// MARK: - OpenRouter decoder (primary dynamic source)

/// Documented public structured endpoint (GET, no auth): OpenRouter Models
/// API, `GET https://openrouter.ai/api/v1/models`. See
/// `https://openrouter.ai/docs/api-reference/overview` and
/// `https://openrouter.ai/docs/guides/overview/models`.
/// Response shape: `{ "data": [ { "id": "openai/gpt-4o",
/// "pricing": { "prompt": "0.0000025", "completion": "0.00001", ... } } ] }`.
/// All pricing values are USD per token as decimal strings; multiply by 1M.
public enum OpenRouterCatalog {
    public static let defaultURLString = "https://openrouter.ai/api/v1/models"

    struct Response: Decodable {
        var data: [Model]
    }

    struct Model: Decodable {
        var id: String
        var pricing: [String: String]?

        private enum CodingKeys: String, CodingKey {
            case id
            case pricing
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            // Pricing values arrive as decimal strings ("0.0000025"). A few
            // entries encode numbers; accept both, strictly as strings/doubles.
            if let stringMap = try? container.decode([String: String].self, forKey: .pricing) {
                pricing = stringMap
            } else if let doubleMap = try? container.decode([String: Double].self, forKey: .pricing) {
                pricing = Dictionary(uniqueKeysWithValues: doubleMap.map { ($0.key, String($0.value)) })
            } else if (try? container.decodeNil(forKey: .pricing)) == true {
                pricing = nil
            } else {
                pricing = nil
            }
        }
    }

    /// Strict decode: caps model count, requires a usable id plus prompt
    /// and completion rates on every kept entry, skips (never throws for)
    /// entries with unparseable rates so one bad provider row cannot poison
    /// the file. Returns normalized per-1M entries sorted by model id.
    public static func decodeEntries(from data: Data, maxModels: Int = 10_000) throws -> [CatalogEntry] {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw PricingCatalogError.malformed("openrouter payload is not {data:[{id,pricing}]} (\(error))")
        }
        guard response.data.count <= maxModels else {
            throw PricingCatalogError.tooLarge(response.data.count)
        }
        var entries: [CatalogEntry] = []
        entries.reserveCapacity(min(response.data.count, 1024))
        for model in response.data {
            let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            guard let pricing = model.pricing else { continue }
            guard let input = perMTok(pricing["prompt"]),
                  let output = perMTok(pricing["completion"]) else { continue }
            // Cache-read discount when published; otherwise no invented
            // discount: cached bills at the input rate (documented).
            let cached = perMTok(pricing["input_cache_read"])
                ?? perMTok(pricing["input_cache_write"])
                ?? input
            guard input.isFinite, output.isFinite, cached.isFinite,
                  input >= 0, output >= 0, cached >= 0 else { continue }
            entries.append(CatalogEntry(
                model: id, inputPerMTok: input, outputPerMTok: output, cachedPerMTok: cached))
        }
        return entries.sorted { $0.model < $1.model }
    }

    /// Decimal-string USD-per-token to USD-per-1M. Nil for missing/blank/
    /// unparseable values so callers can fall back deterministically.
    static func perMTok(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed) else { return nil }
        return value * 1_000_000.0
    }
}

// MARK: - Cache file codec (pluggable normalized format)

public enum PricingCatalogCodec {
    /// Encodes the persisted cache file. Dates use ISO-8601 so the file is
    /// human-inspectable and diffable.
    public static func encode(_ catalog: PricingCatalog) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(catalog)
    }

    /// Strict decode of the cache file: version must be 1, entries must
    /// carry finite non-negative rates and non-empty model ids.
    public static func decode(_ data: Data, maxEntries: Int = 50_000) throws -> PricingCatalog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalog: PricingCatalog
        do {
            catalog = try decoder.decode(PricingCatalog.self, from: data)
        } catch {
            throw PricingCatalogError.malformed("pricing cache is not {version,sourceURL,fetchedAt,entries} (\(error))")
        }
        guard catalog.version == PricingCatalog.currentVersion else {
            throw PricingCatalogError.unsupportedVersion(catalog.version)
        }
        guard catalog.entries.count <= maxEntries else {
            throw PricingCatalogError.tooLarge(catalog.entries.count)
        }
        for entry in catalog.entries {
            guard !entry.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PricingCatalogError.malformed("catalog entry with empty model id")
            }
            for rate in [entry.inputPerMTok, entry.outputPerMTok, entry.cachedPerMTok] {
                guard rate.isFinite, rate >= 0 else {
                    throw PricingCatalogError.invalidRate(entry.model)
                }
            }
        }
        return catalog
    }
}

// MARK: - Freshness

public enum PricingFreshness {
    /// Catalogs older than this count as cached/stale, never "dynamic".
    public static let freshThreshold: TimeInterval = 7 * 24 * 3600

    public static func isFresh(fetchedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(fetchedAt) >= 0 && now.timeIntervalSince(fetchedAt) <= freshThreshold
    }
}
