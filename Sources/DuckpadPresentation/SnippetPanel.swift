import AppKit
import DuckpadDomain
import DuckpadLocalization

@MainActor
final class SnippetPanel: NSObject {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 510),
                                styleMask: [.titled], backing: .buffered, defer: false)
    private let picker = NSPopUpButton()
    private let name = NSTextField(string: "")
    private let language = NSPopUpButton()
    private let body = NSTextView()
    private let error = NSTextField(wrappingLabelWithString: "")
    private var snippets: [TextSnippet] = []
    private var selectedID: UUID?
    private var buttons: [NSButton] = []
    private var activeLanguage = "text"
    private var busy = false
    private var onSave: (([TextSnippet]) async -> Bool)?
    private var onInsert: ((String) -> Bool)?

    override init() {
        super.init()
        panel.title = L10n.text("Snippets")
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -20),
        ])
        picker.target = self; picker.action = #selector(selectSnippet)
        picker.setAccessibilityLabel(L10n.text("Snippets"))
        stack.addArrangedSubview(picker)
        let row = NSStackView(views: [NSTextField(labelWithString: L10n.text("Snippet name")), name])
        row.spacing = 12; stack.addArrangedSubview(row)
        name.setAccessibilityLabel(L10n.text("Snippet name"))
        let languageRow = NSStackView(views: [NSTextField(labelWithString: L10n.text("Language")), language])
        languageRow.spacing = 12; stack.addArrangedSubview(languageRow)
        language.setAccessibilityLabel(L10n.text("Language"))
        let hint = NSTextField(wrappingLabelWithString: L10n.text("Use ${1:name}, $2 and $0 for fields. Tab moves forward, Shift+Tab moves back, and Esc finishes. Repeated numbers edit together."))
        hint.textColor = .secondaryLabelColor; stack.addArrangedSubview(hint)
        body.isRichText = false; body.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        body.isAutomaticQuoteSubstitutionEnabled = false; body.isAutomaticDashSubstitutionEnabled = false
        body.isAutomaticTextReplacementEnabled = false; body.isAutomaticSpellingCorrectionEnabled = false
        body.autoresizingMask = [.width]; body.isVerticallyResizable = true
        body.textContainer?.widthTracksTextView = true
        body.setAccessibilityLabel(L10n.text("Snippet text"))
        let scroll = NSScrollView(); scroll.documentView = body; scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        stack.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        error.textColor = .systemRed; stack.addArrangedSubview(error)
        let new = button("New snippet", #selector(newSnippet))
        let delete = button("Delete", #selector(deleteSnippet))
        let save = button("Save", #selector(saveSnippet))
        let close = button("Close", #selector(closePanel)); close.keyEquivalent = "\u{1b}"
        let insert = button("Insert snippet", #selector(insertSnippet)); insert.keyEquivalent = "\r"
        let actions = NSStackView(views: [new, delete, save, NSView(), close, insert]); actions.spacing = 8
        stack.addArrangedSubview(actions)
        for view in [picker, row, languageRow, hint, scroll, error, actions] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    func present(in window: NSWindow, snippets: [TextSnippet], activeLanguage: String, onDismiss: @escaping () -> Void, languages: [LanguageDefinition],
                 onSave: @escaping ([TextSnippet]) async -> Bool, onInsert: @escaping (String) -> Bool) {
        self.activeLanguage = activeLanguage
        self.snippets = snippets; self.onSave = onSave; self.onInsert = onInsert
        language.removeAllItems(); language.addItem(withTitle: L10n.text("All languages"))
        language.lastItem?.representedObject = ""
        for definition in languages {
            language.addItem(withTitle: definition.displayName); language.lastItem?.representedObject = definition.id.rawValue
        }
        reloadPicker(); loadSelection()
        window.beginSheet(panel) { _ in onDismiss() }
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let result = NSButton(title: L10n.text(title), target: self, action: action)
        buttons.append(result); return result
    }

    private func reloadPicker() {
        picker.removeAllItems(); picker.addItem(withTitle: L10n.text("New snippet"))
        for snippet in snippets { picker.addItem(withTitle: snippet.name); picker.lastItem?.representedObject = snippet.id }
        if let selectedID, let item = picker.itemArray.first(where: { $0.representedObject as? UUID == selectedID }) { picker.select(item) }
    }

    @objc private func selectSnippet() { loadSelection() }
    private func loadSelection() {
        selectedID = picker.selectedItem?.representedObject as? UUID
        let snippet = snippets.first { $0.id == selectedID }
        name.stringValue = snippet?.name ?? ""; body.string = snippet?.body ?? ""
        language.select(language.itemArray.first { ($0.representedObject as? String) == (snippet?.language ?? "") } ?? language.item(at: 0))
        error.stringValue = ""
    }
    @objc private func newSnippet() { picker.selectItem(at: 0); loadSelection(); panel.makeFirstResponder(name) }
    @objc private func closePanel() {
        guard !busy else { return }
        panel.sheetParent?.endSheet(panel); panel.orderOut(nil)
    }
    @objc private func insertSnippet() {
        guard !busy, !body.string.isEmpty else { return }
        let scope = language.selectedItem?.representedObject as? String ?? ""
        guard (scope.isEmpty || scope == activeLanguage), onInsert?(body.string) == true else { error.stringValue = L10n.text("Could not insert snippet. Select an editable document and try again."); return }
        closePanel()
    }
    @objc private func saveSnippet() {
        let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !title.isEmpty, !body.string.isEmpty, title.utf8.count <= 256,
              body.string.utf8.count <= 65_536, snippets.count < 200 || selectedID != nil else {
            error.stringValue = L10n.text("Enter a name and snippet text. Limits: 200 snippets, 256 bytes per name and 64 KB per snippet."); return
        }
        let entry = TextSnippet(id: selectedID ?? UUID(), name: title,
                                language: language.selectedItem?.representedObject as? String ?? "", body: body.string)
        var next = snippets
        if let index = next.firstIndex(where: { $0.id == entry.id }) { next[index] = entry } else { next.append(entry) }
        persist(next, selection: entry.id)
    }
    @objc private func deleteSnippet() {
        guard !busy, let selectedID else { return }
        persist(snippets.filter { $0.id != selectedID }, selection: nil)
    }
    private func persist(_ next: [TextSnippet], selection: UUID?) {
        busy = true; buttons.forEach { $0.isEnabled = false }; picker.isEnabled = false
        name.isEnabled = false; language.isEnabled = false; body.isEditable = false
        Task { @MainActor in
            let saved = await onSave?(next) == true
            busy = false; buttons.forEach { $0.isEnabled = true }; picker.isEnabled = true
            name.isEnabled = true; language.isEnabled = true; body.isEditable = true
            if saved { snippets = next; selectedID = selection; reloadPicker(); loadSelection() }
            else { error.stringValue = L10n.text("Could not save snippets. Try again.") }
        }
    }
}
