import Foundation

public struct SnippetSession {
    private var fields: [SnippetExpansion.Field]
    private let order: [Int]
    private var position = 0
    public var ranges: [NSRange] { fields.filter { $0.number == order[position] }.map(\.range) }
    public var isFinal: Bool { order[position] == 0 }

    public init(expansion: SnippetExpansion, offset: Int) {
        fields = expansion.fields.map { field in
            var field = field; field.range.location += offset; return field
        }
        order = Set(fields.map(\.number)).filter { $0 != 0 }.sorted() + [0]
    }

    public mutating func move(backwards: Bool) -> Bool {
        let next = position + (backwards ? -1 : 1)
        guard order.indices.contains(next) else { return false }
        position = next; return true
    }

    public mutating func apply(range: NSRange, replacementBytes: Int) -> Bool {
        guard let edited = fields.indices.first(where: {
            fields[$0].number == order[position] && range.location >= fields[$0].range.location && NSMaxRange(range) <= NSMaxRange(fields[$0].range)
        }) else { return false }
        let difference = replacementBytes - range.length
        for i in fields.indices {
            if i == edited { fields[i].range.length += difference }
            else if fields[i].range.location >= NSMaxRange(range) { fields[i].range.location += difference }
            else if NSIntersectionRange(fields[i].range, range).length > 0 { return false }
        }
        return true
    }
}
