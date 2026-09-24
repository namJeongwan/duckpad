import DuckpadDomain
import Foundation

@MainActor
public final class DocumentConventionsUseCase {
    private let reader: any EditorConfigReading
    private let workspace: ScratchWorkspaceUseCase
    private let editor: any FormattingEditorPort
    private var requestedPath: String?
    private var rulesByPath: [String: EditorConventions] = [:]
    private var detected: [BufferID: LanguageIndentation] = [:]
    private var sampled = Set<BufferID>()
    private var task: Task<Void, Never>?
    public var settings = AppSettings.defaults
    public var onRulesChanged: (() -> Void)?

    public var mayAffectSave: Bool {
        settings.editorConfigEnabled || settings.trimWhitespaceOnSave || settings.finalNewlineOnSave
    }

    public init(reader: any EditorConfigReading, workspace: ScratchWorkspaceUseCase, editor: any FormattingEditorPort) {
        self.reader = reader; self.workspace = workspace; self.editor = editor
    }

    public func indentation(defaults: LanguageIndentation) -> (LanguageIndentation, Int) {
        guard let context = workspace.activeFileContext() else { return (defaults, defaults.width) }
        let path = context.binding?.canonicalPath
        if settings.editorConfigEnabled, requestedPath != path {
            requestedPath = path
            task?.cancel()
            if let path {
                task = Task { [weak self, reader] in
                    let rules = await reader.conventions(for: URL(fileURLWithPath: path))
                    guard let self, !Task.isCancelled, self.requestedPath == path else { return }
                    self.rulesByPath[path] = rules
                    self.onRulesChanged?()
                }
            }
        }
        let buffer = context.buffer.bufferID
        // A scratch document can acquire a convention once it has enough text.
        if settings.detectIndentation, !sampled.contains(buffer) {
            let prefix = editor.detectionPrefix(maximumBytes: IndentationDetector.maximumProbeBytes)
            if let match = IndentationDetector.detect(prefix) { detected[buffer] = match; sampled.insert(buffer) }
            else if path != nil { sampled.insert(buffer) }
        }
        let base = settings.overrideLanguageIndentation
            ? LanguageIndentation(width: settings.indentationWidth, useTabs: settings.indentationUsesTabs) : defaults
        let inferred: LanguageIndentation
        if settings.detectIndentation, let match = detected[buffer] {
            inferred = match.useTabs ? .init(width: base.width, useTabs: true) : match
        } else { inferred = base }
        let rules = settings.editorConfigEnabled ? path.flatMap { rulesByPath[$0] } ?? .init() : .init()
        let result = rules.indentation(defaults: inferred)
        return (result.indent, result.tabWidth)
    }

    public func rules(for file: URL) async -> EditorConventions {
        guard settings.editorConfigEnabled else { return .init() }
        let result = await reader.conventions(for: file)
        rulesByPath[file.path] = result
        return result
    }

    public func documentOpened(_ buffer: BufferID) {
        sampled.remove(buffer); detected.removeValue(forKey: buffer)
        let live = Set(workspace.snapshot().tabs.map { $0.buffer.bufferID })
        sampled.formIntersection(live)
        detected = detected.filter { live.contains($0.key) }
        let paths = Set(workspace.snapshot().tabs.compactMap { workspace.fileContext(tabID: $0.id)?.binding?.canonicalPath })
        rulesByPath = rulesByPath.filter { paths.contains($0.key) }
        onRulesChanged?()
    }

    public func settingsDidChange(_ settings: AppSettings) {
        self.settings = settings
        requestedPath = nil
        rulesByPath.removeAll()
        task?.cancel()
        onRulesChanged?()
    }

    /// Re-read rules for the destination (including Save As), then apply changes
    /// through the editor transaction so disk, undo and recovery agree.
    public func prepareSave(context: FileWorkspaceContext, destination: URL) async throws -> (FileWorkspaceContext, EditorConventions) {
        let preferences = settings
        let rules = preferences.editorConfigEnabled ? await reader.conventions(for: destination) : .init()
        try Task.checkCancellation()
        guard workspace.activeFileContext() == context else { throw FormattingFailure.staleDocument }
        rulesByPath[destination.path] = rules
        let trim = rules.trimTrailingWhitespace ?? preferences.trimWhitespaceOnSave
        let newline = rules.insertFinalNewline ?? (preferences.finalNewlineOnSave ? true : nil)
        guard trim || newline != nil else { return (context, rules) }
        guard editor.isReadyForFormatting(context.buffer),
              let capture = editor.recoveryCapture(for: context.buffer.bufferID), capture.revision == context.buffer.revision else {
            throw FormattingFailure.staleDocument
        }
        let ending = rules.lineEnding ?? context.binding?.lineEnding ?? .lf
        let edits = try await Task.detached(priority: .userInitiated) {
            try SaveCleanupEdits.make(utf8: capture.materializedSnapshot().utf8, trim: trim, finalNewline: newline, lineEnding: ending)
        }.value
        try Task.checkCancellation()
        guard workspace.activeFileContext() == context, editor.isReadyForFormatting(context.buffer) else { throw FormattingFailure.staleDocument }
        guard !edits.isEmpty else { return (context, rules) }
        guard let reservation = await workspace.reserveEditorBatch(bufferID: context.buffer.bufferID,
            expectedRevision: context.buffer.revision, editCount: edits.count) else { throw FormattingFailure.staleDocument }
        defer { workspace.cancelEditorBatch(reservation) }
        guard !Task.isCancelled, workspace.activeFileContext() == context,
              editor.isReadyForFormatting(context.buffer) else { throw FormattingFailure.staleDocument }
        let result = editor.replaceActiveBatch(edits, expectedRevision: context.buffer.revision) { [workspace] in
            workspace.commitEditorBatch(reservation, edits: $0)
        }
        guard case .accepted = result, let updated = workspace.fileContext(tabID: context.tabID) else { throw FormattingFailure.staleDocument }
        return (updated, rules)
    }
}
