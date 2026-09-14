import XCTest
@testable import TokenBarCore

/// Compact token-count unit contract: raw, k, M, B, T with rounding
/// promotion at every boundary, sign-preserving negatives, and defined
/// behavior for zero and very large `Int` values.
///
/// This pins the reported bug (`2_416_100_000` rendered as `2416.1M`) and
/// the exact transitions the dashboard and menu title share through
/// `TokenCountFormat.compact`.
final class TokenCountFormatTests: XCTestCase {
    // MARK: - Raw counts and k

    func testRawCounts() {
        XCTAssertEqual(TokenCountFormat.compact(0), "0")
        XCTAssertEqual(TokenCountFormat.compact(1), "1")
        XCTAssertEqual(TokenCountFormat.compact(999), "999")
        XCTAssertEqual(TokenCountFormat.compact(-1), "-1")
        XCTAssertEqual(TokenCountFormat.compact(-999), "-999")
    }

    func testThousands() {
        XCTAssertEqual(TokenCountFormat.compact(1000), "1k")
        XCTAssertEqual(TokenCountFormat.compact(1500), "1.5k")
        XCTAssertEqual(TokenCountFormat.compact(1999), "2k")
        XCTAssertEqual(TokenCountFormat.compact(2000), "2k")
        XCTAssertEqual(TokenCountFormat.compact(12_345), "12.3k")
        XCTAssertEqual(TokenCountFormat.compact(-1000), "-1k")
        XCTAssertEqual(TokenCountFormat.compact(-1500), "-1.5k")
    }

    // MARK: - Millions (existing dashboard precision, trimmed)

    func testMillions() {
        XCTAssertEqual(TokenCountFormat.compact(1_000_000), "1M")
        XCTAssertEqual(TokenCountFormat.compact(2_000_000), "2M")
        XCTAssertEqual(TokenCountFormat.compact(2_345_678), "2.3M")
        XCTAssertEqual(TokenCountFormat.compact(12_500_000), "12.5M")
        XCTAssertEqual(TokenCountFormat.compact(-2_500_000), "-2.5M")
    }

    // MARK: - Reported bug: billions use B, trillions use T

    func testBillions() {
        XCTAssertEqual(TokenCountFormat.compact(1_000_000_000), "1B")
        XCTAssertEqual(TokenCountFormat.compact(2_000_000_000), "2B")
        XCTAssertEqual(TokenCountFormat.compact(2_416_100_000), "2.4B")
        XCTAssertEqual(TokenCountFormat.compact(12_500_000_000), "12.5B")
        XCTAssertEqual(TokenCountFormat.compact(-1_000_000_000), "-1B")
    }

    func testTrillions() {
        XCTAssertEqual(TokenCountFormat.compact(1_000_000_000_000), "1T")
        XCTAssertEqual(TokenCountFormat.compact(2_000_000_000_000), "2T")
        XCTAssertEqual(TokenCountFormat.compact(1_500_000_000_000), "1.5T")
        XCTAssertEqual(TokenCountFormat.compact(123_456_789_012_345), "123.5T")
        XCTAssertEqual(TokenCountFormat.compact(-1_500_000_000_000), "-1.5T")
    }

    // MARK: - Rounding promotion never emits 1000.0k/M/B

    func testKToMBoundaryPromotion() {
        XCTAssertEqual(TokenCountFormat.compact(999_949), "999.9k")
        XCTAssertEqual(TokenCountFormat.compact(999_950), "1M")
        XCTAssertEqual(TokenCountFormat.compact(999_999), "1M")
    }

    func testMToBBoundaryPromotion() {
        XCTAssertEqual(TokenCountFormat.compact(999_499_999), "999.5M")
        XCTAssertEqual(TokenCountFormat.compact(999_949_999), "999.9M")
        XCTAssertEqual(TokenCountFormat.compact(999_950_000), "1B")
    }

    func testBToTBoundaryPromotion() {
        XCTAssertEqual(TokenCountFormat.compact(999_499_999_999), "999.5B")
        XCTAssertEqual(TokenCountFormat.compact(999_949_999_999), "999.9B")
        XCTAssertEqual(TokenCountFormat.compact(999_950_000_000), "1T")
    }

    // MARK: - Output shape: locale-independent decimal point, trimmed .0

    func testTrimmedWholeUnits() {
        for value in [1000, 1_000_000, 1_000_000_000, 1_000_000_000_000] {
            let text = TokenCountFormat.compact(value)
            XCTAssertFalse(text.contains(".0"), "\(value) should trim trailing .0, got \(text)")
        }
        XCTAssertEqual(TokenCountFormat.compact(1000), "1k")
        XCTAssertEqual(TokenCountFormat.compact(1_000_000), "1M")
        XCTAssertEqual(TokenCountFormat.compact(1_000_000_000), "1B")
        XCTAssertEqual(TokenCountFormat.compact(1_000_000_000_000), "1T")
    }

    func testDecimalSeparatorIsPeriod() {
        let text = TokenCountFormat.compact(1_500_000_000)
        XCTAssertEqual(text, "1.5B")
        XCTAssertTrue(text.contains("."), "compact counts must use a period decimal separator")
        XCTAssertFalse(text.contains(","), "compact counts must never group with commas")
    }

    // MARK: - Very large Int values stay defined in T

    func testExtremeIntValues() {
        XCTAssertEqual(TokenCountFormat.compact(Int.max), "9223372T")
        XCTAssertEqual(TokenCountFormat.compact(Int.min), "-9223372T")
    }
}
