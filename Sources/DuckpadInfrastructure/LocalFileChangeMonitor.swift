import Darwin
import Foundation
import DuckpadApplication

/// Metadata-only checks also detect atomic replacement, deletion/recreation,
/// and changes made while Duckpad is in the background. No document is read
/// or hashed until its stamp changes and stays stable for another tick.
@MainActor
public final class LocalFileChangeMonitor: FileChangeMonitoring {
    private struct Stamp: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
        let error: Int32
    }
    public var onChange: ((Set<String>) -> Void)?
    private var paths: Set<String> = []
    private var seen: [String: Stamp] = [:]
    private var delivered: [String: Stamp] = [:]
    private var task: Task<Void, Never>?
    private let interval: Duration

    public init(interval: Duration = .milliseconds(250)) { self.interval = interval }
    deinit { task?.cancel() }

    public func watch(paths: Set<String>) {
        self.paths = paths
        seen = seen.filter { paths.contains($0.key) }
        delivered = delivered.filter { paths.contains($0.key) }
        guard !paths.isEmpty else { stop(); return }
        guard task == nil else { return }
        let interval = interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                let watched = self.paths
                let stamps = await Task.detached(priority: .utility) {
                    Dictionary(uniqueKeysWithValues: watched.map { path in
                        var info = stat()
                        let error = Darwin.fstatat(AT_FDCWD, path, &info, 0) == 0 ? 0 : errno
                        return (path, Stamp(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
                            changedSeconds: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec, error: error))
                    })
                }.value
                guard !Task.isCancelled else { return }
                var changed = Set<String>()
                for (path, stamp) in stamps where self.paths.contains(path) {
                    if self.seen[path] == stamp && self.delivered[path] != stamp {
                        self.delivered[path] = stamp
                        changed.insert(path)
                    }
                    self.seen[path] = stamp
                }
                if !changed.isEmpty { self.onChange?(changed) }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        paths.removeAll()
        seen.removeAll()
        delivered.removeAll()
    }
}
