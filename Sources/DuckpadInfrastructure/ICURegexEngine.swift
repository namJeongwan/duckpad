import DuckpadApplication
import DuckpadDomain
import DuckpadICUBridge
import Foundation

/// Production regex adapter. ICU owns pattern semantics and enforces hard time
/// and stack budgets; no ICU handle or UTF-16 range crosses Infrastructure.
public struct ICURegexEngine: RegexEnginePort {
    public let timeLimitMilliseconds: Int32
    public let stackLimitBytes: Int32
    public let maximumCaptures: Int32

    public init(
        timeLimitMilliseconds: Int32 = 100,
        stackLimitBytes: Int32 = 8 * 1_024 * 1_024,
        maximumCaptures: Int32 = 32
    ) {
        self.timeLimitMilliseconds = timeLimitMilliseconds
        self.stackLimitBytes = stackLimitBytes
        self.maximumCaptures = maximumCaptures
    }

    public func matches(
        pattern: String,
        utf8: Data,
        matchCase: Bool,
        dotMatchesNewline: Bool,
        restrictTo: SearchUTF8Range?,
        maximumMatches: Int
    ) throws(SearchFailure) -> [RegexEngineMatch] {
        guard (maximumMatches == -1 || maximumMatches > 0), maximumMatches <= 100_001,
              pattern.utf8.count <= 64 * 1_024,
              let text = String(data: utf8, encoding: .utf8) else { throw .invalidLimits }
        let utf16 = Array(text.utf16)
        let patternUTF16 = Array(pattern.utf16)
        guard utf16.count <= Int(Int32.max), patternUTF16.count <= Int(Int32.max) else {
            throw .documentTooLarge(actual: utf8.count, limit: Int(Int32.max))
        }
        let region: NSRange
        if let restrictTo {
            guard let swiftRange = Self.stringRange(restrictTo, in: text) else { throw .invalidUTF8Range }
            region = NSRange(swiftRange, in: text)
        } else {
            region = NSRange(location: 0, length: utf16.count)
        }
        var flags: UInt32 = 0
        if !matchCase { flags |= 2 } // UREGEX_CASE_INSENSITIVE
        if dotMatchesNewline { flags |= 32 } // UREGEX_DOTALL
        let raw = patternUTF16.withUnsafeBufferPointer { patternBuffer in
            utf16.withUnsafeBufferPointer { textBuffer in
                dp_icu_regex_find_all(
                    patternBuffer.baseAddress, Int32(patternBuffer.count),
                    textBuffer.baseAddress, Int32(textBuffer.count),
                    Int32(region.location), Int32(NSMaxRange(region)), flags,
                    timeLimitMilliseconds, stackLimitBytes,
                    Int32(maximumMatches), maximumCaptures
                )
            }
        }
        defer { dp_icu_regex_result_free(raw) }
        switch raw.status.rawValue {
        case 0: break
        case 1: throw .invalidRegularExpression("ICU rejected the pattern")
        case 2: throw .timedOut
        case 3, 4: throw .tooComplex
        default: throw .replacementFailed
        }
        guard raw.matchCount >= 0, raw.captureCount >= 0, let ranges = raw.ranges else { return [] }
        let groupSlots = Int(raw.captureCount) + 1
        var requested: Set<Int> = []
        for match in 0..<Int(raw.matchCount) {
            for group in 0..<groupSlots {
                let start = Int(ranges[(match * groupSlots + group) * 2])
                let end = Int(ranges[(match * groupSlots + group) * 2 + 1])
                if start >= 0 { requested.insert(start); requested.insert(end) }
            }
        }
        let offsets = Self.utf8Offsets(forUTF16Offsets: requested, in: text)
        var matches: [RegexEngineMatch] = []
        matches.reserveCapacity(Int(raw.matchCount))
        for match in 0..<Int(raw.matchCount) {
            func range(_ group: Int) throws(SearchFailure) -> SearchUTF8Range? {
                let start16 = Int(ranges[(match * groupSlots + group) * 2])
                let end16 = Int(ranges[(match * groupSlots + group) * 2 + 1])
                guard start16 >= 0 else { return nil }
                guard let start8 = offsets[start16], let end8 = offsets[end16], end8 >= start8 else {
                    throw .invalidUTF8Range
                }
                return SearchUTF8Range(location: start8, length: end8 - start8)
            }
            guard let primary = try range(0) else { throw SearchFailure.invalidUTF8Range }
            var captures: [SearchUTF8Range?] = []
            for group in 1..<groupSlots { captures.append(try range(group)) }
            matches.append(RegexEngineMatch(
                range: primary,
                captures: captures
            ))
        }
        return matches
    }

    public func directionalMatch(
        pattern: String,
        utf8: Data,
        matchCase: Bool,
        dotMatchesNewline: Bool,
        restrictTo: SearchUTF8Range,
        backwards: Bool
    ) throws(SearchFailure) -> RegexEngineMatch? {
        try matches(
            pattern: pattern, utf8: utf8, matchCase: matchCase,
            dotMatchesNewline: dotMatchesNewline, restrictTo: restrictTo,
            maximumMatches: backwards ? -1 : 1
        ).first
    }

    private static func utf8Offsets(forUTF16Offsets requested: Set<Int>, in text: String) -> [Int: Int] {
        let sorted = requested.sorted()
        var result: [Int: Int] = [:]
        var target = 0
        var offset16 = 0
        var offset8 = 0
        for scalar in text.unicodeScalars {
            while target < sorted.count, sorted[target] == offset16 {
                result[sorted[target]] = offset8
                target += 1
            }
            offset16 += scalar.value > 0xFFFF ? 2 : 1
            offset8 += scalar.utf8.count
        }
        while target < sorted.count, sorted[target] == offset16 {
            result[sorted[target]] = offset8
            target += 1
        }
        return result
    }

    private static func stringRange(_ range: SearchUTF8Range, in text: String) -> Range<String.Index>? {
        guard range.location >= 0, range.length >= 0,
              range.location <= text.utf8.count,
              range.length <= text.utf8.count - range.location,
              let lower8 = text.utf8.index(text.utf8.startIndex, offsetBy: range.location, limitedBy: text.utf8.endIndex),
              let upper8 = text.utf8.index(lower8, offsetBy: range.length, limitedBy: text.utf8.endIndex),
              let lower = String.Index(lower8, within: text),
              let upper = String.Index(upper8, within: text) else { return nil }
        return lower..<upper
    }
}
