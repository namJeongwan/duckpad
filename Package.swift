// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Duckpad",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DuckpadDomain", targets: ["DuckpadDomain"]),
        .library(name: "DuckpadApplication", targets: ["DuckpadApplication"]),
        .library(name: "DuckpadInfrastructure", targets: ["DuckpadInfrastructure"]),
        .library(name: "DuckpadPresentation", targets: ["DuckpadPresentation"]),
        .executable(name: "DuckpadApp", targets: ["DuckpadApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.2.4"),
    ],
    targets: [
        .target(name: "DuckpadDomain"),
        .target(name: "DuckpadApplication", dependencies: ["DuckpadDomain"]),
        .target(
            name: "DuckpadInfrastructure",
            dependencies: ["DuckpadApplication", "DuckpadDomain"]
        ),
        .target(
            name: "DuckpadPresentation",
            dependencies: ["DuckpadApplication", "DuckpadDomain"]
        ),
        .executableTarget(
            name: "DuckpadApp",
            dependencies: [
                "DuckpadApplication",
                "DuckpadDomain",
                "DuckpadInfrastructure",
                "DuckpadPresentation",
            ],
            resources: [
                .copy("Resources/AppIcon.iconset"),
                .copy("Resources/Duckpad.icns"),
                .copy("Resources/AppIcon-SOURCE.md"),
            ]
        ),
        .testTarget(
            name: "DuckpadDomainTests",
            dependencies: ["DuckpadDomain", .product(name: "Testing", package: "swift-testing")]
        ),
        .testTarget(
            name: "DuckpadApplicationTests",
            dependencies: [
                "DuckpadApplication",
                "DuckpadDomain",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "DuckpadPresentationTests",
            dependencies: [
                "DuckpadApplication",
                "DuckpadDomain",
                "DuckpadPresentation",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
