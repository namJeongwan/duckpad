import Darwin
import DuckpadApplication
import Foundation

public struct LocalFileObservationReader: FileObservationReading {
    public init() {}
    public func read(_ source: FileObservationSource, after cursor: FileObservationCursor?, maximumBytes: Int) async throws -> FileObservationRead {
        guard case .local(let path) = source, maximumBytes > 0, maximumBytes <= 4 * 1_024 * 1_024 else {
            throw FileObservationError.invalidResponse
        }
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw FileObservationError.unavailable }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
                throw FileObservationError.unavailable
            }
            let identity = "\(UInt32(bitPattern: info.st_dev)):\(info.st_ino)"
            let size = UInt64(info.st_size)
            let reset = cursor != nil && (cursor!.identity != identity || cursor!.offset > size)
            let offset = reset ? 0 : cursor?.offset ?? 0
            let count = min(UInt64(maximumBytes), size - offset)
            var data = Data(count: Int(count))
            let actual = data.withUnsafeMutableBytes { bytes in
                pread(fd, bytes.baseAddress, bytes.count, off_t(offset))
            }
            guard actual >= 0 else { throw FileObservationError.unavailable }
            data.count = actual
            try Task.checkCancellation()
            return FileObservationRead(data: data, cursor: .init(identity: identity, offset: offset + UInt64(actual)), sourceSize: size, reset: reset)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
