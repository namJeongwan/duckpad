import DuckpadPresentation
import Testing

@Test func lineAndColumnInputIsBoundedAndDefaultsColumn() {
    #expect(EditorNavigationInput.lineAndColumn(" 12 ", maximumLine: 20)?.line == 12)
    #expect(EditorNavigationInput.lineAndColumn("12", maximumLine: 20)?.column == 1)
    #expect(EditorNavigationInput.lineAndColumn("12:7", maximumLine: 20)?.column == 7)
    #expect(EditorNavigationInput.lineAndColumn("12, 7", maximumLine: 20)?.column == 7)
    #expect(EditorNavigationInput.lineAndColumn("0", maximumLine: 20) == nil)
    #expect(EditorNavigationInput.lineAndColumn("21", maximumLine: 20) == nil)
    #expect(EditorNavigationInput.lineAndColumn("12:0", maximumLine: 20) == nil)
    #expect(EditorNavigationInput.lineAndColumn("12:", maximumLine: 20) == nil)
    #expect(EditorNavigationInput.lineAndColumn("12:2:1", maximumLine: 20) == nil)
}

@Test func UTF8OffsetInputAcceptsBothDocumentBoundaries() {
    #expect(EditorNavigationInput.utf8Offset(" 0 ", maximumOffset: 12) == 0)
    #expect(EditorNavigationInput.utf8Offset("12", maximumOffset: 12) == 12)
    #expect(EditorNavigationInput.utf8Offset("-1", maximumOffset: 12) == nil)
    #expect(EditorNavigationInput.utf8Offset("13", maximumOffset: 12) == nil)
    #expect(EditorNavigationInput.utf8Offset("1.5", maximumOffset: 12) == nil)
}
