import Foundation
import XCTest
@testable import TokenBarCore

/// M3 provider-aware pricing: exact normalized provider/model first, then
/// family/substring, then fallback. Static estimates only, never a bill.
final class PricingTests: XCTestCase {
    func testObservedProviderModelsResolveDeterministically() {
        // github-copilot/gpt-5.6-sol: GPT-5 family approximation.
        XCTAssertTrue(Pricing.isExactMatch(forModel: "github-copilot/gpt-5.6-sol"))
        XCTAssertEqual(
            Pricing.cost(model: "github-copilot/gpt-5.6-sol", inputTokens: 1_000_000, outputTokens: 0, cachedTokens: 0),
            1.25, accuracy: 0.0001)
        XCTAssertEqual(
            Pricing.cost(model: "github-copilot/gpt-5.6-sol", inputTokens: 0, outputTokens: 1_000_000, cachedTokens: 0),
            10.0, accuracy: 0.0001)

        // openai/gpt-5.6-luna: GPT-5 family approximation.
        XCTAssertTrue(Pricing.isExactMatch(forModel: "openai/gpt-5.6-luna"))
        XCTAssertEqual(
            Pricing.cost(model: "openai/gpt-5.6-luna", inputTokens: 1_000_000, outputTokens: 0, cachedTokens: 0),
            1.25, accuracy: 0.0001)

        // opencode-go/muse-spark-1.3-contributor: Sonnet family approximation.
        // Output rate distinguishes exact (15.0) from fallback (12.0);
        // input rate alone cannot (both 3.0).
        XCTAssertTrue(Pricing.isExactMatch(forModel: "opencode-go/muse-spark-1.3-contributor"))
        XCTAssertEqual(
            Pricing.cost(model: "opencode-go/muse-spark-1.3-contributor", inputTokens: 0, outputTokens: 1_000_000, cachedTokens: 0),
            15.0, accuracy: 0.0001)
        XCTAssertEqual(
            Pricing.cost(model: "opencode-go/muse-spark-1.3-contributor", inputTokens: 1_000_000, outputTokens: 0, cachedTokens: 1_000_000),
            0.30, accuracy: 0.0001)
    }

    func testExactIsCaseInsensitiveAndTrimmed() {
        XCTAssertTrue(Pricing.isExactMatch(forModel: "OPENAI/GPT-5.6-LUNA"))
        XCTAssertTrue(Pricing.isExactMatch(forModel: "  openai/gpt-5.6-luna  "))
        XCTAssertTrue(Pricing.isExactMatch(forModel: "GitHub-Copilot/GPT-5.6-SOL"))
        XCTAssertTrue(Pricing.isExactMatch(forModel: "Opencode-Go/Muse-Spark-1.3-Contributor"))
        XCTAssertEqual(
            Pricing.cost(model: "OPENAI/GPT-5.6-LUNA", inputTokens: 1_000_000, outputTokens: 0, cachedTokens: 0),
            Pricing.cost(model: "openai/gpt-5.6-luna", inputTokens: 1_000_000, outputTokens: 0, cachedTokens: 0),
            accuracy: 0.000001)
    }

    func testProviderPrefixMatters() {
        let split = Pricing.providerAndModel(forModel: "OpenAI/GPT-5.6-Luna")
        XCTAssertEqual(split.provider, "openai")
        XCTAssertEqual(split.name, "gpt-5.6-luna")
        XCTAssertEqual(Pricing.providerAndModel(forModel: "gpt-5").provider, "")

        // Bare suffix is not an exact hit: provider is part of the key.
        XCTAssertFalse(Pricing.isExactMatch(forModel: "gpt-5.6-luna"))
        // Wrong provider falls through (family gives GPT-5 rate here).
        XCTAssertFalse(Pricing.isExactMatch(forModel: "other-provider/gpt-5.6-luna"))
        XCTAssertEqual(
            Pricing.cost(model: "other-provider/gpt-5.6-luna", inputTokens: 1_000_000, outputTokens: 0, cachedTokens: 0),
            1.25, accuracy: 0.0001)
        // Muse Spark without its provider has no family substring, so it
        // visibly falls back instead of silently matching Sonnet.
        XCTAssertFalse(Pricing.isExactMatch(forModel: "muse-spark-1.3-contributor"))
        XCTAssertEqual(
            Pricing.cost(model: "muse-spark-1.3-contributor", inputTokens: 0, outputTokens: 1_000_000, cachedTokens: 0),
            12.0, accuracy: 0.0001)
        XCTAssertFalse(Pricing.isExactMatch(forModel: "other/muse-spark-1.3-contributor"))
    }

