import DuckpadDomain
import Foundation

public struct SecondaryEditorViewState: Codable, Equatable, Sendable {
    public var anchorUTF8: Int
    public var caretUTF8: Int
    public var firstVisibleLine: Int
    public var horizontalScrollOffset: Int
    public var wordWrapEnabled: Bool
    public var wrapMarkerVisible: Bool
    public var whitespaceVisible: Bool
    public var lineEndingsVisible: Bool
    public var zoomLevel: Int

    public init(
        anchorUTF8: Int = 0,
        caretUTF8: Int = 0,
        firstVisibleLine: Int = 0,
        horizontalScrollOffset: Int = 0,
        wordWrapEnabled: Bool = true,
        wrapMarkerVisible: Bool = false,
        whitespaceVisible: Bool = false,
        lineEndingsVisible: Bool = false,
        zoomLevel: Int = 0
    ) {
        self.anchorUTF8 = anchorUTF8
        self.caretUTF8 = caretUTF8
        self.firstVisibleLine = firstVisibleLine
        self.horizontalScrollOffset = horizontalScrollOffset
        self.wordWrapEnabled = wordWrapEnabled
        self.wrapMarkerVisible = wrapMarkerVisible
        self.whitespaceVisible = whitespaceVisible
        self.lineEndingsVisible = lineEndingsVisible
        self.zoomLevel = min(max(zoomLevel, -10), 20)
    }

    private enum CodingKeys: String, CodingKey {
        case anchorUTF8, caretUTF8, firstVisibleLine, horizontalScrollOffset
        case wordWrapEnabled, wrapMarkerVisible
        case whitespaceVisible, lineEndingsVisible, zoomLevel
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        anchorUTF8 = try values.decode(Int.self, forKey: .anchorUTF8)
        caretUTF8 = try values.decode(Int.self, forKey: .caretUTF8)
        firstVisibleLine = try values.decode(Int.self, forKey: .firstVisibleLine)
        horizontalScrollOffset = try values.decode(Int.self, forKey: .horizontalScrollOffset)
        wordWrapEnabled = try values.decode(Bool.self, forKey: .wordWrapEnabled)
        wrapMarkerVisible = try values.decodeIfPresent(Bool.self, forKey: .wrapMarkerVisible) ?? false
        whitespaceVisible = try values.decodeIfPresent(Bool.self, forKey: .whitespaceVisible) ?? false
        lineEndingsVisible = try values.decodeIfPresent(Bool.self, forKey: .lineEndingsVisible) ?? false
        zoomLevel = min(max(try values.decodeIfPresent(Int.self, forKey: .zoomLevel) ?? 0, -10), 20)
    }
}

public struct EditorViewState: Codable, Equatable, Sendable {
    public static let maximumBookmarkCount = 10_000
    public var anchorUTF8: Int
    public var caretUTF8: Int
    public var firstVisibleLine: Int
    public var horizontalScrollOffset: Int
    public var wordWrapEnabled: Bool
    public var wrapMarkerVisible: Bool
    public var whitespaceVisible: Bool
    public var lineEndingsVisible: Bool
    public var zoomLevel: Int
    public var bookmarkedLines: [Int]
    public var splitOrientation: EditorSplitOrientation?
    public var secondaryViewState: SecondaryEditorViewState?

