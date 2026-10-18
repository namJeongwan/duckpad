import AppKit
import DuckpadLocalization
@testable import DuckpadPresentation
import Testing

@Suite(.serialized) @MainActor
struct TerminalCommandPaletteTests {
    @Test func palettePreservesInvokingTextFieldAndSelection() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = try #require(window.contentView)
        let input = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
        input.stringValue = "original text"
        host.addSubview(input)
        #expect(window.makeFirstResponder(input))
        let originalEditor = try #require(input.currentEditor() as? NSTextView)
        let selection = NSRange(location: 3, length: 4)
        originalEditor.setSelectedRange(selection)
        let palette = CommandPaletteView()
        let menu = NSMenu()
        let command = menu.addItem(withTitle: "Select All", action: #selector(NSTextView.selectAll(_:)), keyEquivalent: "")
        palette.onExecute = { item, target in
            #expect(NSApp.sendAction(item.action!, to: target, from: item))
        }
        palette.present(menu: menu, in: host)
        #expect(window.firstResponder !== originalEditor)
        palette.setQuery("Select All")
        palette.refreshIfPresented(menu: menu, excludingAction: nil)
        #expect(palette.filteredCommands.first { $0.item === command }?.target === originalEditor)
        palette.dismiss()
        #expect(input.currentEditor() === window.firstResponder)
        #expect((input.currentEditor() as? NSTextView)?.selectedRange() == selection)
        #expect(input.stringValue == "original text")
        palette.present(menu: menu, in: host)
        palette.setQuery("Select All")
        palette.activateSelectedResult()
        #expect((input.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location: 0, length: 13))
        #expect(input.stringValue == "original text")
    }

    @Test func paletteFollowsLightHostAppearance() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        let palette = CommandPaletteView()
        let target = PaletteFocusView()
        let menu = NSMenu()
        for title in ["Split Terminal Right", "Split Terminal Down", "Equalize Terminal Splits"] {
            let item = menu.addItem(withTitle: title, action: #selector(PaletteFocusView.execute(_:)), keyEquivalent: "d")
            item.target = target
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            palette.present(menu: menu, in: try #require(window.contentView))
            let card = try #require(palette.subviews.first)
            #expect(card.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance)
            palette.layoutSubtreeIfNeeded()
            if let directory = ProcessInfo.processInfo.environment["DUCKPAD_CHROME_TEST_IMAGES"] {
                let bitmap = try #require(palette.bitmapImageRepForCachingDisplay(in: palette.bounds))
                palette.cacheDisplay(in: palette.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let destination = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try png.write(to: destination.appendingPathComponent("palette-\(appearance == .aqua ? "light" : "dark").png"))
            }
            palette.dismiss()
        }
    }

    @Test func paletteStaysInsideWindowAndRestoresTerminalFocus() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = try #require(window.contentView)
        let terminal = PaletteFocusView(frame: host.bounds)
        host.addSubview(terminal)
        window.makeFirstResponder(terminal)
        let palette = CommandPaletteView()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Split Terminal Right", action: #selector(PaletteFocusView.execute(_:)), keyEquivalent: "d")
        item.target = terminal
        item.keyEquivalentModifierMask = .command
        menu.addItem(item)
        var executed = false
        palette.onExecute = { selected, target in
            #expect(selected === item)
            let sameTarget = target === terminal
            #expect(sameTarget)
            #expect(window.firstResponder === terminal)
            executed = true
        }
        palette.present(menu: menu, in: host)
        palette.layoutSubtreeIfNeeded()
        #expect(palette.window === window)
        #expect(palette.bounds.contains(palette.cardFrame))
        #expect(palette.filteredCommands.first?.shortcut == "⌘D")
        #expect(window.firstResponder !== terminal)
        // A narrow window must never force an external popover or clip the card.
        palette.frame.size = NSSize(width: 320, height: 240)
        palette.needsLayout = true
        palette.layoutSubtreeIfNeeded()
        #expect(palette.bounds.contains(palette.cardFrame))
        palette.setQuery("nothing matches")
        #expect(palette.filteredCommands.isEmpty)
        palette.activateSelectedResult()
        #expect(!executed)
        palette.setQuery("split right")
        palette.activateSelectedResult()
        #expect(executed)
        #expect(!palette.isPresented)
        palette.present(menu: menu, in: host)
        let card = try #require(palette.subviews.first)
        let search = try #require(card.subviews.compactMap { $0 as? NSTextField }.first)
        let icon = try #require(card.subviews.compactMap { $0 as? NSImageView }.first)
        #expect(!search.frame.intersects(icon.frame))
        search.stringValue = "nothing matches"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: search)
        #expect(palette.filteredCommands.isEmpty)
        search.stringValue = "split"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: search)
        #expect(palette.filteredCommands.count == 1)
        let replacement = CommandPaletteView()
        replacement.present(menu: menu, in: host)
        #expect(!palette.isPresented)
        #expect(replacement.isPresented)
        replacement.dismiss()
        #expect(window.firstResponder === terminal)
    }

    @Test func closingWindowRemovesPaletteAndItsEventMonitor() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let palette = CommandPaletteView()
        palette.present(menu: NSMenu(), in: try #require(window.contentView))
        #expect(palette.isPresented)
        window.close()
        #expect(!palette.isPresented)
    }
}

@MainActor private final class PaletteFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
    @objc func execute(_ sender: Any?) {}
}
