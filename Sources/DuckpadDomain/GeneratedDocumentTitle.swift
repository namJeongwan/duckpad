/// Display metadata for app-generated names. Raw titles and user filenames stay intact.
public enum GeneratedDocumentTitle: Codable, Equatable, Sendable {
    case untitled(Int)
    case restored(String)
}
