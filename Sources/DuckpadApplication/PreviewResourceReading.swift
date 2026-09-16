import Foundation

/// A chunked resource stream; the reader owns filesystem policy and I/O.
public protocol PreviewResourceStream: Sendable {
    func read() async throws -> Data
    func close() async
}

public protocol PreviewResourceReading: Sendable {
    func open(_ url: URL) async throws -> any PreviewResourceStream
}
