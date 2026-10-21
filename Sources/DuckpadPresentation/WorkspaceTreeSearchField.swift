import AppKit
import DuckpadApplication
import DuckpadLocalization

/// The sidebar shares the search input used by the filename and content popups.
@MainActor
final class WorkspaceTreeSearchField: NSView, NSTextFieldDelegate {
    var onLoad: ((String) async throws -> WorkspaceFileNameIndex)?
    var onResults: ((WorkspaceFileNameIndex?) -> Void)?
    var onCancel: (() -> Void)?
    private let input = SearchInputField(fontSize: 12)
    private let clear = StatusBarButton()
    private let status = NSTextField(labelWithString: "")
    private var statusHeight: NSLayoutConstraint!
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var catalog = L10n.catalog
    private var enabled = true
    var query: String { input.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        input.delegate = self
        input.setAccessibilityIdentifier("duckpad.workspace.query")
        input.heightAnchor.constraint(equalToConstant: SearchInputField.preferredHeight).isActive = true
        clear.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        clear.isBordered = false; clear.target = self; clear.action = #selector(clearPressed)
        clear.widthAnchor.constraint(equalToConstant: 22).isActive = true
        clear.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let row = NSStackView(views: [icon, input, clear])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 6
        status.font = .systemFont(ofSize: 10); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        for view in [row, status] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        statusHeight = status.heightAnchor.constraint(equalToConstant: 0)
        status.isHidden = true
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            row.topAnchor.constraint(equalTo: topAnchor), row.heightAnchor.constraint(equalToConstant: 32),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9), status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            status.topAnchor.constraint(equalTo: row.bottomAnchor), statusHeight,
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        refreshLocalization(catalog: catalog)
    }
    required init?(coder: NSCoder) { nil }
    deinit { task?.cancel() }

    func refreshLocalization(catalog: LocalizationCatalog) {
        self.catalog = catalog
        input.placeholderString = catalog.text("Filter")
        input.setAccessibilityLabel(catalog.text("Search files by name or path"))
        input.toolTip = catalog.text("Search files by name or path")
        clear.toolTip = catalog.text("Clear"); clear.setAccessibilityLabel(catalog.text("Clear"))
    }
    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value; input.isEnabled = value; clear.isEnabled = value
        refresh()
    }
    @discardableResult
    func focus() -> Bool {
        guard enabled, let window, !isHiddenOrHasHiddenAncestor else { return false }
        guard window.makeFirstResponder(input) else { return false }
        input.selectText(nil)
        return true
    }

    func stop() { task?.cancel(); task = nil; generation = UUID() }
    func setQuery(_ text: String) { input.stringValue = text; refresh() }
    func refresh() {
        stop()
        let text = query, token = generation
        clear.isHidden = text.isEmpty
        setStatus("")
        guard !FileNameQuery(text).isEmpty else { onResults?(nil); return }
        onResults?(.init(files: [], isTruncated: false, skippedDirectoryCount: 0))
        guard enabled, let onLoad else { return }
        setStatus(catalog.text("Searching…"))
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                let result = try await onLoad(text)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.onResults?(result)
                self.setStatus(self.catalog.text(result.isTruncated
                    ? "Showing %1$@ files · Index limit reached · Skipped items: %2$@"
                    : "Showing %1$@ files · Skipped items: %2$@", arguments: [String(result.files.count), String(result.skippedDirectoryCount)]))
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.setStatus(self.catalog.text("Search failed: %1$@", arguments: [PresentationErrorText.message(error, catalog: self.catalog)]))
            }
        }
    }
    private func setStatus(_ text: String) {
        status.stringValue = text
        status.toolTip = text.isEmpty ? nil : text
        status.isHidden = text.isEmpty
        statusHeight.constant = text.isEmpty ? 0 : 16
    }
    @objc private func clearPressed() { setQuery(""); window?.makeFirstResponder(input) }
    func controlTextDidChange(_ obj: Notification) { refresh() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if let onCancel { onCancel(); return true }
        guard !query.isEmpty else { return false }
        clearPressed(); return true
    }
}
