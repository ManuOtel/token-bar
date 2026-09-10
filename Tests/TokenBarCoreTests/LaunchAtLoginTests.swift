import XCTest
@testable import TokenBarCore

/// Pins the pure launch-at-login policy. No system calls, no paths.
final class LaunchAtLoginTests: XCTestCase {
    func testBundledRequiresIdentifierAndAppExtension() {
        XCTAssertTrue(LaunchAtLoginPolicy.isBundled(
            bundleIdentifier: "com.manuotel.TokenBar", bundlePathExtension: "app"))
        XCTAssertFalse(LaunchAtLoginPolicy.isBundled(
            bundleIdentifier: nil, bundlePathExtension: "app"))
        XCTAssertFalse(LaunchAtLoginPolicy.isBundled(
            bundleIdentifier: "", bundlePathExtension: "app"))
        XCTAssertFalse(LaunchAtLoginPolicy.isBundled(
            bundleIdentifier: "com.manuotel.TokenBar", bundlePathExtension: nil))
        // swift run has no .app bundle.
        XCTAssertFalse(LaunchAtLoginPolicy.isBundled(
            bundleIdentifier: "com.manuotel.TokenBar", bundlePathExtension: "xctest"))
    }

    func testUnbundledStatusPointsAtBuildScript() {
        let message = LaunchAtLoginPolicy.statusMessage(
            isBundled: false, isEnabled: false, isAvailable: true)
        XCTAssertTrue(message.contains("unbundled"))
        XCTAssertTrue(message.contains("TokenBar.app"))
        XCTAssertFalse(message.contains("/"))
    }

    func testBundledStatusReflectsToggle() {
        XCTAssertTrue(LaunchAtLoginPolicy.statusMessage(
            isBundled: true, isEnabled: true, isAvailable: true).contains("on"))
        XCTAssertTrue(LaunchAtLoginPolicy.statusMessage(
            isBundled: true, isEnabled: false, isAvailable: true).contains("off"))
    }

    func testUnavailableWinsOverBundled() {
        let message = LaunchAtLoginPolicy.statusMessage(
            isBundled: true, isEnabled: true, isAvailable: false)
        XCTAssertTrue(message.contains("unavailable"))
    }

    func testHelpTextNeverLeaksPaths() {
        for message in [
            LaunchAtLoginPolicy.helpText(isBundled: false, isAvailable: true),
            LaunchAtLoginPolicy.helpText(isBundled: true, isAvailable: true),
            LaunchAtLoginPolicy.helpText(isBundled: true, isAvailable: false),
        ] {
            XCTAssertFalse(message.contains("/Users"))
            XCTAssertFalse(message.contains("/tmp"))
        }
        XCTAssertTrue(LaunchAtLoginPolicy.helpText(isBundled: false, isAvailable: true)
            .contains("build-app.sh"))
    }
}
