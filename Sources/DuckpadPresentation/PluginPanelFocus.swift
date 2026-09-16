import AppKit

@MainActor enum PluginPanelFocus {
    static func ownsKeyboardFocus(_ panel: NSView, in split: NSSplitView) -> Bool {
        guard panel.superview === split, !panel.isHiddenOrHasHiddenAncestor,
              let window = split.window, panel.window === window,
              window.attachedSheet == nil, let responder = window.firstResponder else { return false }
        if let view = responder as? NSView, view === panel || view.isDescendant(of: panel) { return true }
        // Search fields can use a window-owned field editor outside the panel.
        if let editor = responder as? NSTextView, editor.isFieldEditor,
           let owner = editor.delegate as? NSView {
            return owner === panel || owner.isDescendant(of: panel)
        }
        return false
    }
}
