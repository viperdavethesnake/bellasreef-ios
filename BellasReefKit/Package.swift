// swift-tools-version: 6.2
// Bella's Reef iOS — closed source. See LICENSE.

import PackageDescription

let package = Package(
    name: "BellasReefKit",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "BellasReefKit", targets: ["BellasReefKit"]),
        .library(name: "BellasReefAPI", targets: ["BellasReefAPI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.8.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.1.0"),
    ],
    targets: [
        // Nothing in this target is written by hand. The whole point of PRD G3:
        // a contract change becomes a compile error here rather than a runtime
        // surprise on a tank.
        .target(
            name: "BellasReefAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
            ]
        ),
        .target(
            name: "BellasReefKit",
            dependencies: ["BellasReefAPI"]
        ),
        .testTarget(
            name: "BellasReefKitTests",
            dependencies: ["BellasReefKit"]
        ),
    ]
)
