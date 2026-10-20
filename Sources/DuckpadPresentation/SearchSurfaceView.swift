import AppKit

/// Shared opaque search surfaces make the result, preview and actions distinct.
@MainActor
final class SearchSurfaceView: NSView {
    enum Surface { case panel, editor, chrome }
    private let surface: Surface
    init(_ surface: Surface) { self.surface = surface; super.init(frame: .zero); wantsLayer = true; refresh() }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    private func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor = switch surface { case .panel: WorkspaceColors.panel; case .editor: WorkspaceColors.editor; case .chrome: WorkspaceColors.chrome }
            layer?.backgroundColor = color.cgColor
        }
    }
}
