import DuckpadApplication
import Foundation
@testable import DuckpadPresentation
import Testing

private typealias DiffRow = AlignedLineDiff.Row

private struct RowIdentity: Equatable {
    let left: Int?
    let right: Int?
    let kind: AlignedLineDiff.Kind

    init(_ left: Int?, _ right: Int?, _ kind: AlignedLineDiff.Kind) {
        self.left = left
        self.right = right
        self.kind = kind
    }
}

private func lineNumbers(_ rows: [DiffRow]) -> [RowIdentity] {
    rows.map { RowIdentity($0.left?.number, $0.right?.number, $0.kind) }
}

private func logicalLineCount(_ text: String) -> Int {
    var count = 1
    var previousWasCarriageReturn = false
    for byte in text.utf8 {
        if byte == 0x0D {
            count += 1
            previousWasCarriageReturn = true
        } else if byte == 0x0A {
            if !previousWasCarriageReturn { count += 1 }
            previousWasCarriageReturn = false
        } else {
            previousWasCarriageReturn = false
        }
    }
    return count
}

private final class DelayedCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingChecks: Int

    init(after checks: Int) { remainingChecks = checks }

    func callAsFunction() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remainingChecks > 0 else { return true }
        remainingChecks -= 1
        return false
    }
}

@Test func unchangedAndUnicodeLinesRetainExactReferences() throws {
    let diff = try AlignedLineDiff.build(left: "한글🙂\nend", right: "한글🙂\nend")

    #expect(lineNumbers(diff.rows) == [RowIdentity(1, 1, .unchanged), RowIdentity(2, 2, .unchanged)])
    #expect(diff.rows[0].left?.utf8Range == 0..<10)
    #expect(diff.rows[0].right?.utf8Range == 0..<10)
    #expect(!diff.usedFallback)
}

@Test func insertionDeletionAndReplacementProduceEqualLengthAlignedRows() throws {
    let insertion = try AlignedLineDiff.build(left: "a\nc", right: "a\nb\nc")
    #expect(lineNumbers(insertion.rows) == [
        RowIdentity(1, 1, .unchanged), RowIdentity(nil, 2, .inserted), RowIdentity(2, 3, .unchanged),
    ])

    let deletion = try AlignedLineDiff.build(left: "a\nb\nc", right: "a\nc")
    #expect(lineNumbers(deletion.rows) == [
        RowIdentity(1, 1, .unchanged), RowIdentity(2, nil, .deleted), RowIdentity(3, 2, .unchanged),
    ])

    let replacement = try AlignedLineDiff.build(left: "a\nold\nc", right: "a\nnew\nc")
    #expect(lineNumbers(replacement.rows) == [
        RowIdentity(1, 1, .unchanged), RowIdentity(2, 2, .replaced), RowIdentity(3, 3, .unchanged),
    ])
}

@Test func duplicateLinesUseTheShortestStableAlignment() throws {
    let diff = try AlignedLineDiff.build(left: "same\nx\nsame", right: "same\nsame")

    #expect(lineNumbers(diff.rows) == [
        RowIdentity(1, 1, .unchanged), RowIdentity(2, nil, .deleted), RowIdentity(3, 2, .unchanged),
    ])
}

@Test func emptyDocumentsAndTrailingNewlinesRemainObservable() throws {
    let empty = try AlignedLineDiff.build(left: "", right: "")
    #expect(lineNumbers(empty.rows) == [RowIdentity(1, 1, .unchanged)])
    #expect(empty.rows[0].left?.utf8Range == 0..<0)

    let trailing = try AlignedLineDiff.build(left: "a", right: "a\n")
    #expect(lineNumbers(trailing.rows) == [RowIdentity(1, 1, .unchanged), RowIdentity(nil, 2, .inserted)])
    #expect(trailing.rows[1].right?.utf8Range == 2..<2)
}

