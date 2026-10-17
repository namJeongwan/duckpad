import AppKit
import DuckpadApplication

/// The panel owns session views; the engine adapter owns rendering and processes.
@MainActor
open class TerminalSurfaceView: NSView {
    public var onAction: ((TerminalAction) -> Void)?
    public var onFocus: (() -> Void)?
    public var workingDirectory: URL?
    open func handleTerminalKeyEquivalent(_ event: NSEvent) -> Bool { false }
    open func performBinding(_ binding: String) -> Bool { false }
    public var onExit: (() -> Void)?
    open var needsCloseConfirmation: Bool { false }
    open func canPerform(_ command: EditorCommand) -> Bool { false }
    open func perform(_ command: EditorCommand) {}
    open func shutdown() {}
}
