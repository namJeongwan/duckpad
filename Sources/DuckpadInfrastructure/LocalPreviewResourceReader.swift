import Darwin
import DuckpadApplication
import Foundation

public struct LocalPreviewResourceReader: PreviewResourceReading {
    public init() {}

    public func open(_ url: URL) async throws -> any PreviewResourceStream {
        try Task.checkCancellation()
        guard url.isFileURL else { throw URLError(.noPermissionsToReadFile) }
        let stream = try await Task.detached(priority: .utility) {
            // Following image symlinks is supported; inspect the opened object,
            // never a path check that could race the open. Sandbox grants apply.
            let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw URLError(.cannotOpenFile) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size >= 0 else {
                Darwin.close(descriptor)
                throw URLError(.cannotOpenFile)
            }
            return LocalPreviewResourceStream(descriptor: descriptor)
        }.value
        if Task.isCancelled {
            await stream.close()
            throw CancellationError()
        }
        return stream
    }
}

private actor LocalPreviewResourceStream: PreviewResourceStream {
    private let handle: FileHandle
    private var closed = false

    init(descriptor: Int32) {
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func read() throws -> Data {
        try Task.checkCancellation()
        guard !closed else { throw URLError(.cancelled) }
        // Preserve support for large and growing regular images. Bound each
        // allocation, and let WebKit cancellation stop subsequent reads.
        return try handle.read(upToCount: 64 * 1_024) ?? Data()
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? handle.close()
    }
}
