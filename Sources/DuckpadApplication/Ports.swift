import DuckpadDomain

public enum SessionStoreError: Error, Equatable, Sendable {
    case unavailable(String)
    case corrupt(String)
}

public struct PersistenceGeneration: RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum SessionCommitResult: Equatable, Sendable {
    case committed
    case superseded(durableGeneration: PersistenceGeneration)
}

public struct StoredSession: Equatable, Sendable {
    public let session: ScratchSession
    public let generation: PersistenceGeneration

    public init(session: ScratchSession, generation: PersistenceGeneration) {
        self.session = session
        self.generation = generation
    }
}

public protocol SessionStore: Sendable {
    func loadSession() async throws(SessionStoreError) -> StoredSession?
    /// Atomically replaces durable state only when `generation` is newer than the
    /// last committed generation. Adapters must perform the comparison and write
    /// in one isolation boundary.
    func commitSession(
        _ session: ScratchSession,
        generation: PersistenceGeneration
    ) async throws(SessionStoreError) -> SessionCommitResult
}

public struct TextEditRange: Equatable, Sendable {
    /// Zero-based UTF-8 byte offset. Cocoa UTF-16 ranges must be converted at
    /// the adapter boundary before entering Application.
    public let location: Int
    /// Number of UTF-8 bytes replaced in the pre-edit snapshot.
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct EditorIncrementalEdit: Equatable, Sendable {
    public let bufferID: BufferID
    public let expectedRevision: UInt64
    public let range: TextEditRange
    public let replacement: String

    public init(
        bufferID: BufferID,
        expectedRevision: UInt64,
        range: TextEditRange,
        replacement: String
    ) {
        self.bufferID = bufferID
        self.expectedRevision = expectedRevision
        self.range = range
        self.replacement = replacement
    }
}

public struct EditorBufferDescriptor: Equatable, Sendable {
    public let bufferID: BufferID
    public let revision: UInt64

    public init(bufferID: BufferID, revision: UInt64) {
        self.bufferID = bufferID
        self.revision = revision
    }
}

public struct EditorTextSnapshot: Equatable, Sendable {
    public let bufferID: BufferID
    public let revision: UInt64
    public let text: String

    public init(bufferID: BufferID, revision: UInt64, text: String) {
        self.bufferID = bufferID
        self.revision = revision
        self.text = text
    }
}

public enum EditorEditOutcome: Equatable, Sendable {
    case accepted(newRevision: UInt64)
    case rejected(currentRevision: UInt64)
}

@MainActor
public protocol EditorPort: AnyObject {
    var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)? { get set }
    func display(_ buffer: EditorBufferDescriptor)
    func snapshot(for bufferID: BufferID) -> EditorTextSnapshot?
    func retire(bufferID: BufferID)
    func setInputEnabled(_ isEnabled: Bool)
    func focus()
}
