import DuckpadDomain
import Foundation

public struct FileWorkspaceContext: Equatable, Sendable {
    public let tabID: TabID
    public let title: String
    public let buffer: EditorBufferDescriptor
    public let binding: FileBinding?

    public init(tabID: TabID, title: String, buffer: EditorBufferDescriptor, binding: FileBinding?) {
        self.tabID = tabID
        self.title = title
        self.buffer = buffer
        self.binding = binding
    }
}

public enum FileOperationFailure: Error, Equatable, Sendable {
    case cancelled
    case noActiveDocument
    case editorSnapshotUnavailable(BufferID)
    case editorRevisionMismatch(bufferID: BufferID, expected: UInt64, actual: UInt64)
    case codec(TextFileCodecError)
    case store(TextFileStoreError)
    case workspace(PersistenceFailure)
    case session(SessionError)
    case comparisonTooLarge(actual: Int, limit: Int)
    case comparisonInvalidated
}

public enum FileOpenOutcome: Equatable, Sendable {
    case opened(TabID)
    case activatedExisting(TabID)
    case failed(FileOperationFailure)
}

public enum FileSaveOutcome: Equatable, Sendable {
    case saved(TabID)
    case requiresDestination(TabID)
    case conflict(tabID: TabID, current: FileIdentity?)
    case cancelled(TabID)
    case failed(FileOperationFailure)
}

public enum FileConflictResolution: Equatable, Sendable {
    case overwrite
    case reload
    case compare
    case cancel
}

public struct ExternalFileComparison: Equatable, Sendable {
    public let tabID: TabID
    public let path: String
    public let localText: String
    public let externalText: String
    public let localRevision: UInt64
    public let externalIdentity: FileIdentity

    public init(
        tabID: TabID,
        path: String,
        localText: String,
        externalText: String,
        localRevision: UInt64,
        externalIdentity: FileIdentity
    ) {
        self.tabID = tabID
        self.path = path
        self.localText = localText
        self.externalText = externalText
        self.localRevision = localRevision
        self.externalIdentity = externalIdentity
    }
}

public enum FileComparisonOutcome: Equatable, Sendable {
    case ready(ExternalFileComparison)
    case failed(FileOperationFailure)
}

public enum FolderSearchActivationOutcome: Equatable, Sendable {
    case activated(TabID)
    case stale(String)
    case failed(FileOperationFailure)
}

/// Coordinates file I/O while the editor remains the sole live-text authority.
/// MainActor isolation serializes open/save decisions and keeps UI publication ordered.
@MainActor
public final class FileDocumentUseCase {
    public static let defaultMaximumComparisonBytes = 32 * 1_024 * 1_024
    private struct PendingConflict {
        let context: FileWorkspaceContext
        let url: URL
        let conversion: TextFileConversion?
        let currentIdentity: FileIdentity?
    }

