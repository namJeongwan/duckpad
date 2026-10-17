import AppKit
import DuckpadLocalization
@testable import DuckpadPresentation
import Testing

@Suite(.serialized) @MainActor
struct TerminalCommandPaletteTests {
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
        let palette = TerminalCommandPaletteView()
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
        palette.dismiss()
        #expect(window.firstResponder === terminal)
    }

    @Test func closingWindowRemovesPaletteAndItsEventMonitor() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let palette = TerminalCommandPaletteView()
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
