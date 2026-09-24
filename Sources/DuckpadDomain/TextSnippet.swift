import Foundation

public struct TextSnippet: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Empty means any document; otherwise a registry LanguageID.
    public var language: String
    public var body: String
    public init(id: UUID = UUID(), name: String, language: String = "", body: String) {
        self.id = id; self.name = name; self.language = language; self.body = body
    }
}
