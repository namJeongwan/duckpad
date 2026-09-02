import DuckpadDomain
import Foundation

public struct EditorViewState: Codable, Equatable, Sendable {
    public var anchorUTF8: Int
    public var caretUTF8: Int
    public var firstVisibleLine: Int
    public var horizontalScrollOffset: Int
    public var wordWrapEnabled: Bool

    public init(
        anchorUTF8: Int = 0,
        caretUTF8: Int = 0,
        firstVisibleLine: Int = 0,
        horizontalScrollOffset: Int = 0,
        wordWrapEnabled: Bool = true
    ) {
        self.anchorUTF8 = anchorUTF8
        self.caretUTF8 = caretUTF8
        self.firstVisibleLine = firstVisibleLine
        self.horizontalScrollOffset = horizontalScrollOffset
        self.wordWrapEnabled = wordWrapEnabled
    }
}

public struct EditorRecoverySnapshot: Equatable, Sendable {
    public let bufferID: BufferID
    public let revision: UInt64
    public let utf8: Data
    public let viewState: EditorViewState

    public init(bufferID: BufferID, revision: UInt64, utf8: Data, viewState: EditorViewState = EditorViewState()) {
        self.bufferID = bufferID
        self.revision = revision
        self.utf8 = utf8
        self.viewState = viewState
    }
}

/// A bounded edit recorded against an immutable UTF-8 checkpoint. Editors
/// append these records on the input path; recovery materializes them away
/// from the main actor.
public struct EditorRecoveryDelta: Equatable, Sendable {
    public let expectedRevision: UInt64
    public let range: TextEditRange
    public let replacementUTF8: Data

    public init(expectedRevision: UInt64, range: TextEditRange, replacementUTF8: Data) {
        self.expectedRevision = expectedRevision
        self.range = range
        self.replacementUTF8 = replacementUTF8
    }
}

public struct EditorRecoveryCapture: Equatable, Sendable {
    public let bufferID: BufferID
    public let baseRevision: UInt64
    public let revision: UInt64
    public let baseUTF8: Data
    public let deltas: [EditorRecoveryDelta]
    public let viewState: EditorViewState

    public init(
        bufferID: BufferID,
        baseRevision: UInt64,
        revision: UInt64,
        baseUTF8: Data,
        deltas: [EditorRecoveryDelta] = [],
        viewState: EditorViewState = EditorViewState()
    ) {
        self.bufferID = bufferID
        self.baseRevision = baseRevision
        self.revision = revision
        self.baseUTF8 = baseUTF8
        self.deltas = deltas
        self.viewState = viewState
    }

    /// Intentionally called from a utility task by SessionRecoveryUseCase.
    public func materializedSnapshot() throws(SessionStoreError) -> EditorRecoverySnapshot {
        var bytes = baseUTF8
        var currentRevision = baseRevision
        guard String(data: bytes, encoding: .utf8) != nil else {
            throw .corrupt("invalid recovery checkpoint UTF-8")
        }
        for delta in deltas {
            guard delta.expectedRevision == currentRevision,
                  currentRevision < UInt64.max,
                  delta.range.location >= 0,
                  delta.range.length >= 0,
                  delta.range.location <= bytes.count,
                  delta.range.length <= bytes.count - delta.range.location,
                  String(data: delta.replacementUTF8, encoding: .utf8) != nil else {
                throw .corrupt("invalid recovery delta")
            }
            let start = delta.range.location
            let end = start + delta.range.length
            guard Self.isUTF8Boundary(start, in: bytes), Self.isUTF8Boundary(end, in: bytes) else {
                throw .corrupt("recovery delta splits UTF-8 code point")
            }
            bytes.replaceSubrange(start..<end, with: delta.replacementUTF8)
            currentRevision += 1
        }
        guard currentRevision == revision, String(data: bytes, encoding: .utf8) != nil else {
            throw .corrupt("recovery delta revision mismatch")
        }
        return EditorRecoverySnapshot(
            bufferID: bufferID,
            revision: revision,
            utf8: bytes,
            viewState: viewState
        )
    }

    private static func isUTF8Boundary(_ offset: Int, in bytes: Data) -> Bool {
        guard offset >= 0, offset <= bytes.count else { return false }
        return offset == 0 || offset == bytes.count || (bytes[offset] & 0xC0) != 0x80
    }
}

public struct RecoveryArchive: Equatable, Sendable {
    public let session: ScratchSession
    public let buffers: [BufferID: EditorRecoverySnapshot]

    public init(session: ScratchSession, buffers: [BufferID: EditorRecoverySnapshot]) {
        self.session = session
        self.buffers = buffers
    }
}

public struct StoredRecoveryArchive: Equatable, Sendable {
    public let archive: RecoveryArchive
    public let generation: PersistenceGeneration

    public init(archive: RecoveryArchive, generation: PersistenceGeneration) {
        self.archive = archive
        self.generation = generation
    }
}

public protocol RecoveryStore: Sendable {
    func loadLatest() async throws(SessionStoreError) -> StoredRecoveryArchive?
    func commit(
        _ archive: RecoveryArchive,
        generation: PersistenceGeneration
    ) async throws(SessionStoreError) -> SessionCommitResult
    func reset() async throws(SessionStoreError)
}

public enum RecoveryOutcome: Equatable, Sendable {
    case saved(PersistenceGeneration)
    case failed(SessionStoreError)
}