    public init(
        anchorUTF8: Int = 0,
        caretUTF8: Int = 0,
        firstVisibleLine: Int = 0,
        horizontalScrollOffset: Int = 0,
        wordWrapEnabled: Bool = true,
        wrapMarkerVisible: Bool = false,
        whitespaceVisible: Bool = false,
        lineEndingsVisible: Bool = false,
        zoomLevel: Int = 0,
        bookmarkedLines: [Int] = [],
        splitOrientation: EditorSplitOrientation? = nil,
        secondaryViewState: SecondaryEditorViewState? = nil
    ) {
        self.anchorUTF8 = anchorUTF8
        self.caretUTF8 = caretUTF8
        self.firstVisibleLine = firstVisibleLine
        self.horizontalScrollOffset = horizontalScrollOffset
        self.wordWrapEnabled = wordWrapEnabled
        self.wrapMarkerVisible = wrapMarkerVisible
        self.whitespaceVisible = whitespaceVisible
        self.lineEndingsVisible = lineEndingsVisible
        self.zoomLevel = min(max(zoomLevel, -10), 20)
        self.bookmarkedLines = Array(
            Array(Set(bookmarkedLines.filter { $0 >= 0 })).sorted().prefix(Self.maximumBookmarkCount)
        )
        self.splitOrientation = splitOrientation
        self.secondaryViewState = splitOrientation == nil ? nil : (secondaryViewState ?? SecondaryEditorViewState())
    }

    private enum CodingKeys: String, CodingKey {
        case anchorUTF8
        case caretUTF8
        case firstVisibleLine
        case horizontalScrollOffset
        case wordWrapEnabled
        case wrapMarkerVisible
        case whitespaceVisible
        case lineEndingsVisible
        case zoomLevel
        case bookmarkedLines
        case splitOrientation
        case secondaryViewState
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        anchorUTF8 = try values.decode(Int.self, forKey: .anchorUTF8)
        caretUTF8 = try values.decode(Int.self, forKey: .caretUTF8)
        firstVisibleLine = try values.decode(Int.self, forKey: .firstVisibleLine)
        horizontalScrollOffset = try values.decode(Int.self, forKey: .horizontalScrollOffset)
        wordWrapEnabled = try values.decode(Bool.self, forKey: .wordWrapEnabled)
        wrapMarkerVisible = try values.decodeIfPresent(Bool.self, forKey: .wrapMarkerVisible) ?? false
        whitespaceVisible = try values.decodeIfPresent(Bool.self, forKey: .whitespaceVisible) ?? false
        lineEndingsVisible = try values.decodeIfPresent(Bool.self, forKey: .lineEndingsVisible) ?? false
        zoomLevel = min(max(try values.decodeIfPresent(Int.self, forKey: .zoomLevel) ?? 0, -10), 20)
        let decodedBookmarks = try values.decodeIfPresent([Int].self, forKey: .bookmarkedLines) ?? []
        guard decodedBookmarks.count <= Self.maximumBookmarkCount,
              decodedBookmarks.allSatisfy({ $0 >= 0 }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .bookmarkedLines,
                in: values,
                debugDescription: "Bookmarks must be nonnegative and bounded"
            )
        }
        bookmarkedLines = Array(Set(decodedBookmarks)).sorted()
        splitOrientation = try values.decodeIfPresent(EditorSplitOrientation.self, forKey: .splitOrientation)
        secondaryViewState = try values.decodeIfPresent(SecondaryEditorViewState.self, forKey: .secondaryViewState)
        guard (splitOrientation == nil) == (secondaryViewState == nil) else {
            throw DecodingError.dataCorruptedError(
                forKey: .secondaryViewState,
                in: values,
                debugDescription: "Split orientation and secondary view state must appear together"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(anchorUTF8, forKey: .anchorUTF8)
        try values.encode(caretUTF8, forKey: .caretUTF8)
        try values.encode(firstVisibleLine, forKey: .firstVisibleLine)
        try values.encode(horizontalScrollOffset, forKey: .horizontalScrollOffset)
        try values.encode(wordWrapEnabled, forKey: .wordWrapEnabled)
        try values.encode(wrapMarkerVisible, forKey: .wrapMarkerVisible)
        try values.encode(whitespaceVisible, forKey: .whitespaceVisible)
        try values.encode(lineEndingsVisible, forKey: .lineEndingsVisible)
        try values.encode(zoomLevel, forKey: .zoomLevel)
        try values.encode(bookmarkedLines, forKey: .bookmarkedLines)
        try values.encodeIfPresent(splitOrientation, forKey: .splitOrientation)
        try values.encodeIfPresent(secondaryViewState, forKey: .secondaryViewState)
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
