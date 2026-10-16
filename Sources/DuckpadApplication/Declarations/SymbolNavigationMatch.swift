import DuckpadDomain
import Foundation

public enum SymbolNavigationKind: Sendable { case declarations, references }

/// A syntax-based location. References are name matches, not semantic bindings.
public struct SymbolNavigationMatch: Equatable, Sendable {
    public let name: String
    public let range: SearchUTF8Range
    public let line: Int
    public init(name: String, range: SearchUTF8Range, line: Int) {
        self.name = name; self.range = range; self.line = line
    }
    public init(_ declaration: Declaration) {
        self.init(name: declaration.name, range: declaration.range, line: declaration.line)
    }
    /// Bounded context even when the containing line is megabytes long.
    public func preview(in data: Data) -> String {
        let position = min(max(0, range.location), data.count)
        var start = position, end = position
        while start > max(0, position - 100), data[start - 1] != 10, data[start - 1] != 13 { start -= 1 }
        while end < min(data.count, position + 160), data[end] != 10, data[end] != 13 { end += 1 }
        return String(decoding: data[start..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
