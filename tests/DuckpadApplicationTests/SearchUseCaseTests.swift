import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
import Testing

private let regexEngine = ICURegexEngine()

private func snapshot(_ text: String) -> SearchBufferSnapshot {
    SearchBufferSnapshot(tabID: TabID(), title: "sample", bufferID: BufferID(), revision: 3, utf8: Data(text.utf8))
}

private func matches(_ text: String, _ query: SearchQuery, restrictTo: SearchUTF8Range? = nil, limit: Int = 100_000) throws -> [SearchMatch] {
    try SearchEngine.matches(in: snapshot(text), query: query, restrictTo: restrictTo, limit: limit, regexEngine: regexEngine)
}

@Test func literalCaseWholeWordAndUnicodeRanges() throws {
    var options = SearchOptions(matchCase: false, wholeWord: true)
    #expect(try matches("duck Duck duckling", SearchQuery(pattern: "duck", options: options)).count == 2)
    options.matchCase = true
    let korean = try matches("한글 한글자", SearchQuery(pattern: "한글", options: options))
    #expect(korean.count == 1)
    #expect(korean[0].range.length == 6)
    let emoji = try matches("🦆🦆", SearchQuery(pattern: "🦆"))
    #expect(emoji.count == 2)
    #expect(emoji.allSatisfy { $0.range.length == 4 })
}

@Test func extendedEscapesIncludeNULNewlineTabAndBackslash() throws {
    #expect(try SearchPatternCodec.decodeExtended("A\\0B\\nC\\r\\t\\\\") == Data([65, 0, 66, 10, 67, 13, 9, 92]))
    #expect(throws: SearchFailure.invalidExtendedEscape(offset: 0)) { try SearchPatternCodec.decodeExtended("\\x") }
    let found = try matches("A\0B\nC", SearchQuery(pattern: "\\0B", options: SearchOptions(mode: .extended)))
    #expect(found.map(\.range) == [SearchUTF8Range(location: 1, length: 2)])
}

@Test func regexCapturesLookaheadDotAllAndReplacement() throws {
    let text = "ab12\r\nab34\r끝"
    let query = SearchQuery(pattern: "ab(\\d+)", replacement: "[$1]", options: SearchOptions(mode: .regularExpression, matchCase: true))
    let found = try SearchEngine.matches(
        in: snapshot(text), query: query, regexEngine: regexEngine,
        includeReplacement: true
    )
    #expect(found.count == 2)
    #expect(found[1].line == 2)
    #expect(String(data: try SearchEngine.replacement(for: found[0], in: snapshot(text), query: query), encoding: .utf8) == "[12]")
    #expect(try matches(text, SearchQuery(pattern: "(?=ab)", options: SearchOptions(mode: .regularExpression))).allSatisfy { $0.range.length == 0 })
    #expect(throws: SearchFailure.self) { try matches(text, SearchQuery(pattern: "(", options: SearchOptions(mode: .regularExpression))) }
    #expect(try matches(text, SearchQuery(pattern: "(ab)+", options: SearchOptions(mode: .regularExpression))).count == 2)
    #expect(try matches("a\nb", SearchQuery(pattern: "a.b", options: SearchOptions(mode: .regularExpression, dotMatchesNewline: true))).count == 1)
}

@Test func selectionBoundsAndCRLFLineColumnAreUTF8Accurate() throws {
    let text = "한🙂\r\nsecond 🙂\rthird"
    let all = try matches(text, SearchQuery(pattern: "🙂"))
    #expect(all.count == 2)
    #expect(all[0].line == 1)
    #expect(all[1].line == 2)
    #expect(all[1].column == 8)
    #expect(try matches(text, SearchQuery(pattern: "🙂"), restrictTo: all[1].range).map(\.range) == [all[1].range])
    #expect(throws: SearchFailure.invalidUTF8Range) {
        try matches(text, SearchQuery(pattern: "🙂"), restrictTo: SearchUTF8Range(location: 1, length: 1))
    }
}

@Test func fiftyMiBLiteralScanUsesBoundedMatchCount() throws {
    let size = 50 * 1_024 * 1_024
    var data = Data(repeating: 0x61, count: size)
    data.append(contentsOf: "🦆needle".utf8)
    let large = SearchBufferSnapshot(tabID: TabID(), title: "large", bufferID: BufferID(), revision: 0, utf8: data)
    var found: [SearchMatch] = []
    let elapsed = try ContinuousClock().measure {
        found = try SearchEngine.matches(
            in: large,
            query: SearchQuery(pattern: "🦆needle", options: SearchOptions(matchCase: true)),
            limit: 2, regexEngine: regexEngine
        )
    }
    #expect(found.map(\.range.location) == [size])
    #expect(elapsed < .seconds(15))
}

@Test func ICUHardBudgetMapsPathologicalExpression() throws {
    let engine = ICURegexEngine(timeLimitMilliseconds: 1, stackLimitBytes: 64 * 1_024)
    let input = Data((String(repeating: "a", count: 200_000) + "!").utf8)
    do {
        _ = try engine.matches(pattern: "(a+)+$", utf8: input, matchCase: true, dotMatchesNewline: false, restrictTo: nil, maximumMatches: 2)
        Issue.record("catastrophic regex must hit a hard ICU budget")
    } catch let error {
        #expect(error == .timedOut || error == .tooComplex)
    }
}

@Test func ICUDirectionalMatchIsIndependentOfGlobalResultCapAndHandlesZeroLength() throws {
    let engine = ICURegexEngine()
    let text = String(repeating: "a ", count: 120_000)
    let bytes = Data(text.utf8)
    let nearEnd = SearchUTF8Range(location: bytes.count - 20, length: 20)
    let forward = try engine.directionalMatch(
        pattern: "a", utf8: bytes, matchCase: true, dotMatchesNewline: false,
        restrictTo: nearEnd, backwards: false
    )
    let backward = try engine.directionalMatch(
        pattern: "a", utf8: bytes, matchCase: true, dotMatchesNewline: false,
        restrictTo: SearchUTF8Range(location: 0, length: bytes.count - 1), backwards: true
    )
    #expect(forward?.range.location == bytes.count - 20)
    #expect(backward?.range.location == bytes.count - 2)
    let zero = try engine.directionalMatch(
        pattern: "(?=a)", utf8: bytes, matchCase: true, dotMatchesNewline: false,
        restrictTo: nearEnd, backwards: false
    )
    #expect(zero?.range.length == 0)
}
