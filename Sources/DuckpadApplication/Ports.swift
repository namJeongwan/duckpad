import DuckpadDomain
import Foundation

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
    /// Explicit file-open/reload boundary. Never called on the normal edit path.
    func install(_ snapshot: EditorTextSnapshot)
    func snapshot(for bufferID: BufferID) -> EditorTextSnapshot?
    func retire(bufferID: BufferID)
    func setInputEnabled(_ isEnabled: Bool)
    func focus()
    func recoverySnapshot(for bufferID: BufferID) -> EditorRecoverySnapshot?
    func recoveryCapture(for bufferID: BufferID) -> EditorRecoveryCapture?
    func acknowledgeRecoverySnapshot(_ snapshot: EditorRecoverySnapshot)
    func installRecovery(_ snapshot: EditorRecoverySnapshot)
}

/// View-only editor controls. Implementations keep these options outside the
/// document text transaction while recovery captures their visible state.
@MainActor
public protocol EditorViewOptionsPort: EditorPort {
    var isWordWrapEnabled: Bool { get }
    var isWrapMarkerVisible: Bool { get }
    var supportsWrapMarker: Bool { get }
    func setWordWrapEnabled(_ isEnabled: Bool)
    func setWrapMarkerVisible(_ isVisible: Bool)
}

/// Line bookmarks are view metadata: they move with editor lines, survive
/// recovery, and never mutate document bytes, revision, dirty state, or undo.
@MainActor
public protocol BookmarkEditorPort: EditorPort {
    var hasBookmarks: Bool { get }
    func toggleBookmarkAtCaret()
    @discardableResult func navigateToBookmark(forward: Bool) -> Bool
    func clearBookmarks()
}

public enum EditorSplitOrientation: String, Codable, Equatable, Sendable {
    case sideBySide
    case stacked
}

/// A split keeps one shared document/undo history while each pane owns its
/// cursor, selection, wrapping, and scroll position.
@MainActor
public protocol SplitEditorPort: EditorPort {
    var splitOrientation: EditorSplitOrientation? { get }
    func split(orientation: EditorSplitOrientation)
    func closeSplit()
    func focusOtherPane()
}

/// Platform-neutral edit commands surfaced by the native menu. Application
/// owns the intent while each editor adapter owns its responder/engine details.
public enum EditorCommand: Equatable, Sendable {
    case undo
    case redo
    case cut
    case copy
    case paste
    case delete
    case selectAll
    case duplicateLine
    case moveLineUp
    case moveLineDown
    case deleteLine
    case joinLines
    case uppercase
    case lowercase
    case indent
    case unindent
    case trimTrailingWhitespace
}

@MainActor
public protocol EditorCommandPort: EditorPort {
    func canPerform(_ command: EditorCommand) -> Bool
    func perform(_ command: EditorCommand)
}

public enum EditorThemePalette: Equatable, Sendable {
    case light
    case dark
    case highContrastLight
    case highContrastDark
}

public struct EditorLanguageConfiguration: Equatable, Sendable {
    public let languageID: LanguageID
    public let lexerName: String
    public let keywords: [String]
    public let indentation: LanguageIndentation
    public let folding: Bool
    public let braceMatching: Bool
    public let maximumStyleBytes: Int

    public init(
        languageID: LanguageID,
        lexerName: String,
        keywords: [String] = [],
        indentation: LanguageIndentation,
        folding: Bool,
        braceMatching: Bool,
        maximumStyleBytes: Int = 16 * 1_024 * 1_024
    ) {
        self.languageID = languageID
        self.lexerName = lexerName
        self.keywords = keywords
        self.indentation = indentation
        self.folding = folding
        self.braceMatching = braceMatching
        self.maximumStyleBytes = max(1_024, maximumStyleBytes)
    }
}

@MainActor
public protocol LanguageEditorPort: EditorPort {
    var activeLanguageID: LanguageID { get }
    var isLanguageStylingFallback: Bool { get }
    var activeDocumentByteLength: Int { get }
    func detectionPrefix(maximumBytes: Int) -> Data
    func supportsLexer(named name: String) -> Bool
    @discardableResult func applyLanguage(_ configuration: EditorLanguageConfiguration) -> Bool
    func applyTheme(_ palette: EditorThemePalette)
    func toggleLineComment(prefix: String) -> EditorEditOutcome
}

public extension EditorPort {
    func recoverySnapshot(for bufferID: BufferID) -> EditorRecoverySnapshot? {
        guard let snapshot = snapshot(for: bufferID) else { return nil }
        return EditorRecoverySnapshot(
            bufferID: bufferID,
            revision: snapshot.revision,
            utf8: Data(snapshot.text.utf8)
        )
    }

    func recoveryCapture(for bufferID: BufferID) -> EditorRecoveryCapture? {
        guard let snapshot = recoverySnapshot(for: bufferID) else { return nil }
        return EditorRecoveryCapture(
            bufferID: snapshot.bufferID,
            baseRevision: snapshot.revision,
            revision: snapshot.revision,
            baseUTF8: snapshot.utf8,
            viewState: snapshot.viewState
        )
    }

    func acknowledgeRecoverySnapshot(_ snapshot: EditorRecoverySnapshot) {}

    func installRecovery(_ snapshot: EditorRecoverySnapshot) {
        guard let text = String(data: snapshot.utf8, encoding: .utf8) else { return }
        install(EditorTextSnapshot(bufferID: snapshot.bufferID, revision: snapshot.revision, text: text))
    }
}
