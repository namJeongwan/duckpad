import AppKit

@MainActor
final class SearchPopupPanel: NSPanel {
    init(size: NSSize, identifier: String) {
        super.init(contentRect: .init(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; isFloatingPanel = true; hidesOnDeactivate = false
        titleVisibility = .hidden; titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(button)?.isHidden = true }
        setAccessibilityIdentifier(identifier)
    }
    required init?(coder: NSCoder) { nil }
}
