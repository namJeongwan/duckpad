import DuckpadApplication
import Foundation

@MainActor public final class LocalMarkdownImageAccess: MarkdownImageAccess {
    private let defaults: UserDefaults
    private let key = "markdownPreview.imageFolders"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func remember(_ urls: [URL]) {
        var bookmarks = defaults.array(forKey: key) as? [Data] ?? []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard url.isFileURL,
                  let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { continue }
            bookmarks.removeAll { existing in
                var stale = false
                let resolved = try? URL(resolvingBookmarkData: existing, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
                return resolved?.standardizedFileURL.path == url.standardizedFileURL.path
            }
            bookmarks.append(data)
        }
        defaults.set(bookmarks, forKey: key)
    }

    public func acquire() -> [URL] {
        var grants: [URL] = []
        for data in defaults.array(forKey: key) as? [Data] ?? [] {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() { grants.append(url) }
        }
        return grants
    }

    public func release(_ urls: [URL]) {
        urls.forEach { $0.stopAccessingSecurityScopedResource() }
    }
}
