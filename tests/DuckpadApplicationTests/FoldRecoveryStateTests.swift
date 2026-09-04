import DuckpadApplication
import Foundation
import Testing

@Test func foldRecoveryStateCanonicalizesValidLines() {
    #expect(FoldRecoveryState(contractedHeaderLines: [4, 1, 4, -1, 2]).contractedHeaderLines == [1, 2, 4])
}

@Test func initializerTruncatesAtExactlyTenThousand() {
    #expect(
        FoldRecoveryState(contractedHeaderLines: Array(0...FoldRecoveryState.maximumContractedHeaderCount))
            .contractedHeaderLines == Array(0..<10_000)
    )
}

@Test func decoderAcceptsExactlyTenThousand() throws {
    let data = try JSONEncoder().encode(Array(0..<10_000))
    let decoded = try JSONDecoder().decode(FoldRecoveryState.self, from: data)
    #expect(decoded.contractedHeaderLines == Array(0..<10_000))
}

@Test func decoderCanonicalizesUnsortedDuplicates() throws {
    let decoded = try JSONDecoder().decode(FoldRecoveryState.self, from: Data("[4,1,4,2]".utf8))
    #expect(decoded.contractedHeaderLines == [1, 2, 4])
}

@Test func legacyEditorViewStateDefaultsBothPanesToNoFolds() throws {
    let data = Data(#"{"anchorUTF8":0,"caretUTF8":0,"firstVisibleLine":0,"horizontalScrollOffset":0,"wordWrapEnabled":true,"splitOrientation":"sideBySide","secondaryViewState":{"anchorUTF8":0,"caretUTF8":0,"firstVisibleLine":0,"horizontalScrollOffset":0,"wordWrapEnabled":true}}"#.utf8)
    let decoded = try JSONDecoder().decode(EditorViewState.self, from: data)
    #expect(decoded.foldState == FoldRecoveryState())
    #expect(decoded.secondaryViewState?.foldState == FoldRecoveryState())
}

@Test func viewStateArchivePreservesFoldStateForBothPanes() throws {
    let state = EditorViewState(
        foldState: FoldRecoveryState(contractedHeaderLines: [3]),
        splitOrientation: .sideBySide,
        secondaryViewState: SecondaryEditorViewState(
            foldState: FoldRecoveryState(contractedHeaderLines: [7])
        )
    )
    let decoded = try JSONDecoder().decode(EditorViewState.self, from: JSONEncoder().encode(state))
    #expect(decoded.foldState.contractedHeaderLines == [3])
    #expect(decoded.secondaryViewState?.foldState.contractedHeaderLines == [7])
}

@Test func foldRecoveryArchiveRejectsNegativeAndOversizedArrays() {
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(FoldRecoveryState.self, from: Data("[-1]".utf8))
    }
    let oversized = try! JSONEncoder().encode(
        Array(0...FoldRecoveryState.maximumContractedHeaderCount)
    )
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(FoldRecoveryState.self, from: oversized)
    }
}
