// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RemodexTransport",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "RemodexTransport", targets: ["RemodexTransport"])],
    dependencies: [
        .package(url: "https://github.com/launchdarkly/swift-eventsource.git", exact: "3.3.0"),
    ],
    targets: [
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/stasel/WebRTC/releases/download/152.0.0/WebRTC-M152.xcframework.zip",
            checksum: "115cb9944248a3302c0c8af17462e2576a28ccc7adef9f6a1fe66ee75d9e1cc8"
        ),
        .target(name: "RemodexTransport", dependencies: ["WebRTC", .product(name: "LDSwiftEventSource", package: "swift-eventsource")], path: "SharedTransport"),
    ]
)
