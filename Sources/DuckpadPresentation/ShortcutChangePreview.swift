import AppKit
import DuckpadLocalization

/// A reversible, single-line comparison. No keymap mutation occurs until Enter.
@MainActor
final class ShortcutChangePreview: NSTableCellView {
    private let before = NSTextField(labelWithString: "")
    private let arrow = NSTextField(labelWithString: "→")
    private let after = NSTextField(labelWithString: "…")
    private let registry: ShortcutRegistry
    private let entry: ShortcutRegistry.Entry
    private(set) var feedback = L10n.text("Press a shortcut · Enter to apply · Esc to cancel")
    private(set) var hasError = false
    private(set) var canApply = false
    private(set) var candidate: String?
    var onComplete: ((String?) -> Void)?
    var onFeedback: (() -> Void)?
    var comparison: String { before.stringValue + " → " + after.stringValue }

    init(entry: ShortcutRegistry.Entry, registry: ShortcutRegistry) {
        self.entry = entry; self.registry = registry
        super.init(frame: .zero)
        before.stringValue = entry.displayShortcut.isEmpty ? "—" : entry.displayShortcut
        before.font = .systemFont(ofSize: 12)
        after.font = .systemFont(ofSize: 12, weight: .semibold)
        for field in [before, arrow, after] { field.lineBreakMode = .byTruncatingTail }
        let stack = NSStackView(views: [before, arrow, after]); stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(L10n.text("Shortcut"))
        updateDisplay()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { updateDisplay() } }
    private func updateDisplay() {
        let selected = backgroundStyle == .emphasized
        before.textColor = selected ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.65) : .secondaryLabelColor
        arrow.textColor = before.textColor
        after.textColor = selected ? .alternateSelectedControlTextColor : (hasError ? .systemRed : .controlAccentColor)
        setAccessibilityValue(comparison)
        toolTip = feedback
    }
    func capture(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53 && flags.isEmpty { cancel(); return }
        if event.keyCode == 36 && flags.isEmpty {
            if canApply, let candidate { finish(candidate) }
            return
        }
        candidate = ShortcutRecorder.declaration(for: event)
        canApply = false
        if let candidate, let shortcut = MenuShortcut(candidate) {
            after.stringValue = MenuShortcut.display(key: shortcut.keyEquivalent, modifiers: shortcut.modifiers)
            if let conflict = registry.conflict(for: candidate, excluding: entry.id) {
                feedback = L10n.text("Shortcut already used by %1$@", L10n.argument(conflict.path.isEmpty ? conflict.title : conflict.path + " › " + conflict.title))
                hasError = true
            } else {
                feedback = L10n.text("Enter to apply · Esc to cancel")
                hasError = false; canApply = true
            }
        } else {
            after.stringValue = "…"
            feedback = L10n.text("Use a supported shortcut with Command or Control.")
            hasError = true
        }
        updateDisplay(); onFeedback?()
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: feedback, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    func cancel() { finish(nil) }
    private func finish(_ declaration: String?) {
        let completion = onComplete; onComplete = nil
        completion?(declaration)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}
