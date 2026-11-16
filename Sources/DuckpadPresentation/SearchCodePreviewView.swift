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
        let sameText = textView.string.utf8.elementsEqual(content.text.utf8)
        let preserveView = sameText && self.content?.firstLine == content.firstLine
            && self.content?.matchLine == content.matchLine && self.content?.highlight == content.highlight
        let selection = textView.selectedRanges, origin = scroll.contentView.bounds.origin
        self.content = content
        if !sameText { textView.string = content.text }
        let length = (content.text as NSString).length
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let palette: EditorThemePalette = dark ? .dark : .light
        let offsets = Self.utf16Offsets(content.text)
        func range(_ source: SearchUTF8Range) -> NSRange? {
            guard source.location >= 0, source.length >= 0, source.location < offsets.count,
                  source.length <= offsets.count - 1 - source.location else { return nil }
            let start = offsets[source.location], end = offsets[source.location + source.length]
            guard start >= 0, end >= start else { return nil }
            return .init(location: start, length: end - start)
        }
        textView.textStorage?.beginEditing()
        textView.textStorage?.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: Self.color(palette.colors.foreground)], range: NSRange(location: 0, length: length))
        for span in content.syntax {
            guard let range = range(span.range) else { continue }
            textView.textStorage?.addAttribute(.foregroundColor,
                value: Self.color(dark ? span.darkForeground : span.lightForeground), range: range)
        }
        let highlightRange = range(content.highlight)
        if let range = highlightRange {
            let line = (content.text as NSString).lineRange(for: range)
            textView.textStorage?.addAttribute(.backgroundColor, value: WorkspaceColors.selection.withAlphaComponent(0.35), range: line)
            textView.textStorage?.addAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.6), .foregroundColor: NSColor.black], range: range)
        }
        textView.textStorage?.endEditing()
        if preserveView {
            textView.selectedRanges = selection
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(.init(origin: origin, size: scroll.contentView.bounds.size)).origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        } else if let highlightRange { textView.scrollRangeToVisible(highlightRange) }
        gutter.firstLine = content.firstLine; gutter.needsDisplay = true
    }

    private static func color(_ rgb: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    /// Valid scalar boundaries only; byte offsets inside a UTF-8 scalar remain -1.
    private static func utf16Offsets(_ text: String) -> [Int] {
        var result = Array(repeating: -1, count: text.utf8.count + 1), byte = 0, utf16 = 0
        result[0] = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            byte += value <= 0x7F ? 1 : value <= 0x7FF ? 2 : value <= 0xFFFF ? 3 : 4
            utf16 += value <= 0xFFFF ? 1 : 2
            result[byte] = utf16
        }
        return result
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
