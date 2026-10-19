import AppKit
import Testing
import DuckpadDomain
import DuckpadApplication
import DuckpadInfrastructure
import DuckpadLocalization
@testable import DuckpadPresentation

@Suite(.serialized)
struct ShortcutRegistryTests {
    @MainActor private func menu() -> NSMenu {
        let menu = NSMenu()
        for (title, action, key) in [("Duplicate", "performDuplicateLine:", "d"), ("Next", "performSelectNextOccurrence:", ""), ("Copy", "performCopy:", "c")] {
            let item = NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key)
            item.keyEquivalentModifierMask = key.isEmpty ? [] : [.command]
            menu.addItem(item)
        }
        return menu
    }
    @Test @MainActor func overridePersistsThroughRebuildAndCanSwapDefault() throws {
        let overrides = ["performDuplicateLine:": "cmd+shift+d", "performSelectNextOccurrence:": "cmd+d", "performCopy:": ""]
        let first = ShortcutRegistry(menu: menu(), overrides: overrides)
        let second = ShortcutRegistry(menu: menu(), overrides: overrides)
        #expect(first.entries.map(\.displayShortcut) == ["⇧⌘D", "⌘D", ""])
        #expect(second.entries.map(\.displayShortcut) == first.entries.map(\.displayShortcut))
        #expect(second.suppressedDefaults.contains(.init(key: "c", modifiers: NSEvent.ModifierFlags.command.rawValue)))
        #expect(!second.suppressedDefaults.contains(.init(key: "d", modifiers: NSEvent.ModifierFlags.command.rawValue)))
        #expect(second.conflict(for: "cmd+d", excluding: "performCopy:")?.id == "performSelectNextOccurrence:")
    }
    @Test @MainActor func conflictingImportedBindingsCannotStealExistingCommand() {
        let registry = ShortcutRegistry(menu: menu(), overrides: ["performSelectNextOccurrence:": "cmd+c"])
        #expect(registry.entries[1].displayShortcut.isEmpty)
        #expect(registry.entries[2].displayShortcut == "⌘C")
    }
    @Test @MainActor func duplicateMenuAliasesShareOneCommand() {
        let menu = menu()
        menu.addItem(NSMenuItem(title: "Copy alias", action: NSSelectorFromString("performCopy:"), keyEquivalent: ""))
        let registry = ShortcutRegistry(menu: menu, overrides: ["performCopy:": "ctrl+c"])
        #expect(registry.entries.count == 3)
        #expect(menu.items.filter { !$0.keyEquivalent.isEmpty && $0.action == NSSelectorFromString("performCopy:") }.count == 1)
    }
    @Test @MainActor func allAliasShortcutsParticipateInConflictsAndSuppression() throws {
        func aliasedMenu() -> NSMenu {
            let menu = menu()
            for flags: NSEvent.ModifierFlags in [[.control], [.control, .shift]] {
                let item = NSMenuItem(title: "Tab History", action: NSSelectorFromString("performLastUsedTab:"), keyEquivalent: "\t")
                item.keyEquivalentModifierMask = flags
                menu.addItem(item)
            }
            return menu
        }
        let original = ShortcutRegistry(menu: aliasedMenu(), overrides: [:])
        #expect(original.conflict(for: "ctrl+shift+tab", excluding: "performSelectNextOccurrence:")?.id == "performLastUsedTab:")
        let imported = ShortcutRegistry(menu: aliasedMenu(), overrides: ["performSelectNextOccurrence:": "ctrl+shift+tab"])
        #expect(imported.entries.first { $0.id == "performSelectNextOccurrence:" }?.displayShortcut == "")
        let replaced = ShortcutRegistry(menu: aliasedMenu(), overrides: ["performLastUsedTab:": "cmd+shift+h"])
        #expect(replaced.suppressedDefaults.contains(.init(key: "\t", modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)))
        #expect(replaced.suppressedDefaults.contains(.init(key: "\t", modifiers: NSEvent.ModifierFlags.control.rawValue)))
    }
    @Test func shortcutSettingsDecodeOldArchivesAndRoundTrip() throws {
        var archive = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.defaults)) as? [String: Any])
        archive.removeValue(forKey: "keyboardShortcuts")
        let old = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: archive))
        #expect(old.keyboardShortcuts.isEmpty)
        var changed = old
        changed.keyboardShortcuts = ["performSelectNextOccurrence:": "cmd+shift+d", "performCopy:": ""]
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(changed)).keyboardShortcuts == changed.keyboardShortcuts)
    }
}

