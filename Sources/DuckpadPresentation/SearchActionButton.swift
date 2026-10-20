import AppKit

@MainActor
final class SearchActionButton: NSButton {
    var isPrimary = false { didSet { refresh() } }
    override var isEnabled: Bool { didSet { refresh() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false; imagePosition = .noImage; font = .systemFont(ofSize: 13)
        setButtonType(.momentaryPushIn); wantsLayer = true
        layer?.cornerRadius = 5; layer?.borderWidth = 1
        setContentCompressionResistancePriority(.required, for: .horizontal)
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { .init(width: super.intrinsicContentSize.width + (controlSize == .small ? 16 : 24), height: controlSize == .small ? 24 : 32) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    private func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let foreground: NSColor = isEnabled ? (isPrimary ? .white : .labelColor) : .disabledControlTextColor
            attributedTitle = NSAttributedString(string: title, attributes: [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: foreground])
            layer?.backgroundColor = (isPrimary && isEnabled ? NSColor.controlAccentColor : NSColor.clear).cgColor
            layer?.borderColor = (isPrimary && isEnabled ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        }
    }
    override var title: String { didSet { refresh() } }
}
