import Darwin
import DuckpadApplication
import DuckpadDomain
import Foundation

/// Every component is opened relative to the pinned root, without following links.
/// Content is read into immutable Data for the native matcher. The helper only
/// discovers filenames and never reads file contents or edits source files.
final class FolderSearchRoot {
    struct File {
        let descriptor: Int32
        let relativePath: String
        let info: stat
    }
    let url: URL
    let descriptor: Int32
    private let scoped: URL
    private let hasScope: Bool
    private let info: stat

    init(path: String) throws {
        scoped = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        hasScope = scoped.startAccessingSecurityScopedResource()
        url = scoped.resolvingSymlinksInPath().standardizedFileURL
        descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var info = stat()
        guard descriptor >= 0, fstat(descriptor, &info) == 0,
              LocalFolderSearchFileStore.fileType(info) == S_IFDIR else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            if hasScope { scoped.stopAccessingSecurityScopedResource() }
            throw FolderSearchFailure.invalidRoot(path)
        }
        self.info = info
    }
    deinit { Darwin.close(descriptor); if hasScope { scoped.stopAccessingSecurityScopedResource() } }

    var fileNameRoot: FolderFileNameRoot {
        .init(canonicalPath: url.path, device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    func validate() throws {
        var current = stat()
        guard Darwin.lstat(url.path, &current) == 0, current.st_dev == info.st_dev,
              current.st_ino == info.st_ino, LocalFolderSearchFileStore.fileType(current) == S_IFDIR else {
            throw FolderSearchFailure.enumerationFailed("selected folder changed during search")
        }
    }

    func open(_ relative: String, includeHiddenFiles: Bool = false) -> File? {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, !relative.utf8.contains(0), components.count <= 257,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && (includeHiddenFiles || !$0.hasPrefix(".")) }) else { return nil }
        var parent = descriptor
        defer { if parent != descriptor { Darwin.close(parent) } }
        var display = url
        for part in components.dropLast() {
            display.appendPathComponent(String(part))
            let next = Darwin.openat(parent, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard next >= 0 else { return nil }
            var status = stat()
            guard fstat(next, &status) == 0, (includeHiddenFiles || status.st_flags & UInt32(UF_HIDDEN) == 0),
                  !LocalFolderSearchFileStore.isPackageDirectory(name: String(part), displayPath: display.path) else {
                Darwin.close(next); return nil
            }
            if parent != descriptor { Darwin.close(parent) }
            parent = next
        }
        let leaf = Darwin.openat(parent, String(components.last!), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard leaf >= 0 else { return nil }
        var status = stat()
        guard fstat(leaf, &status) == 0, LocalFolderSearchFileStore.fileType(status) == S_IFREG,
              (includeHiddenFiles || status.st_flags & UInt32(UF_HIDDEN) == 0), status.st_size >= 0 else { Darwin.close(leaf); return nil }
        return .init(descriptor: leaf, relativePath: relative, info: status)
    }

    func read(_ file: File, maximumBytes: Int) throws -> FolderSearchFile? {
        var before = stat(), after = stat()
        guard fstat(file.descriptor, &before) == 0,
              LocalFolderSearchFileStore.sameSnapshot(file.info, before),
              lseek(file.descriptor, 0, SEEK_SET) == 0 else { return nil }
        let data = try LocalFolderSearchFileStore.boundedRead(descriptor: file.descriptor, documentLimit: maximumBytes, aggregateLimit: maximumBytes)
        guard fstat(file.descriptor, &after) == 0, LocalFolderSearchFileStore.sameSnapshot(before, after),
              after.st_size == data.count else { return nil }
        let path = url.appendingPathComponent(file.relativePath).path
        return .init(path: path, relativePath: file.relativePath, data: data,
            identity: LocalFolderSearchFileStore.identity(path: path, info: after, data: data))
    }
}
