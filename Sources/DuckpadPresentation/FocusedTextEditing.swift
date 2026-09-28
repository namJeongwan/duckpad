import AppKit
import DuckpadApplication

/// Native text controls own editing commands while their field editor has focus.
/// Never fall through to the document when a control cannot perform a command.
@MainActor
struct FocusedTextEditing {
    let textView: NSTextView

    func canPerform(_ command: EditorCommand) -> Bool {
        switch command {
        case .undo: return textView.isEditable && textView.undoManager?.canUndo == true
        case .redo: return textView.isEditable && textView.undoManager?.canRedo == true
        default:
            guard let action = action(for: command) else { return false }
            return textView.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
        }
    }

    func perform(_ command: EditorCommand) {
        guard canPerform(command) else { return }
        switch command {
        case .undo: textView.undoManager?.undo()
        case .redo: textView.undoManager?.redo()
        default:
            guard let action = action(for: command) else { return }
            _ = textView.tryToPerform(action, with: nil)
        }
    }

    private func action(for command: EditorCommand) -> Selector? {
        switch command {
        case .cut: #selector(NSText.cut(_:))
        case .copy: #selector(NSText.copy(_:))
        case .paste: #selector(NSText.paste(_:))
        case .delete: #selector(NSText.delete(_:))
        case .selectAll: #selector(NSText.selectAll(_:))
        default: nil
        }
    }
}
