// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TokenBarCore", targets: ["TokenBarCore"]),
        .executable(name: "TokenBarApp", targets: ["TokenBarApp"]),
        .executable(name: "TokenBarCLI", targets: ["TokenBarCLI"]),
    ],
    targets: [
        .target(name: "TokenBarCore", path: "Sources/TokenBarCore"),
        .executableTarget(
            name: "TokenBarApp",
            dependencies: ["TokenBarCore"],
            path: "Sources/TokenBarApp"
        ),
        .executableTarget(
            name: "TokenBarCLI",
            dependencies: ["TokenBarCore"],
            path: "Sources/TokenBarCLI"
        ),
        .testTarget(
            name: "TokenBarCoreTests",
            dependencies: ["TokenBarCore"],
            path: "Tests/TokenBarCoreTests"
        ),
    ]
)
