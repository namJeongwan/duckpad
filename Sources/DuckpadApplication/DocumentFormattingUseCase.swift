import DuckpadDomain
import Foundation

@MainActor
public protocol FormattingEditorPort: SearchEditorPort, LanguageEditorPort {
    func isReadyForFormatting(_ buffer: EditorBufferDescriptor) -> Bool
}

@MainActor
public final class DocumentFormattingUseCase {
    public static let maximumInputBytes = 1_024 * 1_024
    private let workspace: ScratchWorkspaceUseCase
    private let editor: any FormattingEditorPort
    private let formatter: any DocumentFormatting
    private struct SuccessfulFormat: Equatable {
        let buffer: EditorBufferDescriptor
        let parser: String
        let settings: FormattingSettings
        let boundLineEnding: LineEnding?
    }
    // One key only; never retain document contents or an unbounded cache.
    private var successfulFormat: SuccessfulFormat?
    public var settings = FormattingSettings()
    public private(set) var isFormatting = false

    public init(workspace: ScratchWorkspaceUseCase, editor: any FormattingEditorPort, formatter: any DocumentFormatting) {
        self.workspace = workspace
        self.editor = editor
        self.formatter = formatter
    }

    public var canFormat: Bool {
        guard let context = workspace.activeFileContext() else { return false }
        return !isFormatting && editor.isReadyForFormatting(context.buffer) && context.binding?.isReadOnly != true && parser() != nil
    }

    private func parser(destination: URL? = nil) -> String? {
        guard let language = workspace.activeLanguageContext() else { return nil }
        let id: String
        let manual: Bool
        switch language.override {
        case .automatic: id = editor.activeLanguageID.rawValue; manual = false
        case .manual(let selected): id = selected.rawValue; manual = true
        }
        return FormattingLanguage.parser(languageID: id, filename: destination?.path ?? language.filename ?? "", usesLanguageOverride: manual)
    }

    /// Returns the new revision to the save transaction. All changes enter the
    /// editor's ordinary undo/recovery path; the formatter never writes files.
    @discardableResult
    public func format(expectedContext: FileWorkspaceContext? = nil, destination: URL? = nil) async throws -> FileWorkspaceContext {
        try Task.checkCancellation()
        guard !isFormatting else { throw FormattingFailure.busy }
        guard let context = workspace.activeFileContext(), expectedContext == nil || expectedContext == context,
              context.binding?.isReadOnly != true, editor.isReadyForFormatting(context.buffer) else { throw FormattingFailure.staleDocument }
        guard let parser = parser(destination: destination) else { throw FormattingFailure.unsupportedLanguage }
        guard editor.activeDocumentByteLength <= Self.maximumInputBytes else { throw FormattingFailure.tooLarge }
        let requestedSettings = settings
        let key = SuccessfulFormat(buffer: context.buffer, parser: parser, settings: requestedSettings,
            boundLineEnding: context.binding?.lineEnding)
        if successfulFormat == key { return context }
        guard let snapshot = editor.snapshot(for: context.buffer.bufferID), snapshot.revision == context.buffer.revision else {
            throw FormattingFailure.staleDocument
        }
        let language = workspace.activeLanguageContext()
        isFormatting = true
        defer { isFormatting = false }
        var result = try await formatter.format(.init(text: snapshot.text, parser: parser, settings: requestedSettings))
        guard result.utf8.count <= 4 * Self.maximumInputBytes else { throw FormattingFailure.tooLarge }
        // WebKit may return NSString-backed storage. Convert once before the
        // byte scans rather than repeatedly transcoding its UTF-16 view.
        result.makeContiguousUTF8()
        let ending = context.binding?.lineEnding ?? TextFileCodec.decodeForDisplay(Data(snapshot.text.utf8)).lineEnding
        let normalizedEnding: LineEnding = ending == .none || ending == .mixed ? .lf : ending
        // Bundled formatters normally return LF already. Preserve the original
        // string storage when no conversion is necessary.
        let formatted = normalizedEnding == .lf && !result.utf8.contains(13)
            ? result : TextFileCodec.convert(result, to: normalizedEnding)
        let edits = await Task.detached(priority: .userInitiated) { FormattingEdits.between(snapshot.text, formatted) }.value
        try Task.checkCancellation()
        guard workspace.activeFileContext() == context, workspace.activeLanguageContext() == language,
              editor.isReadyForFormatting(context.buffer) else { throw FormattingFailure.staleDocument }
        guard !edits.isEmpty else { successfulFormat = key; return context }
        guard let reservation = await workspace.reserveEditorBatch(bufferID: context.buffer.bufferID,
            expectedRevision: snapshot.revision, editCount: edits.count) else { throw FormattingFailure.staleDocument }
        defer { workspace.cancelEditorBatch(reservation) }
        try Task.checkCancellation()
        guard workspace.activeFileContext() == context, workspace.activeLanguageContext() == language,
              editor.isReadyForFormatting(context.buffer) else { throw FormattingFailure.staleDocument }
        let outcome = editor.replaceActiveBatch(edits, expectedRevision: snapshot.revision) { [workspace] edits in
            workspace.commitEditorBatch(reservation, edits: edits)
        }
        guard case .accepted = outcome, let updated = workspace.fileContext(tabID: context.tabID) else {
            throw FormattingFailure.staleDocument
        }
        successfulFormat = SuccessfulFormat(buffer: updated.buffer, parser: parser, settings: requestedSettings,
            boundLineEnding: updated.binding?.lineEnding)
        return updated
    }
}
