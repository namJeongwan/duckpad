import DuckpadDomain
import Foundation

public enum FileObservationSource: Hashable, Sendable {
    case local(String)
    case ssh(RemoteFileLocation)
}

public struct FileObservationCursor: Codable, Equatable, Sendable {
    public let identity: String
    public let offset: UInt64
    public init(identity: String, offset: UInt64) { self.identity = identity; self.offset = offset }
}

public struct FileObservationRead: Codable, Equatable, Sendable {
    public let data: Data
    public let cursor: FileObservationCursor
    public let sourceSize: UInt64
    public let reset: Bool
    public var hasMore: Bool { cursor.offset < sourceSize }
    public init(data: Data, cursor: FileObservationCursor, sourceSize: UInt64, reset: Bool) {
        self.data = data; self.cursor = cursor; self.sourceSize = sourceSize; self.reset = reset
    }
}

public enum FileObservationError: Error, Codable, Equatable, Sendable {
    case unavailable
    case authentication
    case invalidResponse
    case invalidUTF8
    case tooLarge
    case remoteFileTooLarge
    case cancelled
    case timedOut
    case dirtyDocument
    case unsupportedEncoding
    case editorUnavailable
    case persistence
}

public protocol FileObservationReading: Sendable {
    func read(_ source: FileObservationSource, after cursor: FileObservationCursor?, maximumBytes: Int) async throws -> FileObservationRead
}

/// Automatic file updates bypass user-edit callbacks but still advance the live
/// revision and recovery journal. Each visible pane retains its own viewport.
@MainActor public protocol ObservedFileEditorPort: EditorPort {
    func applyObservedUTF8(_ data: Data, to buffer: EditorBufferDescriptor, reset: Bool) -> Bool
    func observedByteCount(for bufferID: BufferID) -> Int?
    func isObservedFileFollowingEnd(in bufferID: BufferID) -> Bool
    func followObservedFileEnd(in bufferID: BufferID)
}

/// Keep an incomplete UTF-8 suffix for the next write, never insert replacement
/// characters when a producer splits a Korean character across writes.
public struct FileTailUTF8Decoder: Sendable {
    private var pending = Data()
    private var atFileStart = false
    public init() {}
    public var pendingByteCount: Int { pending.count }
    public mutating func decode(_ data: Data, reset: Bool = false) throws -> Data {
        if reset { pending.removeAll(); atFileStart = true }
        pending.append(data)
        var end = pending.count
        if end > 0 {
            var start = end - 1
            while start > 0 && pending[start] & 0xC0 == 0x80 { start -= 1 }
            let lead = pending[start]
            let width = lead < 0x80 ? 1 : lead >= 0xC2 && lead <= 0xDF ? 2
                : lead >= 0xE0 && lead <= 0xEF ? 3 : lead >= 0xF0 && lead <= 0xF4 ? 4 : 0
            if width > 0 && end - start < width { end = start }
        }
        var complete = Data(pending.prefix(end))
        guard String(data: complete, encoding: .utf8) != nil else { throw FileObservationError.invalidUTF8 }
        pending = Data(pending.dropFirst(end))
        if atFileStart, !complete.isEmpty {
            if complete.starts(with: [0xEF, 0xBB, 0xBF]) { complete.removeFirst(3) }
            atFileStart = false
        }
        guard pending.count <= 3 else { throw FileObservationError.invalidUTF8 }
        return complete
    }
}
