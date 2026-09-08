import DuckpadDomain

public struct OpenDocumentComparison: Equatable, Sendable {
    public enum Side: Equatable, Sendable {
        case left
        case right
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case sameTab(TabID)
        case missingTab(TabID)
        case missingSnapshot(BufferID)
        case staleSnapshot(bufferID: BufferID, expectedRevision: UInt64, actualRevision: UInt64)
        case inputTooLarge(side: Side, byteCount: Int, maximum: Int)
        case tooManyLines(side: Side, lineCount: Int, maximum: Int)
        case complexityExceeded(maximumRows: Int)
        case cancelled
    }

    public struct Limits: Equatable, Sendable {
        public static let `default` = Limits()

        public let maximumUTF8BytesPerSide: Int
        public let maximumLinesPerSide: Int
        public let maximumDiffSteps: Int
        public let maximumAlignedRows: Int

        public init(
            maximumUTF8BytesPerSide: Int = 32 * 1_024 * 1_024,
            maximumLinesPerSide: Int = 50_000,
            maximumDiffSteps: Int = 2_000_000,
            maximumAlignedRows: Int = 100_000
        ) {
            self.maximumUTF8BytesPerSide = max(0, maximumUTF8BytesPerSide)
            self.maximumLinesPerSide = max(0, maximumLinesPerSide)
            self.maximumDiffSteps = max(0, maximumDiffSteps)
            self.maximumAlignedRows = max(0, maximumAlignedRows)
        }
    }

    public struct Document: Equatable, Sendable {
        public let tabID: TabID
        public let title: String
        public let fullPath: String?
        public let bufferID: BufferID
        public let revision: UInt64
        public let text: String

        public init(
            tabID: TabID,
            title: String,
            fullPath: String?,
            bufferID: BufferID,
            revision: UInt64,
            text: String
        ) {
            self.tabID = tabID
            self.title = title
            self.fullPath = fullPath
            self.bufferID = bufferID
            self.revision = revision
            self.text = text
        }
    }

    public let left: Document
    public let right: Document

    public init(left: Document, right: Document) {
        self.left = left
        self.right = right
    }
}
