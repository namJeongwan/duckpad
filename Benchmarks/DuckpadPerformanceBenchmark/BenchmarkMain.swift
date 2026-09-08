import AppKit
import Darwin
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadPresentation
import DuckpadScintillaBridge
import Foundation

private struct BudgetFile: Decodable {
    let schemaVersion: Int
    let metrics: [Budget]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case metrics
    }
}

private struct Budget: Decodable {
    let id: String
    let unit: String
    let maximum: Double
    let aggregation: String
}

private struct Measurement: Codable {
    let id: String
    let unit: String
    let measured: Double
    let maximum: Double
    let aggregation: String
    let passed: Bool
}

private struct MachineProfile: Codable {
    let architecture: String
    let hardwareModel: String
    let operatingSystem: String
    let processorCount: Int
    let physicalMemoryBytes: UInt64

    enum CodingKeys: String, CodingKey {
        case architecture
        case hardwareModel = "hardware_model"
        case operatingSystem = "operating_system"
        case processorCount = "processor_count"
        case physicalMemoryBytes = "physical_memory_bytes"
    }
}

private struct Report: Codable {
    let schemaVersion = 1
    let status: String
    let profile: MachineProfile
    let measurements: [Measurement]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case status, profile, measurements
    }
}

private enum BenchmarkFailure: Error, CustomStringConvertible {
    case invalidArguments
    case invalidBudgets(String)
    case invariant(String)

    var description: String {
        switch self {
        case .invalidArguments:
            return "usage: DuckpadPerformanceBenchmark --warm-launch-ms <positive-number>"
        case .invalidBudgets(let reason), .invariant(let reason):
            return reason
        }
    }
}

@main
private enum DuckpadPerformanceBenchmark {
    private static let expectedMetricIDs: Set<String> = [
        "warm_launch_ready",
        "typing_latency_p95",
        "open_100mb",
        "reflow_200_tabs_p95",
        "folder_search_p95",
        "fold_recovery_10000",
    ]

    @MainActor
    static func main() async {
        do {
            let warmLaunch = try parseWarmLaunch(arguments: Array(CommandLine.arguments.dropFirst()))
            let budgets = try loadBudgets()
            _ = NSApplication.shared
            NSApplication.shared.setActivationPolicy(.prohibited)

            let typing = try await measureTypingLatency()
            let largeOpen = try await measureLargeOpen()
            let tabReflow = measureTabReflow()
            let folderSearch = try await measureFolderSearch()
            let foldRecovery = try measureFoldRecovery10K()
            let values = [
                "warm_launch_ready": warmLaunch,
                "typing_latency_p95": typing,
                "open_100mb": largeOpen,
                "reflow_200_tabs_p95": tabReflow,
                "folder_search_p95": folderSearch,
                "fold_recovery_10000": foldRecovery,
            ]
            let measurements = budgets.metrics.map { budget in
                let measured = values[budget.id]!
                return Measurement(
                    id: budget.id,
                    unit: budget.unit,
                    measured: measured,
                    maximum: budget.maximum,
                    aggregation: budget.aggregation,
                    passed: measured <= budget.maximum
                )
            }
            let passed = measurements.allSatisfy(\.passed)
            let report = Report(
                status: passed ? "pass" : "fail",
                profile: machineProfile(),
                measurements: measurements
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(report))
            FileHandle.standardOutput.write(Data("\n".utf8))
            if !passed { Darwin.exit(1) }
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            Darwin.exit(2)
        }
    }

    private static func parseWarmLaunch(arguments: [String]) throws -> Double {
        guard arguments.count == 2, arguments[0] == "--warm-launch-ms",
              let value = Double(arguments[1]), value.isFinite, value > 0 else {
            throw BenchmarkFailure.invalidArguments
        }
        return value
    }

    private static func loadBudgets() throws -> BudgetFile {
        guard let url = Bundle.module.url(forResource: "performance-budgets.v1", withExtension: "json") else {
            throw BenchmarkFailure.invalidBudgets("bundled performance budgets are missing")
        }
        let decoded = try JSONDecoder().decode(BudgetFile.self, from: Data(contentsOf: url))
        let ids = decoded.metrics.map(\.id)
        guard decoded.schemaVersion == 1,
              decoded.metrics.count == expectedMetricIDs.count,
              Set(ids) == expectedMetricIDs,
              Set(ids).count == ids.count,
              decoded.metrics.allSatisfy({
                  $0.unit == "milliseconds" && $0.maximum.isFinite && $0.maximum > 0
                      && !$0.aggregation.isEmpty
              }) else {
            throw BenchmarkFailure.invalidBudgets("performance budget schema or metric inventory is invalid")
        }
        return decoded
    }

