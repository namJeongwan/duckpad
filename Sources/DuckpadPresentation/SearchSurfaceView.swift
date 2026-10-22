import AppKit

/// Shared opaque search surfaces make the result, preview and actions distinct.
@MainActor
final class SearchSurfaceView: NSView {
    enum Surface { case panel, editor, chrome }
    private let surface: Surface
    var isInteractionHovered = false { didSet { if oldValue != isInteractionHovered { refresh() } } }
    var isInteractionFocused = false { didSet { if oldValue != isInteractionFocused { refresh() } } }
    init(_ surface: Surface) { self.surface = surface; super.init(frame: .zero); wantsLayer = true; refresh() }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    private func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor = switch surface { case .panel: WorkspaceColors.panel; case .editor: WorkspaceColors.editor; case .chrome: WorkspaceColors.chrome }
            layer?.backgroundColor = (isInteractionHovered ? color.blended(withFraction: 0.045, of: .labelColor) ?? color : color).cgColor
            layer?.borderWidth = isInteractionHovered || isInteractionFocused ? 1 : 0
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(isInteractionFocused ? 0.28 : 0.16).cgColor
        }
    }
}
