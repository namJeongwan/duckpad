import DuckpadLocalization
import AppKit

/// Display names belong to the UI; only stable PostScript names reach settings.
@MainActor
final class EditorFontComboBox: NSComboBox, NSComboBoxDataSource, NSComboBoxDelegate {
    struct Entry {
        let family: String
        let font: NSFont

        var previewFont: NSFont {
            // Symbol fonts map letters to pictograms; their names must remain readable.
            guard font.coveredCharacterSet.isSuperset(of: CharacterSet(charactersIn: family)) else {
                return .systemFont(ofSize: 14)
            }
            // Decorative fonts can have much taller ascenders/descenders than normal text.
            let height = font.ascender - font.descender + max(0, font.leading)
            let size = font.pointSize * min(1, 22 / max(1, height))
            return NSFont(descriptor: font.fontDescriptor, size: size) ?? font
        }
    }

    private(set) var installedFonts: [Entry] = []
    private(set) var visibleFonts: [Entry] = []
    private var selectedFontName = "Menlo"
    private var rendering = false
    var onFontSelected: ((String) -> Void)?

    init() {
        super.init(frame: .zero)
        usesDataSource = true
        dataSource = self
        delegate = self
        isEditable = true
        completes = true
        hasVerticalScroller = true
        numberOfVisibleItems = 10
        itemHeight = 28
        target = self
        action = #selector(commitTypedFont(_:))
        refreshLocalization()
        setAccessibilityIdentifier("duckpad.settings.editor-font")
        reloadInstalledFonts()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        placeholderString = catalog.text("Search fonts")
        setAccessibilityLabel(catalog.text("Editor font"))
    }

    func reloadInstalledFonts() {
        installedFonts = NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap { family in
                guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 14),
                      !font.fontName.hasPrefix(".") else { return nil }
                return Entry(family: family, font: font)
            }
        display(fontName: selectedFontName)
    }

    func display(fontName: String) {
        rendering = true
        defer { rendering = false }
        selectedFontName = fontName
        visibleFonts = installedFonts
        reloadData()
        let canonical = NSFont(name: fontName, size: 14)?.fontName ?? fontName
        if let index = visibleFonts.firstIndex(where: { $0.font.fontName == canonical }) {
            selectItem(at: index)
            stringValue = visibleFonts[index].family
        } else {
            if indexOfSelectedItem >= 0 { deselectItem(at: indexOfSelectedItem) }
            stringValue = fontName
        }
    }

    func numberOfItems(in comboBox: NSComboBox) -> Int { visibleFonts.count }

    func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        guard visibleFonts.indices.contains(index) else { return nil }
        let entry = visibleFonts[index]
        return NSAttributedString(string: entry.family, attributes: [.font: entry.previewFont])
    }

    func comboBox(_ comboBox: NSComboBox, indexOfItemWithStringValue string: String) -> Int {
        visibleFonts.firstIndex { matches($0, string) } ?? NSNotFound
    }

    func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
        guard !string.isEmpty else { return nil }
        return visibleFonts.first { $0.family.range(of: string, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil }?.family
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !rendering else { return }
        // NSComboBox clears its field editor while deselecting/reloading items. Preserve
        // the actual input and caret, including the selected autocomplete suffix.
        let editor = currentEditor() as? NSTextView
        guard editor?.hasMarkedText() != true else { return }
        let input = editor?.string ?? stringValue
        let selection = editor?.selectedRange()
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        rendering = true
        defer { rendering = false }
        if indexOfSelectedItem >= 0 { deselectItem(at: indexOfSelectedItem) }
        visibleFonts = query.isEmpty ? installedFonts : installedFonts.filter {
            $0.family.localizedStandardContains(query) || $0.font.fontName.localizedStandardContains(query)
        }
        reloadData()
        stringValue = input
        if let editor, let selection {
            editor.string = input
            editor.setSelectedRange(selection)
        }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard !rendering, !((currentEditor() as? NSTextView)?.hasMarkedText() ?? false),
              visibleFonts.indices.contains(indexOfSelectedItem) else { return }
        choose(visibleFonts[indexOfSelectedItem])
    }

    func controlTextDidEndEditing(_ notification: Notification) { commitTypedFont(nil) }

    @objc private func commitTypedFont(_ sender: Any?) {
        guard !rendering, !((currentEditor() as? NSTextView)?.hasMarkedText() ?? false) else { return }
        let query = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let entry = installedFonts.first(where: { matches($0, query) }) {
            choose(entry)
        } else {
            display(fontName: selectedFontName)
        }
    }

    private func matches(_ entry: Entry, _ text: String) -> Bool {
        entry.family.localizedCaseInsensitiveCompare(text) == .orderedSame ||
            entry.font.fontName.caseInsensitiveCompare(text) == .orderedSame
    }

    private func choose(_ entry: Entry) {
        let previous = NSFont(name: selectedFontName, size: 14)?.fontName ?? selectedFontName
        selectedFontName = entry.font.fontName
        stringValue = entry.family
        if previous != entry.font.fontName { onFontSelected?(entry.font.fontName) }
    }
}
