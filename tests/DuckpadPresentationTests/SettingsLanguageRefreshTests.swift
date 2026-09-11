import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization
import Testing
@testable import DuckpadPresentation

@Suite(.serialized) @MainActor
struct SettingsLanguageRefreshTests {
    @Test func refreshTranslatesExistingControlsWithoutReplacingState() throws {
        _ = NSApplication.shared
        let controller = DuckpadSettingsWindowController()
        defer { controller.close() }
        controller.configure(settings: AppSettings(appearanceMode: .dark, caretBlinkPeriod: 1000)) { .saved($0) }
        controller.refreshLocalization(catalog: LocalizationCatalog(language: .english))
        controller.selectCategory("Editing")
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        let controls = descendants(content)
        let labels = controls.compactMap { $0 as? NSTextField }.filter { !$0.isEditable && !$0.stringValue.isEmpty }
        let originalLabels = labels.map { ($0, $0.stringValue) }
        let buttons = controls.compactMap { $0 as? NSButton }.filter { !($0 is NSPopUpButton) }
        let originalButtons = buttons.map { ($0, $0.title, $0.state, $0.isEnabled) }
        let popups = controls.compactMap { $0 as? NSPopUpButton }
        let originalItems = popups.filter { $0 !== controller.appLanguage }.flatMap { $0.itemArray.map { ($0, $0.title) } }
        let selections = popups.map { ($0, $0.selectedItem) }
        let blink = try #require(popups.first { $0.accessibilityLabel() == "Caret blink rate" })
        controller.editorFont.stringValue = "uncommitted font search"
        controller.editorFontSize.stringValue = "24."
        controller.editorFontSizeStepper.doubleValue = 24
        controller.acceptsUpdates = { false }
        #expect(window.makeFirstResponder(controller.editorFontSize))
        let editor = try #require(controller.editorFontSize.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 1, length: 1))
        let ko = LocalizationCatalog(language: .korean)
        controller.refreshLocalization(catalog: ko)
        controller.refreshLocalization(catalog: ko)
        #expect(controller.window === window)
        #expect(window.contentView === content)
        #expect(controller.selectedCategory == "Editing")
        #expect(window.title == ko.text("Preferences"))
        for (label, key) in originalLabels {
            #expect(label.stringValue == ko.text(key), "Label: \(key)")
        }
        for (button, key, state, enabled) in originalButtons {
            #expect(button.title == ko.text(key), "Button: \(key)")
            #expect(button.state == state)
            #expect(button.isEnabled == enabled)
        }
        for (item, key) in originalItems { #expect(item.title == ko.text(key)) }
        for (popup, item) in selections { #expect(popup.selectedItem === item) }
        #expect(blink.accessibilityLabel() == ko.text("Caret blink rate"))
        #expect(controller.appLanguage.item(at: 0)?.title == ko.text("Follow macOS"))
        #expect(controller.appLanguage.item(at: 1)?.title == AppLanguage.allCases[1].nativeName)
        #expect(controller.appLanguage.accessibilityLabel() == ko.text("App Language"))
        #expect(controller.editorFont.placeholderString == ko.text("Search fonts"))
        #expect(controller.editorFont.accessibilityLabel() == ko.text("Editor font"))
        #expect(controller.editorFontSize.accessibilityLabel() == ko.text("Font size (pt)"))
        #expect(controller.editorFontSizeStepper.accessibilityLabel() == ko.text("Font size (pt)"))
        #expect(controller.editorFontSize.toolTip == ko.text("Enter a size from 6 to 72 points"))
        #expect(controller.editorFont.stringValue == "uncommitted font search")
        #expect(controller.editorFontSize.stringValue == "24.")
        #expect(controller.editorFontSizeStepper.doubleValue == 24)
        #expect(controller.editorFontSize.currentEditor() === editor)
        #expect(editor.string == "24.")
        #expect(editor.selectedRange() == NSRange(location: 1, length: 1))
        let category = try #require(buttons.first { $0.identifier?.rawValue == "Editing" })
        #expect(category.accessibilityLabel() == ko.text("%1$@ preferences", arguments: [ko.text("Editing")]))
    }

    @Test func refreshDuringSaveRetainsCallbackAndDisabledControls() async throws {
        _ = NSApplication.shared
        let controller = DuckpadSettingsWindowController()
        defer { controller.close() }
        var task: Task<Void, Never>?
        var continuation: CheckedContinuation<Void, Never>?
        var saved: [AppSettings] = []
        controller.onUpdateTaskStarted = { task = $0 }
        controller.configure(settings: .defaults) { settings in
            await withCheckedContinuation { continuation = $0 }
            saved.append(settings)
            return .saved(settings)
        }
        controller.selectCategory("Dark Mode")
        controller.selectAppearance(.dark)
        while continuation == nil { await Task.yield() }
        let ko = LocalizationCatalog(language: .korean)
        controller.refreshLocalization(catalog: ko)
        #expect(controller.isUpdating)
        #expect(!controller.appLanguage.isEnabled)
        #expect(!controller.editorFont.isEnabled)
        #expect(controller.selectedCategory == "Dark Mode")
        continuation?.resume()
        await task?.value
        #expect(saved.count == 1)
        #expect(saved.first?.appearanceMode == .dark)
        #expect(controller.appLanguage.isEnabled)
        #expect(controller.smokeState().status == ko.text("Saved"))
        controller.refreshLocalization(catalog: LocalizationCatalog(language: .japanese))
        #expect(controller.smokeState().status == LocalizationCatalog(language: .japanese).text("Saved"))
    }

    @Test func refreshRetranslatesFailureStatus() async {
        let controller = DuckpadSettingsWindowController()
        defer { controller.close() }
        controller.configure(settings: .defaults) { _ in .failed(.writeFailed("fixture")) }
        await controller.applyForSmoke(.defaults)
        let ko = LocalizationCatalog(language: .korean)
        controller.refreshLocalization(catalog: ko)
        #expect(controller.smokeState().status == ko.text("Could not save preferences: %1$@", arguments: [ko.text("Preferences could not be written to disk.")]))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
