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
    case noActiveDocument
    case editorSnapshotUnavailable(BufferID)
    case editorRevisionMismatch(bufferID: BufferID, expected: UInt64, actual: UInt64)
    case codec(TextFileCodecError)
    case store(TextFileStoreError)
    case workspace(PersistenceFailure)
    case session(SessionError)
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
    case cancel
}

/// Coordinates file I/O while the editor remains the sole live-text authority.
/// MainActor isolation serializes open/save decisions and keeps UI publication ordered.
@MainActor
public final class FileDocumentUseCase {
    private struct PendingConflict {
        let context: FileWorkspaceContext
        let url: URL
        let conversion: TextFileConversion?
    }

    private let workspace: ScratchWorkspaceUseCase
    private let editor: any EditorPort
    private let store: any TextFileStore
    private var pendingConflict: PendingConflict?
    private var operationBusy = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(workspace: ScratchWorkspaceUseCase, editor: any EditorPort, store: any TextFileStore) {
        self.workspace = workspace
        self.editor = editor
        self.store = store
    }

    public func open(
        _ url: URL,
        assuming encodingHint: TextFileEncoding? = nil
    ) async -> FileOpenOutcome {
        await acquireOperation()
        defer { releaseOperation() }
        do {
            let canonical = try await store.canonicalURL(for: url)
            if let existing = workspace.tabID(canonicalPath: canonical.path) {
                switch await workspace.activate(tabID: existing) {
                case .applied: return .activatedExisting(existing)
                case .persistenceFailed(let failure): return .failed(.workspace(failure))
                case .rejected(let error): return .failed(.session(error))
                }
            }
            let read = try await store.read(from: canonical)
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
        } catch let error {
            return .failed(.store(error))
        }
    }

    public func saveActive(conversion: TextFileConversion? = nil) async -> FileSaveOutcome {
        await acquireOperation()
        defer { releaseOperation() }
        guard let context = workspace.activeFileContext() else { return .failed(.noActiveDocument) }
        guard let binding = context.binding else { return .requiresDestination(context.tabID) }
        return await save(context: context, to: URL(fileURLWithPath: binding.canonicalPath), conversion: conversion, overwrite: false)
    }

    public func saveAs(_ url: URL, conversion: TextFileConversion? = nil) async -> FileSaveOutcome {
        await acquireOperation()
        defer { releaseOperation() }
        guard let context = workspace.activeFileContext() else { return .failed(.noActiveDocument) }
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
                switch await workspace.replaceFileContents(tabID: context.tabID, binding: updated, title: URL(fileURLWithPath: updated.canonicalPath).lastPathComponent) {
                case .applied:
                    guard let refreshed = workspace.fileContext(tabID: context.tabID) else { return .failed(.noActiveDocument) }
                    editor.install(EditorTextSnapshot(bufferID: refreshed.buffer.bufferID, revision: refreshed.buffer.revision, text: decoded.text))
                    return .saved(context.tabID)
                case .persistenceFailed(let failure): return .failed(.workspace(failure))
                case .rejected(let error): return .failed(.session(error))
                }
            } catch let error {
                return .failed(.store(error))
            }
        }
    }

    private func save(
        context: FileWorkspaceContext,
        to url: URL,
        conversion: TextFileConversion?,
        overwrite: Bool
    ) async -> FileSaveOutcome {
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
            switch await workspace.bindSavedFile(
                tabID: context.tabID,
                binding: binding,
                title: url.lastPathComponent,
                savedRevision: snapshot.revision
            ) {
            case .applied:
                pendingConflict = nil
                return .saved(context.tabID)
            case .persistenceFailed(let failure): return .failed(.workspace(failure))
            case .rejected(let error): return .failed(.session(error))
            }
        } catch .conflict(let current) {
            pendingConflict = PendingConflict(context: context, url: url, conversion: conversion)
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
