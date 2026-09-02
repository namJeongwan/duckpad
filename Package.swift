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
        .library(name: "DuckpadEditorAdapter", targets: ["DuckpadEditorAdapter"]),
        .executable(name: "DuckpadApp", targets: ["DuckpadApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.2.4"),
    ],
    targets: [
        .target(
            name: "DuckpadScintillaBridge",
            path: "Vendor/Scintilla/5.6.6",
            sources: [
                "bridge/DuckpadScintillaBridge.mm",
                "cocoa/InfoBar.mm",
                "cocoa/PlatCocoa.mm",
                "cocoa/ScintillaCocoa.mm",
                "cocoa/ScintillaView.mm",
                "src/AutoComplete.cxx", "src/CallTip.cxx", "src/CaseConvert.cxx",
                "src/CaseFolder.cxx", "src/CellBuffer.cxx", "src/ChangeHistory.cxx",
                "src/CharClassify.cxx", "src/CharacterCategoryMap.cxx",
                "src/CharacterType.cxx", "src/ContractionState.cxx", "src/DBCS.cxx",
                "src/Decoration.cxx", "src/Document.cxx", "src/EditModel.cxx",
                "src/Editor.cxx", "src/EditView.cxx", "src/Geometry.cxx",
                "src/Indicator.cxx", "src/KeyMap.cxx", "src/LineMarker.cxx",
                "src/MarginView.cxx", "src/PerLine.cxx", "src/PositionCache.cxx",
                "src/RESearch.cxx", "src/RunStyles.cxx", "src/ScintillaBase.cxx",
                "src/Selection.cxx", "src/Style.cxx", "src/UndoHistory.cxx",
                "src/UniConversion.cxx", "src/UniqueString.cxx", "src/ViewStyle.cxx",
                "src/XPM.cxx",
            ],
            publicHeadersPath: "bridge/include",
            cxxSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("src"),
                .headerSearchPath("cocoa"),
                .define("NDEBUG", .when(configuration: .release)),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore"),
            ]
        ),
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
        .target(
            name: "DuckpadEditorAdapter",
            dependencies: [
                "DuckpadApplication",
                "DuckpadDomain",
                "DuckpadScintillaBridge",
            ],
            resources: [.copy("Resources/ScintillaCursors")]
        ),
        .executableTarget(
            name: "DuckpadApp",
            dependencies: [
                "DuckpadApplication",
                "DuckpadDomain",
                "DuckpadInfrastructure",
                "DuckpadPresentation",
                "DuckpadEditorAdapter",
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
            name: "DuckpadInfrastructureTests",
            dependencies: [
                "DuckpadApplication",
                "DuckpadDomain",
                "DuckpadInfrastructure",
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
        .testTarget(
            name: "DuckpadEditorAdapterTests",
            dependencies: [
                "DuckpadApplication",
                "DuckpadDomain",
                "DuckpadEditorAdapter",
                "DuckpadInfrastructure",
                "DuckpadPresentation",
                "DuckpadScintillaBridge",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