    @MainActor
    private static func makeHostedEditor() -> (DPScintillaEditorView, NSWindow) {
        ScintillaEditorAdapter.prepareResources()
        let frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let view = DPScintillaEditorView(frame: frame)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderOut(nil)
        return (view, window)
    }

    @MainActor
    private static func measureTypingLatency() async throws -> Double {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        guard await workspace.start() == .saved,
              let descriptor = workspace.snapshot().activeBuffer else {
            throw BenchmarkFailure.invariant("typing benchmark workspace did not start")
        }
        let editor = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { change in binding.render(change) }
        editor.install(.init(bufferID: descriptor.bufferID, revision: descriptor.revision, text: "Duckpad\n"))
        binding.render(workspace.snapshot())
        let frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.view
        window.orderOut(nil)
        defer { window.orderOut(nil) }
        guard let view = editor.activeScintillaView else {
            throw BenchmarkFailure.invariant("typing benchmark editor was not installed")
        }
        for _ in 0..<30 { view.insertCommittedText("x") }
        var samples: [Double] = []
        samples.reserveCapacity(300)
        for _ in 0..<300 {
            let start = ContinuousClock.now
            view.insertCommittedText("x")
            samples.append(milliseconds(start.duration(to: ContinuousClock.now)))
        }
        guard view.documentByteLength == "Duckpad\n".utf8.count + 330,
              workspace.snapshot().activeBuffer?.revision == 330 else {
            throw BenchmarkFailure.invariant("typing benchmark lost editor/workspace revisions")
        }
        return percentile95(samples)
    }