@Test func crlfIsOneLineBreakAndItsTerminatorIsExcludedFromRanges() throws {
    let diff = try AlignedLineDiff.build(left: "a\r\n", right: "a\n")

    #expect(lineNumbers(diff.rows) == [
        RowIdentity(1, 1, .unchanged), RowIdentity(2, 2, .unchanged),
    ])
    #expect(diff.rows[0].left?.utf8Range == 0..<1)
    #expect(diff.rows[0].right?.utf8Range == 0..<1)
    #expect(diff.rows[1].left?.utf8Range == 3..<3)
}

@Test func standaloneCRAndMixedTerminatorsCreateExactLogicalLineRanges() throws {
    let text = "a\r\nb\rc\nd"
    let diff = try AlignedLineDiff.build(left: text, right: text)

    #expect(lineNumbers(diff.rows) == [
        RowIdentity(1, 1, .unchanged), RowIdentity(2, 2, .unchanged),
        RowIdentity(3, 3, .unchanged), RowIdentity(4, 4, .unchanged),
    ])
    #expect(diff.rows.map { $0.left?.utf8Range } == [0..<1, 3..<4, 5..<6, 7..<8])
}

@Test func standaloneCRTrailingBreakProducesAnEmptyFinalLine() throws {
    let diff = try AlignedLineDiff.build(left: "a\r", right: "a\r")

    #expect(lineNumbers(diff.rows) == [
        RowIdentity(1, 1, .unchanged), RowIdentity(2, 2, .unchanged),
    ])
    #expect(diff.rows.map { $0.left?.utf8Range } == [0..<1, 2..<2])
}

@Test func lineLimitRejectsNewlineDenseInputBeforeDiffing() {
    let limits = OpenDocumentComparison.Limits(maximumLinesPerSide: 3)

    #expect(throws: OpenDocumentComparison.Error.tooManyLines(side: .left, lineCount: 4, maximum: 3)) {
        try AlignedLineDiff.build(left: "\n\n\n", right: "", limits: limits)
    }
}

@Test func lineLimitCountsMixedTerminatorsWithoutDoubleCountingCRLF() {
    let limits = OpenDocumentComparison.Limits(maximumLinesPerSide: 4)

    #expect(throws: OpenDocumentComparison.Error.tooManyLines(side: .left, lineCount: 5, maximum: 4)) {
        try AlignedLineDiff.build(left: "a\r\nb\rc\nd\r", right: "", limits: limits)
    }
}

@Test func byteLimitIsEnforcedWhenTheAlignerIsReusedDirectly() {
    let limits = OpenDocumentComparison.Limits(maximumUTF8BytesPerSide: 4)

    #expect(throws: OpenDocumentComparison.Error.inputTooLarge(side: .left, byteCount: 5, maximum: 4)) {
        try AlignedLineDiff.build(left: "🙂a", right: "ok", limits: limits)
    }
    #expect(throws: OpenDocumentComparison.Error.inputTooLarge(side: .right, byteCount: 5, maximum: 4)) {
        try AlignedLineDiff.build(left: "okay", right: "🙂a", limits: limits)
    }
}

@Test func exhaustedMyersWorkFallsBackToOneReplacedMiddle() throws {
    let limits = OpenDocumentComparison.Limits(maximumDiffSteps: 1, maximumAlignedRows: 10)
    let diff = try AlignedLineDiff.build(left: "a\nb\nc", right: "x\ny\nz", limits: limits)

    #expect(lineNumbers(diff.rows) == [
        RowIdentity(1, 1, .replaced), RowIdentity(2, 2, .replaced), RowIdentity(3, 3, .replaced),
    ])
    #expect(diff.usedFallback)
}

@Test func fallbackRetainsCommonPrefixAndSuffix() throws {
    let limits = OpenDocumentComparison.Limits(maximumDiffSteps: 0, maximumAlignedRows: 10)
    let diff = try AlignedLineDiff.build(left: "head\na\nb\ntail", right: "head\nx\ny\ntail", limits: limits)

    #expect(lineNumbers(diff.rows) == [
        RowIdentity(1, 1, .unchanged),
        RowIdentity(2, 2, .replaced),
        RowIdentity(3, 3, .replaced),
        RowIdentity(4, 4, .unchanged),
    ])
    #expect(diff.usedFallback)
}

