import Foundation

public struct DeclarationFileMatch: Sendable {
    public let url: URL
    public let utf8: Data
    public let match: SymbolNavigationMatch
    public init(url: URL, utf8: Data, match: SymbolNavigationMatch) {
        self.url = url; self.utf8 = utf8; self.match = match
    }
}
public struct DeclarationProjectResult: Sendable {
    public let matches: [DeclarationFileMatch]
    public let isComplete: Bool
    public init(matches: [DeclarationFileMatch], isComplete: Bool) { self.matches = matches; self.isComplete = isComplete }
}
public protocol DeclarationProjectSearching: Sendable {
    func find(name: String, language: String, kind: SymbolNavigationKind, roots: [WorkspaceRoot], excludingPaths: Set<String>) async -> DeclarationProjectResult
}
public extension DeclarationProjectSearching {
    func find(name: String, language: String, roots: [WorkspaceRoot], excludingPaths: Set<String>) async -> DeclarationProjectResult
    { await find(name: name, language: language, kind: .declarations, roots: roots, excludingPaths: excludingPaths) }
}
