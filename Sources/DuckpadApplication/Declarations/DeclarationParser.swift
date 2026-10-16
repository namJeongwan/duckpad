import Foundation
import DuckpadDomain

/// A bounded lexical index. Unsupported/ambiguous syntax is left unresolved.
enum DeclarationParser {
    struct Token { let text: String; let start: Int; let end: Int; let line: Int; let indent: Int; var scope = 0; var pythonContinuation = false }
    struct Scope { let parent: Int; let start: Int; var end: Int; let depth: Int; var isType = false }
    static func parse(_ data: Data, language: String) -> DeclarationIndex {
        let empty = DeclarationIndex(declarations: [], words: [], isComplete: false)
        guard DeclarationLanguage.supported.contains(language), data.count <= DeclarationIndex.maximumBytes,
              String(data: data, encoding: .utf8) != nil else { return empty }
        let bytes = [UInt8](data)
        var tokens: [Token] = [], i = 0, line = 1, indent = 0, atLineStart = true
        func isWord(_ byte: UInt8) -> Bool { byte >= 128 || byte == 95 || byte == 36 || (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) }
        func identifier(_ text: String) -> Bool {
            guard let first = text.unicodeScalars.first, first == "_" || first == "$" || CharacterSet.letters.contains(first) else { return false }
            return text.unicodeScalars.allSatisfy { $0 == "_" || $0 == "$" || CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0) }
        }
        // Comments and literals never contribute declaration or query tokens.
        while i < bytes.count {
            if i.isMultiple(of: 4096), Task.isCancelled { return empty }
            if tokens.count >= 200_000 { return empty }
            let b = bytes[i]
            if b == 10 || b == 13 {
                if b == 13, i + 1 < bytes.count, bytes[i + 1] == 10 { i += 1 }
                i += 1; line += 1; indent = 0; atLineStart = true; continue
            }
            if b == 32 || b == 9 {
                if atLineStart { indent = b == 9 ? (indent / 8 + 1) * 8 : indent + 1 }
                i += 1; continue
            }
            atLineStart = false
            if (language == "python" && b == 35) || (b == 47 && i + 1 < bytes.count && bytes[i + 1] == 47) {
                while i < bytes.count && bytes[i] != 10 && bytes[i] != 13 { i += 1 }; continue
            }
            if b == 47, i + 1 < bytes.count, bytes[i + 1] == 42 {
                i += 2; var nesting = 1
                while i < bytes.count && nesting > 0 {
                    if i.isMultiple(of: 4096), Task.isCancelled { return empty }
                    if bytes[i] == 10 { line += 1 }
                    if i + 1 < bytes.count, bytes[i] == 42, bytes[i + 1] == 47 { nesting -= 1; i += 2 }
                    else if ["swift", "rust"].contains(language), i + 1 < bytes.count, bytes[i] == 47, bytes[i + 1] == 42 { nesting += 1; i += 2 }
                    else { i += 1 }
                }
                continue
            }
            // Regex/division is context-sensitive. Never index a possible regex as code.
            if ["javascript", "typescript"].contains(language), b == 47 {
                let previous = tokens.last?.text
                var expressionStart = previous.map { ["=", "(", "[", "{", ":", ",", ";", "!", "?", "return", "yield"].contains($0) } ?? true
                if previous == ">", tokens.count > 1, tokens[tokens.count - 2].text == "=" { expressionStart = true }
                if previous == ")" {
                    var nesting = 0
                    for n in tokens.indices.reversed() {
                        if tokens[n].text == ")" { nesting += 1 }
                        if tokens[n].text == "(" {
                            nesting -= 1
                            if nesting == 0 {
                                expressionStart = n > 0 && ["if", "while", "for", "with", "switch", "catch"].contains(tokens[n - 1].text)
                                break
                            }
                        }
                    }
                }
                var end = i + 1, inClass = false, closed = false
                while end < bytes.count {
                    if bytes[end] == 92 { end = min(bytes.count, end + 2); continue }
                    if bytes[end] == 10 || bytes[end] == 13 { break }
                    if bytes[end] == 91 { inClass = true }
                    if bytes[end] == 93 { inClass = false }
                    if bytes[end] == 47 && !inClass { end += 1; closed = true; break }
                    end += 1
                }
                if closed {
                    guard expressionStart else { return empty }
                    i = end
                    while i < bytes.count && isWord(bytes[i]) { i += 1 }
                    continue
                }
                if expressionStart { return empty }
            }
            // Raw literal delimiters need a full language grammar; fail closed
            // instead of turning embedded source examples into declarations.
            if language == "swift", b == 35, i + 1 < bytes.count, bytes[i + 1] == 34 { return empty }
            if b == 34 || b == 39 || b == 96 {
                // Rust lifetimes are identifiers prefixed by ', not strings.
                if language == "rust", b == 39, i + 1 < bytes.count, isWord(bytes[i + 1]),
                   !(i + 2 < bytes.count && bytes[i + 2] == 39) { i += 1; continue }
                let triple = i + 2 < bytes.count && bytes[i + 1] == b && bytes[i + 2] == b
                let width = triple ? 3 : 1
                i += width
                while i < bytes.count {
                    if i.isMultiple(of: 4096), Task.isCancelled { return empty }
                    if bytes[i] == 10 { line += 1 }
                    if bytes[i] == 92 { i = min(i + 2, bytes.count); continue }
                    if bytes[i] == b, !triple || (i + 2 < bytes.count && bytes[i + 1] == b && bytes[i + 2] == b) { i += width; break }
                    i += 1
                }
                continue
            }
            let start = i
            if isWord(b) { while i < bytes.count && isWord(bytes[i]) { i += 1 } }
            else { i += 1 }
            guard i - start <= 256 else { continue }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            if language == "cpp", ["R", "u8R", "uR", "UR", "LR"].contains(text), i < bytes.count, bytes[i] == 34 { return empty }
            if language == "rust", ["r", "br", "cr"].contains(text) {
                var end = i
                while end < bytes.count && bytes[end] == 35 { end += 1 }
                if end < bytes.count && bytes[end] == 34 { return empty }
            }
            tokens.append(Token(text: text, start: start, end: i, line: line, indent: indent))
        }
        var scopes = [Scope(parent: 0, start: 0, end: bytes.count + 1, depth: 0)]
        var stack = [0], indents = [0], braces: [Int: Int] = [:]
        var pythonBodies: [Int: Int] = [:], bracketDepth = 0
        var header: (name: Int, indent: Int)?
        var suite: (name: Int, indent: Int, line: Int)?
        for n in tokens.indices {
            if language == "python" {
                let beginsLine = n == 0 || tokens[n].line != tokens[n - 1].line
                if beginsLine && bracketDepth == 0 {
                    while indents.count > 1 && tokens[n].indent < indents.last! {
                        scopes[stack.removeLast()].end = tokens[n].start; indents.removeLast()
                    }
                }
                // Only a complete def/class header followed by its suite opens a
                // lexical scope. Continuation indentation belongs to the header.
                if let pending = suite {
                    let inline = tokens[n].line == pending.line
                    guard inline || tokens[n].indent > pending.indent else { return empty }
                    scopes.append(Scope(parent: stack.last!, start: tokens[n].start, end: bytes.count + 1, depth: stack.count))
                    stack.append(scopes.count - 1)
                    indents.append(inline ? pending.indent + 1 : tokens[n].indent)
                    pythonBodies[pending.name] = scopes.count - 1
                    suite = nil
                }
                tokens[n].pythonContinuation = header != nil || bracketDepth > 0
                if ["def", "class"].contains(tokens[n].text), n + 1 < tokens.count {
                    header = (n + 1, tokens[n].indent)
                }
                if ["(", "[", "{"].contains(tokens[n].text) { bracketDepth += 1 }
                if [")", "]", "}"].contains(tokens[n].text) { bracketDepth = max(0, bracketDepth - 1) }
                if tokens[n].text == ":", bracketDepth == 0, let pending = header {
                    suite = (pending.name, pending.indent, tokens[n].line); header = nil
                }
            }
            tokens[n].scope = stack.last!
            if language != "python", tokens[n].text == "{" {
                scopes.append(Scope(parent: stack.last!, start: tokens[n].end, end: bytes.count + 1, depth: stack.count))
                braces[n] = scopes.count - 1; stack.append(scopes.count - 1)
            } else if language != "python", tokens[n].text == "}", stack.count > 1 {
                scopes[stack.removeLast()].end = tokens[n].end
            }
        }
        let types: Set<String> = ["class", "struct", "enum", "protocol", "actor", "interface", "trait", "type", "namespace", "record"]
        let funcs: Set<String> = ["func", "function", "def", "fn"]
        let vars: Set<String> = ["let", "var", "const"]
        let nonTypes: Set<String> = ["return", "throw", "new", "await", "yield", "case", "else", "import", "package", "using", "delete", "if", "while", "for", "switch", "catch"]
        var found: [(Int, DocumentSymbolKind, Int)] = []
        var parentheses: [Int: Int] = [:], opens: [Int] = []
        for n in tokens.indices {
            if tokens[n].text == "(" { opens.append(n) }
            if tokens[n].text == ")", let open = opens.popLast() { parentheses[open] = n }
        }
        for n in tokens.indices {
            if n.isMultiple(of: 1024), Task.isCancelled { return empty }
            let token = tokens[n]
            guard identifier(token.text) else { continue }
            let previous = n > 0 ? tokens[n - 1].text : ""
            let next = n + 1 < tokens.count ? tokens[n + 1].text : ""
            var kind: DocumentSymbolKind?
            if language == "protobuf" {
                if ["message", "enum", "service"].contains(previous), next == "{" { kind = .type }
                else if previous == "rpc", next == "(" { kind = .function }
                else if previous == "oneof", next == "{" { kind = .property }
            }
            else if types.contains(previous) { kind = .type }
            else if funcs.contains(previous) || (previous == "*" && n > 1 && tokens[n - 2].text == "function") { kind = .function }
            else if vars.contains(previous) || (previous == "mut" && n > 1 && tokens[n - 2].text == "let") { kind = .property }
            else if language == "python", !token.pythonContinuation, next == "=", (n == 0 || tokens[n - 1].line != token.line) { kind = .property }
            else if language == "go", next == ":", n + 2 < tokens.count, tokens[n + 2].text == "=" { kind = .property }
            else if ["c", "cpp", "java", "csharp"].contains(language), identifier(previous), !nonTypes.contains(previous),
                    n < 2 || ![".", "=", "return", "new"].contains(tokens[n - 2].text) {
                if next == "(", let close = parentheses[n + 1], close + 1 < tokens.count, ["{", ";"].contains(tokens[close + 1].text) { kind = .function }
                else if ["=", ";", ","].contains(next) { kind = .property }
            }
            guard let kind else { continue }
            found.append((n, kind, token.scope))
            if kind == .type || kind == .function {
                let end = min(tokens.count, n + 512)
                let body = (n + 1..<end).first { tokens[$0].text == "{" || (language == "python" && tokens[$0].line > token.line && tokens[$0].indent > token.indent) || tokens[$0].text == ";" }
                let bodyScope = language == "python" ? pythonBodies[n] : body.flatMap { braces[$0] }
                if let bodyScope, kind == .type { scopes[bodyScope].isType = true }
                // Protobuf RPC parentheses contain message types, not parameter declarations.
                if language != "protobuf", kind == .function, next == "(", let close = parentheses[n + 1], let bodyScope {
                    var start = n + 2
                    for stop in start...close where stop == close || tokens[stop].text == "," {
                        let segment = Array(start..<stop); start = stop + 1
                        let beforeDefault = segment.prefix { tokens[$0].text != "=" }
                        let ids = beforeDefault.filter { identifier(tokens[$0].text) && !["inout", "mut", "const", "ref", "out"].contains(tokens[$0].text) }
                        let parameter: Int?
                        if ["swift", "rust"].contains(language), let colon = beforeDefault.first(where: { tokens[$0].text == ":" }) { parameter = ids.last(where: { $0 < colon }) }
                        else if ["c", "cpp", "java", "csharp"].contains(language) { parameter = ids.count > 1 ? ids.last : nil }
                        else { parameter = ids.first }
                        if let parameter { found.append((parameter, .property, bodyScope)) }
                    }
                }
            }
        }
        let declarations = found.map { n, kind, scopeID in
            let t = tokens[n], s = scopes[scopeID]
            // Only file and direct type members enter cross-file lookup.
            let visible = scopeID == 0 || (s.isType && scopes[s.parent].depth == 0)
            return Declaration(name: t.text, kind: kind, range: SearchUTF8Range(location: t.start, length: t.end - t.start), line: t.line,
                               scope: s.start..<s.end, depth: s.depth, isProjectVisible: visible)
        }
        return DeclarationIndex(declarations: declarations, words: tokens.indices.filter { identifier(tokens[$0].text) }.map {
            .init(text: tokens[$0].text, range: tokens[$0].start..<tokens[$0].end,
                  qualified: $0 > 0 && (tokens[$0 - 1].text == "." || ($0 > 1 && tokens[$0 - 1].text == ":" && tokens[$0 - 2].text == ":")), line: tokens[$0].line)
        }, isComplete: true)
    }
}