extension ShortcutRegistryTests {
    @MainActor private func event(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags, window: NSWindow? = nil) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1, windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
    @Test @MainActor func previewShowsBeforeAfterAndRejectsConflictUntilEnter() throws {
        _ = NSApplication.shared
        let registry = ShortcutRegistry(menu: menu(), overrides: [:])
        let preview = ShortcutChangePreview(entry: registry.entries[0], registry: registry)
        var result: String?
        var completions = 0
        preview.onComplete = { result = $0; completions += 1 }
        #expect(preview.comparison == "⌘D → …")
        preview.capture(try event(8, "c", .command))
        #expect(preview.comparison == "⌘D → ⌘C")
        #expect(preview.hasError)
        preview.capture(try event(36, "\r", []))
        #expect(completions == 0)
        preview.capture(try event(18, "1", .control))
        #expect(preview.comparison == "⌘D → ⌃1")
        #expect(preview.canApply)
        #expect(registry.entries[0].displayShortcut == "⌘D")
        #expect(completions == 0)
        preview.capture(try event(36, "\r", []))
        #expect(result == "ctrl+1")
        #expect(completions == 1)
    }
    @Test @MainActor func captureNormalizesKoreanAndFunctionKeys() throws {
        _ = NSApplication.shared
        #expect(ShortcutRecorder.declaration(for: try event(2, "ㅇ", .command)) == "cmd+d")
        #expect(ShortcutRecorder.declaration(for: try event(111, "\u{10}", .control)) == "ctrl+f12")
        #expect(ShortcutRecorder.declaration(for: try event(49, " ", .command)) == nil)
        #expect(ShortcutRecorder.declaration(for: try event(18, "1", [])) == nil)
    }
    @Test @MainActor func shortcutWindowsFitAllLanguagesAndRowsAreCentered() throws {
        _ = NSApplication.shared
        let previous = L10n.catalog.language
        defer { L10n.configure(language: previous) }
        for raw in ["en", "ko", "ja", "zh-Hans", "de", "fr", "it", "pt-BR"] {
            L10n.configure(language: try #require(AppLanguage(rawValue: raw)))
            let panel = KeyboardShortcutsWindow()
            let registry = ShortcutRegistry(menu: menu(), overrides: [:])
            panel.refresh(registry: registry)
            let window = try #require(panel.window)
            window.setContentSize(NSSize(width: 600, height: 420))
            let content = try #require(window.contentView)
            content.layoutSubtreeIfNeeded()
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let buttons = descendants(content).compactMap { $0 as? NSButton }.filter { $0.target === panel }
            #expect(buttons.count == 4)
            for button in buttons { #expect(button.frame.width >= button.intrinsicContentSize.width) }
            let table = try #require(descendants(content).compactMap { $0 as? NSTableView }.first)
            let cell = try #require(panel.tableView(table, viewFor: table.tableColumns[0], row: 0))
            cell.frame = NSRect(x: 0, y: 0, width: 400, height: 42)
            cell.layoutSubtreeIfNeeded()
            let stack = try #require(cell.subviews.first)
            #expect(abs(stack.frame.midY - cell.bounds.midY) < 1)
            let preview = ShortcutChangePreview(entry: registry.entries[0], registry: registry)
            preview.frame = NSRect(x: 0, y: 0, width: 200, height: 42)
            preview.layoutSubtreeIfNeeded()
            let comparison = try #require(preview.subviews.first)
            #expect(abs(comparison.frame.midY - 21) < 1)
            #expect(comparison.frame.maxX <= preview.bounds.maxX)
            panel.close()
        }
    }
}


extension ShortcutRegistryTests {
    @Test @MainActor func minimapCommandTracksSavedPreferenceAndAppearsInPalette() async throws {
        _ = NSApplication.shared
        let controller = DuckpadWindowController(workspace: ScratchWorkspaceUseCase(store: InMemorySessionStore()),
            previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(), automaticallyStarts: false)
        defer { controller.close() }
        var settings = AppSettings.defaults
        controller.applyPreferences(settings)
        controller.onMinimapVisibilityChanged = { visible in
            settings.minimapVisible = visible
            controller.applyPreferences(settings)
            return true
        }
        defer { controller.onMinimapVisibilityChanged = nil }
        let menu = DuckpadMainMenuFactory.make(target: controller)
        let command = try #require(CommandPaletteRegistry.commands(in: menu).first {
            $0.item.action == #selector(DuckpadWindowController.performToggleMinimap(_:))
        })
        #expect(controller.validateMenuItem(command.item))
        #expect(command.item.state == .on)
        controller.performToggleMinimap()
        #expect(!controller.validateMenuItem(command.item))
        try await Task.sleep(for: .milliseconds(20))
        #expect(!settings.minimapVisible)
        #expect(controller.validateMenuItem(command.item))
        #expect(command.item.state == .off)
    }
}