    func testExactBeatsFamilyAndFallback() {
        // Muse Spark exact (Sonnet output 15.0) beats fallback (12.0):
        // without the exact table this model has no family substring.
        let exactOutput = Pricing.cost(
            model: "opencode-go/muse-spark-1.3-contributor",
            inputTokens: 0, outputTokens: 1_000_000, cachedTokens: 0)
        let fallbackOutput = Pricing.cost(
            model: "some-future-model-zzz", inputTokens: 0, outputTokens: 1_000_000, cachedTokens: 0)
        XCTAssertEqual(exactOutput, 15.0, accuracy: 0.0001)
        XCTAssertEqual(fallbackOutput, 12.0, accuracy: 0.0001)
        XCTAssertNotEqual(exactOutput, fallbackOutput)
        // GPT exact entries are documented approximations equal to the
        // nearest family rate; the exact flag proves provider-aware
        // resolution even when the dollar figure coincides.
        XCTAssertTrue(Pricing.isExactMatch(forModel: "github-copilot/gpt-5.6-sol"))
        XCTAssertFalse(Pricing.isExactMatch(forModel: "gpt-5"))
    }

    func testFallbackPathNeverZero() {
        XCTAssertFalse(Pricing.isExactMatch(forModel: "some-future-model-zzz"))
        XCTAssertEqual(
            Pricing.cost(model: "some-future-model-zzz", inputTokens: 1_000_000, outputTokens: 0, cachedTokens: 0),
            3.0, accuracy: 0.0001)
        XCTAssertEqual(
            Pricing.cost(model: "unknown", inputTokens: 1_000_000, outputTokens: 1_000_000, cachedTokens: 0),
            15.0, accuracy: 0.0001)
    }

    func testCachedSubsetCapPreserved() {
        // All input cached => only cached rate applies (GPT-5 exact).
        XCTAssertEqual(
            Pricing.cost(model: "openai/gpt-5.6-luna", inputTokens: 1000, outputTokens: 0, cachedTokens: 1000),
            1000.0 / 1_000_000.0 * 0.125, accuracy: 0.0000001)
        // Oversized cached clamps to input.
        XCTAssertEqual(
            Pricing.cost(model: "gpt-4o", inputTokens: 100, outputTokens: 0, cachedTokens: 5000),
            Pricing.cost(model: "gpt-4o", inputTokens: 100, outputTokens: 0, cachedTokens: 100),
            accuracy: 0.0000001)
    }

    func testReasoningRidesInsideOutput() {
        let now = Date(timeIntervalSince1970: 1_789_041_600)
        let rec = NormalizedUsage(
            id: "r", source: .codex, timestamp: now,
            model: "github-copilot/gpt-5.6-sol",
            inputTokens: 1000, outputTokens: 500, cachedTokens: 0,
            reasoningTokens: 500, totalTokens: 0, sessionId: "s", requestId: "r")
        // Reasoning never added on top of total.
        XCTAssertEqual(rec.totalTokens, 1500)
        // Cost uses output only; reasoning adds nothing extra.
        XCTAssertEqual(
            Pricing.cost(for: rec),
            Pricing.cost(model: "github-copilot/gpt-5.6-sol", inputTokens: 1000, outputTokens: 500, cachedTokens: 0),
            accuracy: 0.0000001)
    }

    func testFamilyTablePreserved() {
        XCTAssertEqual(
            Pricing.cost(model: "gpt-4o-mini", inputTokens: 1_000_000, outputTokens: 0, cachedTokens: 0),
            0.15, accuracy: 0.0001)
        XCTAssertEqual(
            Pricing.cost(model: "gpt-4o", inputTokens: 1_000_000, outputTokens: 0, cachedTokens: 0),
            2.5, accuracy: 0.0001)
        XCTAssertEqual(
            Pricing.cost(model: "claude-sonnet-4", inputTokens: 0, outputTokens: 1_000_000, cachedTokens: 0),
            15.0, accuracy: 0.0001)
    }

    func testReportLabelsEstimateOnlyAndShowsUnknown() {
        let now = Date(timeIntervalSince1970: 1_789_041_600)
        let records = [
            NormalizedUsage(
                id: "a", source: .codex, timestamp: now,
                model: "openai/gpt-5.6-luna",
                inputTokens: 100, outputTokens: 50, cachedTokens: 0,
                reasoningTokens: 0, totalTokens: 0, sessionId: "s", requestId: "a"),
            NormalizedUsage(
                id: "b", source: .opencode, timestamp: now,
                model: "mystery-model-zzz",
                inputTokens: 100, outputTokens: 50, cachedTokens: 0,
                reasoningTokens: 0, totalTokens: 0, sessionId: "s", requestId: "b"),
        ]
        let section = ReportFormatter.section(
            records: records, source: .all, preset: .lifetime, now: now)
        let text = ReportFormatter.render(section: section)
        XCTAssertTrue(text.contains("Estimated cost:"))
        XCTAssertTrue(text.contains("estimate only"))
        XCTAssertTrue(text.contains("not a bill"))
        XCTAssertTrue(text.contains("not an API invoice"))
        // Unknown fallback stays visible, never zeroed.
        XCTAssertGreaterThan(section.stats.estimatedCostUSD, 0)
        XCTAssertTrue(section.stats.byModel.contains(where: { $0.key == "mystery-model-zzz" }))
    }
}
