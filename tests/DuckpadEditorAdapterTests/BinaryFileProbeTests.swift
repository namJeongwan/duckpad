import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadLocalization
@testable import DuckpadPresentation
import Testing

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_BINARY_PROBE_PATH"] != nil))
@MainActor
struct BinaryFileProbeTests {
    @Test func realBinaryOpensInFullReadOnly() async throws {
        let language = ProcessInfo.processInfo.environment["DUCKPAD_BINARY_PROBE_LANGUAGE"] == "ko" ? AppLanguage.korean : .english
        L10n.configure(language: language)
        let path = try #require(ProcessInfo.processInfo.environment["DUCKPAD_BINARY_PROBE_PATH"])
        let url = URL(fileURLWithPath: path)
        let before = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore())
        let controller = DuckpadWindowController(workspace: workspace, editorAdapter: editor,
            editorView: editor.view, fileUseCase: files, automaticallyStarts: false)
        defer { controller.close(); editor.invalidate() }
        _ = await workspace.start()
        var heartbeatCount = 0
        var previousHeartbeat = ContinuousClock.now
        var longestHeartbeatGap = Duration.zero
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                longestHeartbeatGap = max(longestHeartbeatGap, previousHeartbeat.duration(to: .now))
                previousHeartbeat = .now
                heartbeatCount += 1
            }
        }
        defer { heartbeat.cancel() }
        let start = ContinuousClock.now
        var firstProgress: Duration?
        var firstContent: Duration?
        var capturedLoadingImage = false
        let renderProgress = files.onLoadingProgress
        files.onLoadingProgress = {
            renderProgress?()
            guard let progress = files.loadingProgress else { return }
            if firstProgress == nil { firstProgress = start.duration(to: .now) }
            guard progress.loadedByteCount > 0,
                  let total = progress.totalByteCount, progress.loadedByteCount < total,
                  workspace.activeFileContext()?.binding?.isReadOnly == true,
                  let content = controller.window?.contentView else { return }
            if firstContent == nil {
                content.layoutSubtreeIfNeeded()
                content.displayIfNeeded()
                firstContent = start.duration(to: .now)
            }
            if !capturedLoadingImage, progress.percent >= 10,
               let directory = ProcessInfo.processInfo.environment["DUCKPAD_BINARY_PROBE_IMAGES"] {
                capturedLoadingImage = true
                do {
                    let root = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    content.layoutSubtreeIfNeeded()
                    let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: root.appendingPathComponent("binary-loading.png"))
                } catch { Issue.record("Loading screenshot failed: \(error)") }
            }
        }
        let outcome: FileOpenOutcome
        if ProcessInfo.processInfo.environment["DUCKPAD_BINARY_PROBE_SIDEBAR"] == "1" {
            let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: archive) }
            let roots = LocalWorkspaceRootStore(archiveURL: archive)
            let root = try await roots.addRoot(url.deletingLastPathComponent())
            let entry = try #require(try await roots.children(rootID: root.id, relativeDirectory: "")
                .first(where: { $0.name == url.lastPathComponent }))
            outcome = await files.open(try await roots.readFile(entry))
        } else {
            outcome = await files.open(url)
        }
        guard case .opened = outcome else { Issue.record("Binary did not open: \(outcome)"); return }
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        let duration = start.duration(to: .now)
        longestHeartbeatGap = max(longestHeartbeatGap, previousHeartbeat.duration(to: .now))
        let binding = try #require(workspace.activeFileContext()?.binding)
        #expect(firstProgress != nil)
        #expect(firstContent != nil)
        #expect(files.loadingProgress == nil)
        #expect(binding.binaryByteCount == before.fileSize)
        let native = try #require(editor.activeScintillaView)
        #expect(native.documentByteLength == UInt(try #require(before.fileSize)))
        #expect(native.isInputEnabled == false)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let tailOffset = max(0, (before.fileSize ?? 0) - 64)
        try handle.seek(toOffset: UInt64(tailOffset))
        let tail = try handle.readToEnd() ?? Data()
        #expect(try native.utf8Bytes(in: NSRange(location: tailOffset, length: tail.count)) == tail)
        #expect(editor.recoveryCapture(for: try #require(workspace.snapshot().activeBuffer).bufferID)?.baseUTF8.isEmpty == true)
        #expect(heartbeatCount > 0)
        editor.perform(.selectAll)
        #expect(editor.editorStatus?.selectedCharacters == before.fileSize)
        native.restoreCaretUTF8Position(UInt(tailOffset), anchorPosition: UInt(tailOffset),
            firstVisibleLine: native.lineCount - 1, horizontalScrollOffset: 0, wordWrapEnabled: false)
        try await Task.sleep(for: .milliseconds(30))
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        editor.onEditorStatusChange?()
        #expect(await files.saveActive() == .failed(.readOnly))
        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        #expect(before.fileSize == after.fileSize)
        #expect(before.contentModificationDate == after.contentModificationDate)
        print("Full binary: original=\(before.fileSize ?? 0) bytes, loaded=\(binding.binaryByteCount ?? 0) bytes, first-progress=\(String(describing: firstProgress)), first-content=\(String(describing: firstContent)), open+layout=\(duration), longest-main-gap=\(longestHeartbeatGap)")
        if let directory = ProcessInfo.processInfo.environment["DUCKPAD_BINARY_PROBE_IMAGES"] {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: root.appendingPathComponent("binary-full.png"))
        }
    }
}
