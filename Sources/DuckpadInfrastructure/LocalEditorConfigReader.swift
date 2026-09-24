import DuckpadApplication
import DuckpadDomain
import Foundation

public struct LocalEditorConfigReader: EditorConfigReading {
    private let accessStore: (any TextFileStore)?

    public init(accessStore: (any TextFileStore)? = nil) {
        self.accessStore = accessStore
    }

    public func conventions(for file: URL) async -> EditorConventions {
        await Task.detached(priority: .utility) {
            var directory = file.standardizedFileURL.deletingLastPathComponent()
            var documents: [(EditorConfigDocument, String)] = []
            // Restore only grants already authorized by the user (for example by
            // opening .editorconfig). A document's grant does not cover siblings.
            for _ in 0..<128 {
                if Task.isCancelled { break }
                let url = directory.appendingPathComponent(".editorconfig")
                let owner = UUID()
                let access = try? await accessStore?.prepareSecurityScopedAccess(to: url, ownerID: owner)
                let document = Self.readDocument(at: access?.url ?? url)
                if let access {
                    await accessStore?.releaseSecurityScopedAccess(forCanonicalPath: access.url.path, ownerID: owner)
                }
                if let document {
                    let prefix = directory.path == "/" ? "/" : directory.path + "/"
                    documents.append((document, String(file.standardizedFileURL.path.dropFirst(prefix.count))))
                    if document.isRoot { break }
                }
                let parent = directory.deletingLastPathComponent()
                if parent == directory { break }
                directory = parent
            }
            var result: [String: String] = [:]
            for (document, path) in documents.reversed() { document.apply(to: &result, relativePath: path) }
            return EditorConventions(properties: result)
        }.value
    }

    private static func readDocument(at url: URL) -> EditorConfigDocument? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? Int.max) <= 1_048_576,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_048_577), data.count <= 1_048_576,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return EditorConfigDocument(text)
    }
}
