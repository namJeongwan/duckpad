import Foundation

public enum MarkdownLinkDestination {
    public static func resolve(_ href: String, relativeTo documentURL: URL?) -> URL? {
        guard !href.isEmpty, href.utf8.count <= 16_384,
              href.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let base = href.hasPrefix("/") ? URL(fileURLWithPath: "/") : documentURL
        guard let url = URL(string: href, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            return url.host?.isEmpty == false ? url : nil
        case "mailto": return url
        case "file":
            guard url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            // File tabs use filesystem paths; query/fragment are not filenames.
            return URL(fileURLWithPath: url.path).standardizedFileURL
        default: return nil
        }
    }
}