    private let workspace: ScratchWorkspaceUseCase
    private let editor: any EditorPort
    private let store: any TextFileStore
    private let maximumComparisonBytes: Int
    private var pendingConflict: PendingConflict?
    private var operationBusy = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        workspace: ScratchWorkspaceUseCase,
        editor: any EditorPort,
        store: any TextFileStore,
        maximumComparisonBytes: Int = FileDocumentUseCase.defaultMaximumComparisonBytes
    ) {
        precondition(maximumComparisonBytes > 0)
        self.workspace = workspace
        self.editor = editor
        self.store = store
        self.maximumComparisonBytes = maximumComparisonBytes
    }

    public func open(
        _ url: URL,
        assuming encodingHint: TextFileEncoding? = nil
    ) async -> FileOpenOutcome {
        await acquireOperation()
        defer { releaseOperation() }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        do {
            let canonical = try await store.canonicalURL(for: url)
            guard !Task.isCancelled else { return .failed(.cancelled) }
            return try await openCanonical(canonical, prepared: nil, encodingHint: encodingHint)
        } catch let error {
            return .failed(.store(error))
        }
    }

    public func open(
        _ workspaceRead: WorkspaceFileRead,
        assuming encodingHint: TextFileEncoding? = nil
    ) async -> FileOpenOutcome {
        await acquireOperation()
        defer { releaseOperation() }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        let canonical = workspaceRead.url.standardizedFileURL
        guard canonical.isFileURL,
              workspaceRead.result.identity.canonicalPath == canonical.path else {
            return .failed(.store(.invalidPath(workspaceRead.url.path)))
        }
        do {
            return try await openCanonical(
                canonical,
                prepared: workspaceRead.result,
                encodingHint: encodingHint
            )
        } catch let error {
            return .failed(.store(error))
        }
    }

    private func openCanonical(
        _ canonical: URL,
        prepared: FileReadResult?,
        encodingHint: TextFileEncoding?
    ) async throws(TextFileStoreError) -> FileOpenOutcome {
        if let existing = workspace.tabID(canonicalPath: canonical.path) {
            switch await workspace.activate(tabID: existing) {
            case .applied: return .activatedExisting(existing)
            case .persistenceFailed(let failure): return .failed(.workspace(failure))
            case .rejected(let error): return .failed(.session(error))
            }
        }
        let read: FileReadResult
        if let prepared { read = prepared }
        else { read = try await store.read(from: canonical) }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        let decoded: DecodedTextFile
        do { decoded = try TextFileCodec.decode(read.data, assuming: encodingHint) }
        catch let error { return .failed(.codec(error)) }
        let binding = FileBinding(
            canonicalPath: read.identity.canonicalPath,
            encoding: decoded.encoding,
            byteOrderMark: decoded.byteOrderMark,
            lineEnding: decoded.lineEnding,
            observedIdentity: read.identity
        )
        guard !Task.isCancelled else { return .failed(.cancelled) }
        switch await workspace.addOpenedFile(binding: binding, title: canonical.lastPathComponent) {
        case .applied:
            guard let context = workspace.activeFileContext() else { return .failed(.noActiveDocument) }
            editor.install(EditorTextSnapshot(
                bufferID: context.buffer.bufferID,
                revision: context.buffer.revision,
                text: decoded.text
            ))
            return .opened(context.tabID)
        case .persistenceFailed(let failure): return .failed(.workspace(failure))
        case .rejected(let error): return .failed(.session(error))
        }
    }

    public func activateFolderSearchMatch(
        document: FolderSearchDocumentResult,
        match: FolderSearchMatch
    ) async -> FolderSearchActivationOutcome {
        guard !Task.isCancelled else { return .failed(.cancelled) }
        let outcome = await open(URL(fileURLWithPath: document.path))
        let tabID: TabID
        switch outcome {
        case .opened(let opened), .activatedExisting(let opened): tabID = opened
        case .failed(let failure): return .failed(failure)
        }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        guard let selectionEditor = editor as? any EditorSelectionPort,
              let context = workspace.fileContext(tabID: tabID),
              workspace.snapshot().tabs.first(where: { $0.id == tabID })?.isDirty == false,
              context.binding?.canonicalPath == document.path,
              context.binding?.observedIdentity == document.identity,
              let snapshot = selectionEditor.snapshot(for: context.buffer.bufferID),
              snapshot.revision == context.buffer.revision,
              match.range.location >= 0,
              match.range.length >= 0,
              match.range.location <= snapshot.text.utf8.count,
              match.range.length <= snapshot.text.utf8.count - match.range.location else {
            return .stale(document.path)
        }
        selectionEditor.selectAndReveal(match.range)
        selectionEditor.focus()
        return .activated(tabID)
    }

    public func saveActive(
        conversion: TextFileConversion? = nil,
        expectedContext: FileWorkspaceContext? = nil
    ) async -> FileSaveOutcome {
        await acquireOperation()
        defer { releaseOperation() }
        guard let context = workspace.activeFileContext() else { return .failed(.noActiveDocument) }
        guard expectedContext == nil || expectedContext == context else {
            return .failed(.comparisonInvalidated)
        }
        guard let binding = context.binding else { return .requiresDestination(context.tabID) }
        return await save(context: context, to: URL(fileURLWithPath: binding.canonicalPath), conversion: conversion, overwrite: false)
    }

    public func saveAs(
        _ url: URL,
        conversion: TextFileConversion? = nil,
        expectedContext: FileWorkspaceContext? = nil
    ) async -> FileSaveOutcome {
        await acquireOperation()
        defer { releaseOperation() }
        guard let context = workspace.activeFileContext() else { return .failed(.noActiveDocument) }
        guard expectedContext == nil || expectedContext == context else {
            return .failed(.comparisonInvalidated)
        }
        do {
            let canonical = try await store.canonicalURL(for: url)
            return await save(context: context, to: canonical, conversion: conversion, overwrite: false)
        } catch let error {
            return .failed(.store(error))
        }
    }

    public func resolveConflict(_ resolution: FileConflictResolution) async -> FileSaveOutcome {
        await acquireOperation()
        defer { releaseOperation() }
        guard let pendingConflict else {
            return .failed(.noActiveDocument)
        }
        let context = pendingConflict.context
        switch resolution {
        case .cancel:
            self.pendingConflict = nil
            return .cancelled(context.tabID)
        case .overwrite:
            return await save(
                context: context,
                to: pendingConflict.url,
                conversion: pendingConflict.conversion,
                overwrite: true
            )
        case .compare:
            return .conflict(tabID: context.tabID, current: pendingConflict.currentIdentity)
        case .reload:
            do {
                let read = try await store.read(from: pendingConflict.url)
                let decoded: DecodedTextFile
                do { decoded = try TextFileCodec.decode(read.data) }
                catch let error { return .failed(.codec(error)) }
                let updated = FileBinding(
                    canonicalPath: read.identity.canonicalPath,
                    encoding: decoded.encoding,
                    byteOrderMark: decoded.byteOrderMark,
                    lineEnding: decoded.lineEnding,
                    observedIdentity: read.identity
                )
                switch await workspace.replaceFileContents(
                    tabID: context.tabID,
                    binding: updated,
                    title: URL(fileURLWithPath: updated.canonicalPath).lastPathComponent,
                    expectedRevision: context.buffer.revision,
                    expectedBinding: context.binding
                ) {
                case .applied:
                    guard let refreshed = workspace.fileContext(tabID: context.tabID) else { return .failed(.noActiveDocument) }
                    editor.install(EditorTextSnapshot(bufferID: refreshed.buffer.bufferID, revision: refreshed.buffer.revision, text: decoded.text))
                    self.pendingConflict = nil
                    return .saved(context.tabID)
                case .persistenceFailed(let failure): return .failed(.workspace(failure))
                case .rejected(.revisionConflict(let bufferID, let expected, let actual)):
                    return .failed(.editorRevisionMismatch(
                        bufferID: bufferID,
                        expected: expected,
                        actual: actual
                    ))
                case .rejected(.unknownTab), .rejected(.fileBindingConflict):
                    return .failed(.comparisonInvalidated)
                case .rejected(let error): return .failed(.session(error))
                }
            } catch let error {
                return .failed(.store(error))
            }
        }
    }

    public func pendingExternalComparison() async -> FileComparisonOutcome {
        await acquireOperation()
        defer { releaseOperation() }
        guard let pendingConflict,
              let context = workspace.fileContext(tabID: pendingConflict.context.tabID) else {
            return .failed(.noActiveDocument)
        }
        guard let snapshot = editor.snapshot(for: context.buffer.bufferID) else {
            return .failed(.editorSnapshotUnavailable(context.buffer.bufferID))
        }
        guard snapshot.revision == context.buffer.revision else {
            return .failed(.editorRevisionMismatch(
                bufferID: context.buffer.bufferID,
                expected: context.buffer.revision,
                actual: snapshot.revision
            ))
        }
        guard snapshot.text.utf8.count <= maximumComparisonBytes else {
            return .failed(.comparisonTooLarge(
                actual: snapshot.text.utf8.count,
                limit: maximumComparisonBytes
            ))
        }
        do {
            let read = try await store.read(from: pendingConflict.url)
            guard let refreshed = workspace.fileContext(tabID: context.tabID),
                  refreshed == context,
                  let refreshedSnapshot = editor.snapshot(for: refreshed.buffer.bufferID),
                  refreshedSnapshot.revision == snapshot.revision else {
                return .failed(.comparisonInvalidated)
            }
            guard read.data.count <= maximumComparisonBytes else {
                return .failed(.comparisonTooLarge(
                    actual: read.data.count,
                    limit: maximumComparisonBytes
                ))
            }
            let decoded: DecodedTextFile
            do {
                decoded = try TextFileCodec.decode(
                    read.data,
                    assuming: context.binding?.encoding
                )
            } catch let error {
                return .failed(.codec(error))
            }
            return .ready(ExternalFileComparison(
                tabID: context.tabID,
                path: read.identity.canonicalPath,
                localText: snapshot.text,
                externalText: decoded.text,
                localRevision: snapshot.revision,
                externalIdentity: read.identity
            ))
        } catch let error {
            return .failed(.store(error))
        }
    }

    private func save(
        context: FileWorkspaceContext,
        to url: URL,
        conversion: TextFileConversion?,
        overwrite: Bool
    ) async -> FileSaveOutcome {
        guard workspace.fileContext(tabID: context.tabID) == context else {
            pendingConflict = nil
            return .failed(.comparisonInvalidated)
        }
        if let duplicate = workspace.tabID(canonicalPath: url.path), duplicate != context.tabID {
            return .failed(.session(.duplicateFileBinding(url.path)))
        }
        guard let snapshot = editor.snapshot(for: context.buffer.bufferID) else {
            return .failed(.editorSnapshotUnavailable(context.buffer.bufferID))
        }
        guard snapshot.revision == context.buffer.revision else {
            return .failed(.editorRevisionMismatch(
                bufferID: context.buffer.bufferID,
                expected: context.buffer.revision,
                actual: snapshot.revision
            ))
        }
        let encoding = conversion?.encoding ?? context.binding?.encoding ?? .utf8
        let bom = conversion?.byteOrderMark ?? context.binding?.byteOrderMark ?? .absent
        let lineEnding = conversion?.lineEnding ?? context.binding?.lineEnding ?? .none
        // Bound EOL is a durable format choice, not a one-shot transformation.
        // Normal saves therefore normalize to the binding selected by a prior conversion.
        let text = TextFileCodec.convert(snapshot.text, to: lineEnding)
        let data = TextFileCodec.encode(text, encoding: encoding, byteOrderMark: bom)
        let expected = !overwrite && context.binding?.canonicalPath == url.path ? context.binding?.observedIdentity : nil
        do {
            let receipt = try await store.writeAtomically(data, to: url, expectedIdentity: expected, overwrite: overwrite)
            let identity = receipt.identity
            let binding = FileBinding(
                canonicalPath: identity.canonicalPath,
                encoding: encoding,
                byteOrderMark: bom,
                lineEnding: lineEnding == .none ? inferLineEnding(text) : lineEnding,
                observedIdentity: identity
            )
            switch await workspace.bindSavedFileIfCurrent(
                tabID: context.tabID,
                binding: binding,
                title: url.lastPathComponent,
                savedRevision: snapshot.revision,
                expectedBufferID: context.buffer.bufferID,
                expectedBinding: context.binding
            ) {
            case .applied:
                pendingConflict = nil
                return .saved(context.tabID)
            case .persistenceFailed(let failure): return .failed(.workspace(failure))
            case .rejected(.fileBindingConflict), .rejected(.unknownTab):
                pendingConflict = nil
                return .failed(.comparisonInvalidated)
            case .rejected(let error): return .failed(.session(error))
            }
        } catch .conflict(let current) {
            pendingConflict = PendingConflict(
                context: context,
                url: url,
                conversion: conversion,
                currentIdentity: current
            )
            return .conflict(tabID: context.tabID, current: current)
        } catch let error {
            return .failed(.store(error))
        }
    }

    private func inferLineEnding(_ text: String) -> LineEnding {
        (try? TextFileCodec.decode(Data(text.utf8)).lineEnding) ?? .none
    }

    private func acquireOperation() async {
        if !operationBusy {
            operationBusy = true
            return
        }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func releaseOperation() {
        if operationWaiters.isEmpty { operationBusy = false }
        else { operationWaiters.removeFirst().resume() }
    }
}
