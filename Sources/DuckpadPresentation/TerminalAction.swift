import Foundation

/// Window/session actions requested by an embedded terminal engine.
public enum TerminalAction: Equatable, Sendable {
    case newTab, newWindow, closeSurface, closeTab, closeWindow, closeAllWindows
    case selectTab(Int), split(TerminalDirection), focusSplit(TerminalDirection)
    case resizeSplit(TerminalDirection, Int), equalizeSplits, toggleSplitZoom
    case undo, redo, commandPalette
}

public enum TerminalDirection: Equatable, Sendable {
    case left, right, up, down, previous, next
}