@Test func rowCeilingUsesFallbackThenThrowsWhenFallbackCannotFit() {
    let limits = OpenDocumentComparison.Limits(maximumDiffSteps: 0, maximumAlignedRows: 2)

    #expect(throws: OpenDocumentComparison.Error.complexityExceeded(maximumRows: 2)) {
        try AlignedLineDiff.build(left: "a\nb\nc", right: "x\ny\nz", limits: limits)
    }
}

@Test func exactAlignmentOverTheRowCeilingFallsBackWhenTheMiddleCanFit() throws {
    let limits = OpenDocumentComparison.Limits(maximumDiffSteps: 100, maximumAlignedRows: 2)
    let diff = try AlignedLineDiff.build(left: "a\nb", right: "b\na", limits: limits)

    #expect(lineNumbers(diff.rows) == [
        RowIdentity(1, 1, .replaced), RowIdentity(2, 2, .replaced),
    ])
    #expect(diff.usedFallback)
}

@Test func cancellationStopsPrefixScanAndMyersWork() {
    #expect(throws: OpenDocumentComparison.Error.cancelled) {
        try AlignedLineDiff.build(left: "a\nb", right: "a\nc", isCancelled: { true })
    }
}

@Test func delayedCancellationInterruptsALongSingleLineBeforeTheOtherSideValidation() {
    let cancellation = DelayedCancellation(after: 1)
    let limits = OpenDocumentComparison.Limits(maximumUTF8BytesPerSide: 5_000)

    #expect(throws: OpenDocumentComparison.Error.cancelled) {
        try AlignedLineDiff.build(
            left: String(repeating: "a", count: 5_000),
            right: String(repeating: "b", count: 5_001),
            limits: limits,
            isCancelled: cancellation.callAsFunction
        )
    }
}

@Test func delayedCancellationIsObservedAfterMyersForwardWork() {
    let cancellation = DelayedCancellation(after: 10)

    #expect(throws: OpenDocumentComparison.Error.cancelled) {
        try AlignedLineDiff.build(
            left: "a\nb",
            right: "b\na",
            isCancelled: cancellation.callAsFunction
        )
    }
}

@Test func delayedCancellationInterruptsLargeFallbackMaterialization() {
    let cancellation = DelayedCancellation(after: 8)
    let left = Array(repeating: "a", count: 1_500).joined(separator: "\n")
    let right = Array(repeating: "b", count: 1_500).joined(separator: "\n")
    let limits = OpenDocumentComparison.Limits(maximumDiffSteps: 0)

    #expect(throws: OpenDocumentComparison.Error.cancelled) {
        try AlignedLineDiff.build(
            left: left,
            right: right,
            limits: limits,
            isCancelled: cancellation.callAsFunction
        )
    }
}

@Test func smallDocumentMatrixKeepsEverySourceLineInOrder() throws {
    let documents = [
        "", "a", "b", "a\n", "a\r", "a\r\n", "a\nb", "a\rb", "b\na", "a\na",
        "a\nb\na", "b\na\nb", "🙂\na",
    ]

    for left in documents {
        for right in documents {
            let diff = try AlignedLineDiff.build(left: left, right: right)
            let leftCount = logicalLineCount(left)
            let rightCount = logicalLineCount(right)
            #expect(diff.rows.compactMap { $0.left?.number } == Array(1...leftCount))
            #expect(diff.rows.compactMap { $0.right?.number } == Array(1...rightCount))
            for row in diff.rows {
                switch row.kind {
                case .unchanged:
                    let leftReference = try #require(row.left)
                    let rightReference = try #require(row.right)
                    let leftBytes = Array(left.utf8)[leftReference.utf8Range]
                    let rightBytes = Array(right.utf8)[rightReference.utf8Range]
                    #expect(leftBytes.elementsEqual(rightBytes))
                case .inserted:
                    #expect(row.left == nil && row.right != nil)
                case .deleted:
                    #expect(row.left != nil && row.right == nil)
                case .replaced:
                    #expect(row.left != nil && row.right != nil)
                }
            }
        }
    }
}
