// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChromeWatch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ChromeWatch", targets: ["ChromeWatch"]),
    ],
    targets: [
        // Process reading, detection and classification. No UI, so it can be unit tested.
        .target(name: "ChromeWatchCore"),
        // The menu bar app.
        .executableTarget(name: "ChromeWatch", dependencies: ["ChromeWatchCore"]),
        .testTarget(name: "ChromeWatchCoreTests", dependencies: ["ChromeWatchCore"]),
    ],
    swiftLanguageModes: [.v5]
)