    @MainActor
    private static func measureLargeOpen() async throws -> Double {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("duckpad-large-open-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let fixtureURL = root.appendingPathComponent("large-100mb.txt", isDirectory: false)
        let byteCount = 100 * 1_024 * 1_024
        var fixture = Data(repeating: 0x61, count: byteCount)
        fixture.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for lineEnding in stride(from: 79, to: byteCount, by: 80) {
                bytes[lineEnding] = 0x0A
            }
        }
        try fixture.write(to: fixtureURL, options: .withoutOverwriting)
        fixture = Data()

        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        guard await workspace.start() == .saved else {
            throw BenchmarkFailure.invariant("large-open benchmark workspace did not start")
        }
        let editor = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { change in binding.render(change) }
        binding.render(workspace.snapshot())
        let frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.view
        window.orderOut(nil)
        defer { window.orderOut(nil) }
        let fileStore = LocalTextFileStore(
            bookmarkArchiveURL: root.appendingPathComponent("bookmarks.json", isDirectory: false)
        )
        let fileUseCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: fileStore)
        let start = ContinuousClock.now
        let outcome = await fileUseCase.open(fixtureURL)
        let measured = milliseconds(start.duration(to: ContinuousClock.now))
        guard case .opened = outcome,
              let openedView = editor.activeScintillaView,
              openedView.documentByteLength == UInt(byteCount) else {
            throw BenchmarkFailure.invariant("100 MB benchmark did not complete the file-open pipeline")
        }
        return measured
    }

    private static func measureTabReflow() -> Double {
        let engine = TabFlowLayoutEngine()
        let widths = (0..<200).map { index in CGFloat(88 + (index * 17) % 123) }
        let containers: [CGFloat] = [320, 600, 900, 1_200]
        var samples: [Double] = []
        samples.reserveCapacity(500)
        for iteration in 0..<500 {
            let start = ContinuousClock.now
            let result = engine.layout(
                itemWidths: widths,
                containerWidth: containers[iteration % containers.count]
            )
            precondition(result.frames.count == 200 && result.rowIndices.count == 200)
            samples.append(milliseconds(start.duration(to: ContinuousClock.now)))
        }
        return percentile95(samples)
    }

    private static func measureFolderSearch() async throws -> Double {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("duckpad-performance-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let payload = Data((String(repeating: "a", count: 8_160) + " duckpad-needle\n").utf8)
        for directoryIndex in 0..<20 {
            let directory = root.appendingPathComponent("group-\(directoryIndex)", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            for fileIndex in 0..<100 {
                let file = directory.appendingPathComponent("document-\(fileIndex).txt", isDirectory: false)
                try payload.write(to: file, options: .withoutOverwriting)
            }
        }
        let useCase = FolderSearchUseCase(
            store: LocalFolderSearchFileStore(),
            regexEngine: ICURegexEngine()
        )
        var samples: [Double] = []
        for _ in 0..<3 {
            let start = ContinuousClock.now
            let result = try await useCase.search(
                rootPath: root.path,
                query: SearchQuery(pattern: "duckpad-needle", options: SearchOptions(matchCase: true))
            )
            samples.append(milliseconds(start.duration(to: ContinuousClock.now)))
            guard result.searchedFileCount == 2_000, result.matchCount == 2_000, !result.isTruncated else {
                throw BenchmarkFailure.invariant("folder benchmark fixture was not searched completely")
            }
        }
        return samples.max() ?? .infinity
    }

    @MainActor
    private static func measureFoldRecovery10K() throws -> Double {
        let headerCount = FoldRecoveryState.maximumContractedHeaderCount
        var source = "namespace duckpad_benchmark {\n"
        source.reserveCapacity(240_000)
        for index in 0..<(headerCount - 1) {
            source += "void fold_\(index)() {\n}\n"
        }
        source += "}\n"
        let expectedHeaderLines = [0] + (0..<(headerCount - 1)).map { 1 + $0 * 2 }

        ScintillaEditorAdapter.prepareResources()
        let frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let splitView = NSSplitView(frame: frame)
        splitView.isVertical = true
        let primary = DPScintillaEditorView(frame: frame)
        let secondary = DPScintillaEditorView(frame: frame)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = splitView
        splitView.addArrangedSubview(primary)
        splitView.addArrangedSubview(secondary)
        window.orderOut(nil)
        defer {
            primary.onFoldStateChange = nil
            primary.onFoldRecoveryProgress = nil
            secondary.onFoldStateChange = nil
            secondary.onFoldRecoveryProgress = nil
            window.orderOut(nil)
        }

        try primary.loadUTF8(Data(source.utf8), revision: 0)
        secondary.shareDocument(with: primary)
        secondary.synchronizeRevision(primary.revision)
        for view in [primary, secondary] {
            guard view.applyLexerNamed(
                "cpp",
                keywords: ["namespace", "void"],
                tabWidth: 4,
                useTabs: false,
                folding: true,
                braceMatching: true,
                maximumStyleBytes: 2_000_000
            ) else {
                throw BenchmarkFailure.invariant("10,000-fold benchmark could not apply C++ folding")
            }
        }

        let start = ContinuousClock.now
        guard primary.collapseAllFolds() else {
            throw BenchmarkFailure.invariant("10,000-fold benchmark could not contract its fixture")
        }
        let nativeCapture = primary
            .contractedFoldHeaderLines(maximumCount: UInt(headerCount + 1))
            .map(\.intValue)
        let captured = FoldRecoveryState(contractedHeaderLines: nativeCapture)
        guard nativeCapture == expectedHeaderLines,
              captured.contractedHeaderLines == nativeCapture else {
            throw BenchmarkFailure.invariant("10,000-fold benchmark did not capture exactly 10,000 canonical headers")
        }
        let pending = secondary.restoreContractedFoldHeaderLines(
            captured.contractedHeaderLines.map { NSNumber(value: $0) }
        )
        let restored = secondary
            .contractedFoldHeaderLines(maximumCount: UInt(headerCount + 1))
            .map(\.intValue)
        let measured = milliseconds(start.duration(to: ContinuousClock.now))
        guard pending.isEmpty, restored == captured.contractedHeaderLines else {
            throw BenchmarkFailure.invariant("10,000-fold benchmark did not restore the complete captured state")
        }

        guard primary.expandAllFolds(),
              primary.contractedFoldHeaderLines(maximumCount: 1).isEmpty,
              secondary.contractedFoldHeaderLines(maximumCount: UInt(headerCount + 1)).map(\.intValue) == restored else {
            throw BenchmarkFailure.invariant("shared-document fold panes did not remain independent")
        }
        return measured
    }

    private static func percentile95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1))
        return sorted[index]
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func machineProfile() -> MachineProfile {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        let process = ProcessInfo.processInfo
        return MachineProfile(
            architecture: architecture,
            hardwareModel: sysctlString("hw.model"),
            operatingSystem: process.operatingSystemVersionString,
            processorCount: process.processorCount,
            physicalMemoryBytes: process.physicalMemory
        )
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
