import DuckpadDomain
import Foundation

/// Remote documents are explicit, read-only snapshots. Viewing a server file
/// never routes Save, rename, formatting or recovery through a local file URL.
@MainActor public final class RemoteFileUseCase {
    nonisolated public static let maximumOpenBytes = 64 * 1_024 * 1_024
    public private(set) var loadingProgress: FileLoadingProgress? {
        didSet { onLoadingProgress?() }
    }
    public var onLoadingProgress: (() -> Void)?
    private var busy = false
    private var failedLoads = Set<TabID>()
    private let workspace: ScratchWorkspaceUseCase
    private let editor: any EditorPort
    private let reader: any FileObservationReading
    private let retryPolicy: RemoteConnectionRetryPolicy
    public var browser: (any RemoteFileBrowsing)? { reader as? any RemoteFileBrowsing }
    public init(workspace: ScratchWorkspaceUseCase, editor: any EditorPort, reader: any FileObservationReading, retryPolicy: RemoteConnectionRetryPolicy = .init()) {
        self.workspace = workspace; self.editor = editor; self.reader = reader; self.retryPolicy = retryPolicy
    }
    public func open(_ location: RemoteFileLocation, tail: Bool = false) async throws -> TabID {
        while busy { try await Task.sleep(for: .milliseconds(10)) }
        try Task.checkCancellation()
        busy = true
        loadingProgress = .init(path: location.title, loadedByteCount: 0, totalByteCount: nil)
        defer { busy = false; loadingProgress = nil }
        if let existing = workspace.tabID(canonicalPath: location.identifier) {
            if failedLoads.contains(existing), let context = workspace.fileContext(tabID: existing),
               let progressive = editor as? any ProgressiveTextEditorPort {
                try await completeLoad(context, progressive: progressive, path: location.title)
            }
            _ = await workspace.activateIfCurrent(tabID: existing, isCurrent: { !Task.isCancelled })
            try Task.checkCancellation()
            return existing
        }
        let reader = reader, retryPolicy = retryPolicy
        let worker = Task.detached(priority: .utility) {
            var data = Data(), cursor: FileObservationCursor?
            var firstSize: UInt64?
            var startsMidFile = false
            if tail {
                let metadata = try await retryPolicy.run { try await reader.read(.ssh(location), after: nil, maximumBytes: 1) }
                let start = metadata.sourceSize > 1_024 * 1_024 ? metadata.sourceSize - 1_024 * 1_024 : 0
                startsMidFile = start > 0
                firstSize = metadata.sourceSize
                cursor = .init(identity: metadata.cursor.identity, offset: start)
            }
            repeat {
                try Task.checkCancellation()
                let currentCursor = cursor
                let read = try await retryPolicy.run { try await reader.read(.ssh(location), after: currentCursor, maximumBytes: 4 * 1_024 * 1_024) }
                if let firstSize, read.reset || read.sourceSize < firstSize { throw FileObservationError.unavailable }
                if firstSize == nil { firstSize = read.sourceSize }
                guard (tail || firstSize! <= Self.maximumOpenBytes), data.count <= Self.maximumOpenBytes - read.data.count else {
                    throw FileObservationError.remoteFileTooLarge
                }
                data.append(read.data); cursor = read.cursor
                let loaded = data.count, total = tail ? min(firstSize!, 1_024 * 1_024) : firstSize!
                await self.reportProgress(path: location.title, loaded: loaded, total: Int(clamping: total))
                if cursor!.offset >= firstSize! { break }
                if read.data.isEmpty { throw FileObservationError.unavailable }
            } while true
            if startsMidFile {
                while data.first.map({ $0 & 0xC0 == 0x80 }) == true { data.removeFirst() }
                if let newline = data.firstIndex(of: 10) { data = Data(data.suffix(from: data.index(after: newline))) }
            }
            // An actively written log may end in a partial UTF-8 character.
            // Start following at the last complete byte, so it is read again.
            var finalCursor = cursor
            if tail, let cursor {
                var decoder = FileTailUTF8Decoder()
                data = try decoder.decode(data)
                finalCursor = .init(identity: cursor.identity, offset: cursor.offset - UInt64(decoder.pendingByteCount))
            }
            guard let cursor = finalCursor, !data.contains(0), let decoded = try? TextFileCodec.decode(data, assuming: .utf8) else {
                throw FileObservationError.invalidUTF8
            }
            return (decoded, cursor)
        }
        let (decoded, cursor) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        // Recheck after network I/O: parallel Open requests cannot duplicate a tab.
        if let existing = workspace.tabID(canonicalPath: location.identifier) {
            _ = await workspace.activateIfCurrent(tabID: existing, isCurrent: { !Task.isCancelled })
            try Task.checkCancellation(); return existing
        }
        let progressive = editor as? any ProgressiveTextEditorPort
        let prepare = decoded.text.utf8.count >= 8 * 1_024 * 1_024 ? progressive : nil
        let install = try await prepare?.prepareText(decoded.text)
        try Task.checkCancellation()
        let binding = FileBinding(canonicalPath: location.identifier, encoding: .utf8, byteOrderMark: decoded.byteOrderMark,
            lineEnding: decoded.lineEnding, observedIdentity: .init(canonicalPath: location.identifier,
                device: 0, inode: 0, byteCount: cursor.offset, modifiedNanoseconds: 0, contentToken: cursor.identity), remoteFile: location)
        var didInstall = false
        guard let tab = await workspace.addObservedFile(binding: binding, title: location.title,
            isCurrent: { !Task.isCancelled }, install: { buffer in
                didInstall = true
                if let install { install(buffer) }
                else { self.editor.install(.init(bufferID: buffer.bufferID, revision: buffer.revision, text: decoded.text)) }
                self.editor.setReadOnly(true, for: buffer.bufferID)
            }), let context = workspace.fileContext(tabID: tab) else {
            try Task.checkCancellation()
            throw FileObservationError.persistence
        }
        guard didInstall else {
            _ = await workspace.activateIfCurrent(tabID: tab, isCurrent: { !Task.isCancelled })
            try Task.checkCancellation()
            return tab
        }
        if let prepare { try await completeLoad(context, progressive: prepare, path: location.title) }
        try Task.checkCancellation()
        guard workspace.fileContext(tabID: tab) == context else { throw CancellationError() }
        editor.setReadOnly(true, for: context.buffer.bufferID)
        return tab
    }
    private func completeLoad(_ context: FileWorkspaceContext, progressive: any ProgressiveTextEditorPort, path: String) async throws {
        guard progressive.hasPendingTextLoad(for: context.buffer.bufferID) else {
            failedLoads.remove(context.tabID)
            return
        }
        // Publication is the commit point. Finish the bounded native snapshot
        // even if the opening request is cancelled. User navigation is retained.
        let completion = Task { @MainActor in
            try await progressive.finishTextLoad(for: context.buffer) { [weak self] loaded, total in
                self?.reportProgress(path: path, loaded: loaded, total: total)
            }
        }
        do {
            try await completion.value
            failedLoads.remove(context.tabID)
        } catch {
            if workspace.fileContext(tabID: context.tabID) == context {
                let outcome = await Task { @MainActor in
                    await self.workspace.close(tabID: context.tabID, decision: .discard)
                }.value
                if case .closed = outcome {
                    editor.retire(bufferID: context.buffer.bufferID)
                    failedLoads.remove(context.tabID)
                } else {
                    // Retain the complete recovery checkpoint when closing could
                    // not persist. Reopening explicitly retries this owned load.
                    failedLoads.insert(context.tabID)
                }
            }
            throw error
        }
    }

    private func reportProgress(path: String, loaded: Int, total: Int) {
        loadingProgress = .init(path: path, loadedByteCount: loaded, totalByteCount: total)
    }
}