extension ShortcutRegistryTests {
    @Test @MainActor func typingStartsComparisonAndEscapeRestoresSynchronously() async throws {
        _ = NSApplication.shared
        let panel = KeyboardShortcutsWindow()
        var persisted: [String: String] = [:]
        panel.onSave = { bindings, expected in
            #expect(expected == persisted)
            persisted = bindings
            panel.window?.makeFirstResponder(nil) // Native disabled controls may relinquish focus.
            panel.refresh(registry: ShortcutRegistry(menu: self.menu(), overrides: bindings))
            return true
        }
        defer { panel.onSave = nil; panel.close() }
        panel.refresh(registry: ShortcutRegistry(menu: menu(), overrides: [:]))
        let window = try #require(panel.window)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
        let table = try #require(descendants(content).compactMap { $0 as? ShortcutTableView }.first)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let displayedCell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let hit = displayedCell.convert(NSPoint(x: 12, y: 12), to: table.superview)
        #expect(table.hitTest(hit) === table)
        window.makeFirstResponder(table)
        let router = AuxiliaryCloseKeyRouter()
        #expect(router.handle(try event(18, "1", .control, window: window)))
        #expect(panel.capture?.comparison == "⌘D → ⌃1")
        #expect(window.attachedSheet == nil)
        #expect(panel.tableView(table, heightOfRow: 0) == 42)
        // Escape is synchronous: no persistence or delayed reset can race another key.
        #expect(router.handle(try event(53, "\u{1b}", [], window: window)))
        #expect(panel.capture == nil)
        #expect(persisted.isEmpty)
        #expect(window.firstResponder === table)
        #expect(router.handle(try event(13, "w", .command, window: window)))
        #expect(panel.capture?.comparison == "⌘D → ⌘W")
        #expect(panel.handleShortcutKey(try event(8, "c", .command, window: window)))
        #expect(panel.capture?.hasError == true)
        #expect(panel.handleShortcutKey(try event(36, "\r", [], window: window)))
        #expect(persisted.isEmpty)
        #expect(panel.capture != nil)
        #expect(panel.handleShortcutKey(try event(18, "1", .control, window: window)))
        try await Task.sleep(for: .milliseconds(20))
        #expect(panel.capture?.comparison == "⌘D → ⌃1")
        #expect(window.firstResponder === table)
        #expect(panel.handleShortcutKey(try event(36, "\r", [], window: window)))
        try await Task.sleep(for: .milliseconds(20))
        #expect(persisted == ["performDuplicateLine:": "ctrl+1"])
        #expect(window.firstResponder === table)
        #expect(panel.capture == nil)
        #expect(panel.handleShortcutKey(try event(19, "2", .control, window: window)))
        #expect(panel.capture?.comparison == "⌃1 → ⌃2")
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        #expect(panel.capture == nil)
        #expect(persisted == ["performDuplicateLine:": "ctrl+1"])
        // Search input does not start shortcut capture or swallow normal text editing.
        let search = try #require(descendants(content).compactMap { $0 as? NSSearchField }.first)
        window.makeFirstResponder(search)
        #expect(!table.routeShortcutKey(try event(18, "1", .control, window: window)))
    }
}
