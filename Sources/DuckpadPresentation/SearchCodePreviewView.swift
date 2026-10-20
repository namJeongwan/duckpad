import AppKit
import DuckpadApplication
import DuckpadDomain

@MainActor
final class SearchCodePreviewView: NSView {
    let textView = NSTextView()
    private let scroll = NSScrollView()
    private lazy var gutter = SearchPreviewLineRuler(scrollView: scroll, textView: textView)
    private var content: SearchMatchPreview?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.masksToBounds = true
        textView.isEditable = false; textView.isSelectable = true; textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = .init(width: 12, height: 12)
        textView.isHorizontallyResizable = true; textView.isVerticallyResizable = true
        textView.minSize = .zero; textView.maxSize = .init(width: 10_000_000, height: 10_000_000)
        textView.textContainer?.containerSize = .init(width: 10_000_000, height: 10_000_000)
        textView.textContainer?.widthTracksTextView = false
        textView.autoresizingMask = [.height]
        textView.setAccessibilityIdentifier("duckpad.multifile.preview")
        scroll.documentView = textView; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.verticalRulerView = gutter; scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refreshAppearance()
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshAppearance() }
    private func refreshAppearance() {
        textView.backgroundColor = WorkspaceColors.editor
        textView.textColor = .labelColor
        if let content { apply(content) }
        gutter.needsDisplay = true
    }
    func clear() { content = nil; textView.string = ""; gutter.needsDisplay = true }
    func apply(_ content: SearchMatchPreview) {
        self.content = content
        textView.string = content.text
        let length = (content.text as NSString).length
        textView.textStorage?.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor], range: NSRange(location: 0, length: length))
        let bytes = Data(content.text.utf8), highlight = content.highlight
        if highlight.location >= 0, highlight.length >= 0, highlight.upperBound <= bytes.count {
            let location = String(decoding: bytes.prefix(highlight.location), as: UTF8.self).utf16.count
            let count = String(decoding: bytes.subdata(in: highlight.location..<highlight.upperBound), as: UTF8.self).utf16.count
            let range = NSRange(location: location, length: count)
            let line = (content.text as NSString).lineRange(for: range)
            textView.textStorage?.addAttribute(.backgroundColor, value: WorkspaceColors.selection.withAlphaComponent(0.35), range: line)
            textView.textStorage?.addAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.6), .foregroundColor: NSColor.black], range: range)
            textView.scrollRangeToVisible(range)
        }
        gutter.firstLine = content.firstLine; gutter.needsDisplay = true
    }
}

@MainActor
private final class SearchPreviewLineRuler: NSRulerView {
    private weak var text: NSTextView?
    var firstLine = 1
    override var isFlipped: Bool { true }
    init(scrollView: NSScrollView, textView: NSTextView) {
        text = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView; ruleThickness = 48
    }
    required init(coder: NSCoder) { super.init(coder: coder) }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        WorkspaceColors.editor.setFill(); bounds.fill()
        guard let text, let manager = text.layoutManager, let container = text.textContainer else { return }
        manager.ensureLayout(for: container)
        let source = text.string as NSString
        var offset = 0, line = firstLine
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        while offset < source.length {
            let glyph = manager.glyphIndexForCharacter(at: offset)
            let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = fragment.minY + text.textContainerOrigin.y - (scrollView?.contentView.bounds.minY ?? 0)
            if y + fragment.height >= 0, y < bounds.height {
                let label = String(line) as NSString
                label.draw(at: NSPoint(x: ruleThickness - label.size(withAttributes: attributes).width - 10, y: y + 1), withAttributes: attributes)
            }
            offset = NSMaxRange(source.lineRange(for: NSRange(location: offset, length: 0))); line += 1
        }
    }
}
