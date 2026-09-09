public struct EditorStatusSnapshot: Equatable, Sendable {
    public let length: Int
    public let lines: Int
    public let line: Int
    public let column: Int
    public let selectedCharacters: Int
    public let selectedLines: Int
    public let isOvertype: Bool

    public init(length: Int, lines: Int, line: Int, column: Int,
                selectedCharacters: Int, selectedLines: Int, isOvertype: Bool) {
        self.length = length
        self.lines = lines
        self.line = line
        self.column = column
        self.selectedCharacters = selectedCharacters
        self.selectedLines = selectedLines
        self.isOvertype = isOvertype
    }
}

@MainActor
public protocol EditorStatusReportingPort: EditorPort {
    var editorStatus: EditorStatusSnapshot? { get }
    var onEditorStatusChange: (() -> Void)? { get set }
    func toggleOvertype()
}
