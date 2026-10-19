import Foundation

/// The document's requested output format, independent of bytes last saved.
public struct DocumentFileFormat: Codable, Equatable, Sendable {
    public let encoding: TextFileEncoding
    public let byteOrderMark: ByteOrderMark
    public let lineEnding: LineEnding

    public init(encoding: TextFileEncoding, byteOrderMark: ByteOrderMark, lineEnding: LineEnding) {
        self.encoding = encoding
        self.byteOrderMark = byteOrderMark
        self.lineEnding = lineEnding
    }
}
