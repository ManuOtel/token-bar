// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TokenBarCore", targets: ["TokenBarCore"]),
        .executable(name: "TokenBarApp", targets: ["TokenBarApp"]),
    ],
    targets: [
        .target(name: "TokenBarCore", path: "Sources/TokenBarCore"),
        .executableTarget(
            name: "TokenBarApp",
            dependencies: ["TokenBarCore"],
            path: "Sources/TokenBarApp"
        ),
        .testTarget(
            name: "TokenBarCoreTests",
            dependencies: ["TokenBarCore"],
            path: "Tests/TokenBarCoreTests"
        ),
    ]
)
