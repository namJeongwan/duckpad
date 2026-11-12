import AppKit

@MainActor final class DiagramPreviewWindow: NSWindowController {
    let preview: DiagramPreview
    private let strings: DiagramStrings
    init(strings: DiagramStrings) {
        self.strings = strings
        preview = DiagramPreview(strings: strings)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = strings.format("%@ preview", strings.name); window.contentView = preview
        window.minSize = NSSize(width: 500, height: 350)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }
    required init?(coder: NSCoder) { nil }
    func refreshLocalization() {
        window?.title = strings.format("%@ preview", strings.name)
        preview.refreshLocalization()
    }
    func display(_ image: NSImage) { preview.display(image); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
}
