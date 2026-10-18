import AppKit
import DuckpadLocalization

@MainActor
public final class UsageStatisticsLogWindowController: NSWindowController {
    private let textView = NSTextView()

    public init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.frame = scroll.bounds
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        window.contentView?.addSubview(scroll)
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    public func show(log: String, configured: Bool) {
        window?.title = L10n.text("Statistics transmission log")
        textView.setAccessibilityLabel(L10n.text("Statistics transmission log"))
        textView.string = !configured ? L10n.text("Statistics transmission is unavailable in this build.")
            : log.isEmpty ? L10n.text("No transmission attempts in this session. Statistics are sent in batches while sharing is enabled. This view shows the five most recent batches; reopen it to refresh.") : log
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
