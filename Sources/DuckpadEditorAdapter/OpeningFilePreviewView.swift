import AppKit
import DuckpadScintillaBridge

/// Transient display only: deliberately has no buffer identity or edit callbacks.
@MainActor
final class OpeningFilePreviewView: NSView {
    let editor = DPScintillaEditorView(frame: .zero)

    init(path: String) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: URL(fileURLWithPath: path).lastPathComponent)
        title.lineBreakMode = .byTruncatingMiddle
        title.toolTip = path
        title.translatesAutoresizingMaskIntoConstraints = false
        editor.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        addSubview(editor)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            editor.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            editor.leadingAnchor.constraint(equalTo: leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) { nil }
}
