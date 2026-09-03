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
        .executable(name: "DuckpadPluginHost", targets: ["DuckpadPluginHost"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.2.4"),
    ],
    targets: [
        .target(
            name: "DuckpadICUBridge",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("icucore")]
        ),
        .target(
            name: "DuckpadLexilla",
            path: "Vendor/Lexilla/5.5.3",
            sources: ["src/Lexilla.cxx", "lexlib", "lexers"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("lexlib"),
                .headerSearchPath("scintilla/include"),
                .define("LEXILLA_NO_EXPORT"),
                .define("NDEBUG", .when(configuration: .release)),
            ]
        ),
        .target(
            name: "DuckpadScintillaBridge",
            dependencies: ["DuckpadLexilla"],
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
        .target(
            name: "DuckpadWAMRRuntime",
            path: "Vendor/WAMR/2.4.5",
            sources: [
                "core/iwasm/common/arch/invokeNative_general.c",
                "core/iwasm/common/wasm_blocking_op.c",
                "core/iwasm/common/wasm_c_api.c",
                "core/iwasm/common/wasm_exec_env.c",
                "core/iwasm/common/wasm_loader_common.c",
                "core/iwasm/common/wasm_memory.c",
                "core/iwasm/common/wasm_native.c",
                "core/iwasm/common/wasm_runtime_common.c",
                "core/iwasm/common/wasm_shared_memory.c",
                "core/iwasm/interpreter/wasm_interp_classic.c",
                "core/iwasm/interpreter/wasm_loader.c",
                "core/iwasm/interpreter/wasm_runtime.c",
                "core/shared/mem-alloc/mem_alloc.c",
                "core/shared/mem-alloc/ems/ems_alloc.c",
                "core/shared/mem-alloc/ems/ems_gc.c",
                "core/shared/mem-alloc/ems/ems_hmu.c",
                "core/shared/mem-alloc/ems/ems_kfc.c",
                "core/shared/platform/common/memory/mremap.c",
                "core/shared/platform/common/posix/posix_blocking_op.c",
                "core/shared/platform/common/posix/posix_malloc.c",
                "core/shared/platform/common/posix/posix_memmap.c",
                "core/shared/platform/common/posix/posix_sleep.c",
                "core/shared/platform/common/posix/posix_thread.c",
                "core/shared/platform/common/posix/posix_time.c",
                "core/shared/platform/darwin/platform_init.c",
                "core/shared/utils/bh_assert.c",
                "core/shared/utils/bh_bitmap.c",
                "core/shared/utils/bh_common.c",
                "core/shared/utils/bh_hashmap.c",
                "core/shared/utils/bh_leb128.c",
                "core/shared/utils/bh_list.c",
                "core/shared/utils/bh_log.c",
                "core/shared/utils/bh_queue.c",
                "core/shared/utils/bh_vector.c",
                "core/shared/utils/runtime_timer.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("core"),
                .headerSearchPath("core/iwasm/common"),
                .headerSearchPath("core/iwasm/interpreter"),
                .headerSearchPath("core/iwasm/include"),
                .headerSearchPath("core/shared/mem-alloc"),
                .headerSearchPath("core/shared/mem-alloc/ems"),
                .headerSearchPath("core/shared/platform/include"),
                .headerSearchPath("core/shared/platform/darwin"),
                .headerSearchPath("core/shared/platform/common/posix"),
                .headerSearchPath("core/shared/utils"),
                .define("BH_PLATFORM_DARWIN"),
                .define("BH_MALLOC", to: "wasm_runtime_malloc"),
                .define("BH_FREE", to: "wasm_runtime_free"),
                .define("WASM_ENABLE_INTERP", to: "1"),
                .define("WASM_ENABLE_FAST_INTERP", to: "0"),
                .define("WASM_ENABLE_AOT", to: "0"),
                .define("WASM_ENABLE_JIT", to: "0"),
                .define("WASM_ENABLE_FAST_JIT", to: "0"),
                .define("WASM_ENABLE_LIBC_BUILTIN", to: "0"),
                .define("WASM_ENABLE_LIBC_WASI", to: "0"),
                .define("WASM_ENABLE_UVWASI", to: "0"),
                .define("WASM_ENABLE_THREAD_MGR", to: "0"),
                .define("WASM_ENABLE_SHARED_MEMORY", to: "0"),
                .define("WASM_ENABLE_BULK_MEMORY", to: "1"),
                .define("WASM_ENABLE_REF_TYPES", to: "1"),
                .define("WASM_ENABLE_MULTI_MODULE", to: "0"),
                .define("WASM_ENABLE_MINI_LOADER", to: "0"),
                .define("WASM_ENABLE_INVOKE_NATIVE_GENERAL", to: "1"),
                .define("WASM_DISABLE_APP_ENTRY", to: "1"),
                .define("WASM_DISABLE_HW_BOUND_CHECK", to: "1"),
            ]
        ),
        .target(
            name: "DuckpadWAMRBridge",
            dependencies: ["DuckpadWAMRRuntime"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "DuckpadPluginSupport",
            dependencies: ["DuckpadApplication", "DuckpadDomain"]
        ),
        .target(name: "DuckpadDomain"),
        .target(name: "DuckpadApplication", dependencies: ["DuckpadDomain"]),
        .target(
            name: "DuckpadInfrastructure",
            dependencies: ["DuckpadApplication", "DuckpadDomain", "DuckpadICUBridge", "DuckpadPluginSupport"],
            resources: [
                .process("Resources/Languages.json"),
                .copy("Resources/BundledExtensions"),
            ]
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
        .executableTarget(
            name: "DuckpadPluginHost",
            dependencies: ["DuckpadApplication", "DuckpadDomain", "DuckpadPluginSupport", "DuckpadWAMRBridge"]
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
                "DuckpadInfrastructure",
                "DuckpadPluginSupport",
                "DuckpadPluginHost",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "DuckpadInfrastructureTests",
            dependencies: [
                "DuckpadApplication",
                "DuckpadDomain",
                "DuckpadInfrastructure",
                "DuckpadPluginSupport",
                "DuckpadWAMRBridge",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "DuckpadPresentationTests",
            dependencies: [
                "DuckpadApplication",
                "DuckpadDomain",
                "DuckpadInfrastructure",
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
