import AppKit
@testable import DuckpadPresentation
import Testing

@MainActor
private final class CommandBarTarget: NSObject, NSMenuItemValidation {
    var allowsCommand = false

    @objc func performCommand(_ sender: Any?) {}

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.state = allowsCommand ? .on : .off
        return allowsCommand
    }
}

@MainActor
private func makeCommandBarMenu(target: CommandBarTarget) -> NSMenu {
    let main = NSMenu()
    let app = NSMenuItem(title: "Duckpad", action: nil, keyEquivalent: "")
    app.submenu = NSMenu(title: "Duckpad")
    main.addItem(app)
    for title in ["File", "Format", "Edit", "Search", "View", "Tabs", "Window", "Language", "Extensions"] {
        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        let command = NSMenuItem(
            title: "\(title) command",
            action: #selector(CommandBarTarget.performCommand(_:)),
            keyEquivalent: title == "File" ? "k" : ""
        )
        command.target = target
        menu.addItem(command)
        root.submenu = menu
        main.addItem(root)
    }
    return main
}

@MainActor
private final class CommandBarPointerWindow: NSWindow {
    var pointerLocation = NSPoint(x: -1_000, y: -1_000)

    override var mouseLocationOutsideOfEventStream: NSPoint { pointerLocation }
}

@MainActor
private func hostCommandBar(
    mainMenu: NSMenu,
    appearance: NSAppearance.Name
) -> (CommandBarPointerWindow, WindowCommandBarView) {
    let window = CommandBarPointerWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.appearance = NSAppearance(named: appearance)
    window.isReleasedWhenClosed = false
    let bar = WindowCommandBarView(frame: .zero)
    let root = NSView(frame: window.contentLayoutRect)
    root.addSubview(bar)
    NSLayoutConstraint.activate([
        bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        bar.topAnchor.constraint(equalTo: root.topAnchor),
    ])
    window.contentView = root
    bar.apply(mainMenu: mainMenu)
    root.layoutSubtreeIfNeeded()
    bar.layoutSubtreeIfNeeded()
    return (window, bar)
}

@Suite(.serialized)
struct WindowCommandBarViewTests {
    @Test @MainActor func commandBarUsesFamiliarOrderAndOriginalMenuTrees() throws {
        _ = NSApplication.shared
        let target = CommandBarTarget()
        let main = makeCommandBarMenu(target: target)
        let fileMenu = try #require(main.items.first { $0.submenu?.title == "File" }?.submenu)
        let fileCommand = try #require(fileMenu.items.first)
        let bar = WindowCommandBarView(frame: .zero)

        bar.apply(mainMenu: main)

        #expect(bar.menuTitles == [
            "File", "Edit", "Search", "View", "Format",
            "Language", "Tabs", "Extensions", "Window",
        ])
        #expect(bar.menu(named: "File") === fileMenu)
        #expect(bar.menu(named: "File")?.items.first === fileCommand)
        #expect(fileCommand.action == #selector(CommandBarTarget.performCommand(_:)))
        #expect(fileCommand.target === target)
        #expect(fileCommand.keyEquivalent == "k")
        let fileButton = try #require(bar.button(named: "File"))
        #expect(fileButton.pullsDown)
        #expect(fileButton.menu === fileMenu)
        #expect((fileButton.cell as? NSPopUpButtonCell)?.preferredEdge == .minY)
        #expect(!fileCommand.isHidden)
    }

    @Test @MainActor func hoverAndOpenStatesRemainDistinctInDarkAndLightAppearances() throws {
        _ = NSApplication.shared
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let target = CommandBarTarget()
            let main = makeCommandBarMenu(target: target)
            let (window, bar) = hostCommandBar(mainMenu: main, appearance: appearance)
            defer {
                bar.tearDown()
                window.contentView = nil
                window.close()
            }
            let file = try #require(bar.button(named: "File"))
            let edit = try #require(bar.button(named: "Edit"))
            let restingFile = file.layer?.backgroundColor
            let restingEdit = edit.layer?.backgroundColor

            window.pointerLocation = file.convert(
                NSPoint(x: file.bounds.midX, y: file.bounds.midY),
                to: nil
            )
            bar.updateTrackingAreas()
            let hoveredFile = file.layer?.backgroundColor
            #expect(hoveredFile != restingFile)
            #expect(edit.layer?.backgroundColor == restingEdit)

            window.pointerLocation = edit.convert(
                NSPoint(x: edit.bounds.midX, y: edit.bounds.midY),
                to: nil
            )
            bar.updateTrackingAreas()
            #expect(file.layer?.backgroundColor == restingFile)
            #expect(edit.layer?.backgroundColor != restingEdit)

            NotificationCenter.default.post(
                name: NSPopUpButtonCell.willPopUpNotification,
                object: file.cell
            )
            #expect(bar.activeMenuTitle == "File")
            #expect(file.layer?.backgroundColor != restingFile)
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: file.menu)
            #expect(bar.activeMenuTitle == nil)
        }
    }

    @Test @MainActor func preparingMenuRefreshesValidationAndDismissClearsTrackingState() throws {
        _ = NSApplication.shared
        let target = CommandBarTarget()
        let main = makeCommandBarMenu(target: target)
        let bar = WindowCommandBarView(frame: .zero)
        bar.apply(mainMenu: main)
        let command = try #require(bar.menu(named: "File")?.items.first)

        target.allowsCommand = true
        #expect(bar.prepareMenuForPresentation(named: "File") === bar.menu(named: "File"))
        #expect(command.isEnabled)
        #expect(command.state == .on)
        #expect(bar.activeMenuTitle == "File")

        target.allowsCommand = false
        #expect(bar.prepareMenuForPresentation(named: "File") != nil)
        #expect(!command.isEnabled)
        #expect(command.state == .off)
        bar.dismissMenu()
        #expect(bar.activeMenuTitle == nil)
    }

    @Test @MainActor func commandBarExposesConciseMenuAccessibilityAndTearsDown() throws {
        _ = NSApplication.shared
        let target = CommandBarTarget()
        let bar = WindowCommandBarView(frame: .zero)
        bar.apply(mainMenu: makeCommandBarMenu(target: target))
        let fileButton = try #require(bar.button(named: "File"))

        #expect(bar.accessibilityIdentifier() == "duckpad.window.command-bar")
        #expect(bar.accessibilityLabel() == "Application commands")
        #expect(fileButton.accessibilityIdentifier() == "duckpad.window.command.file")
        #expect(fileButton.accessibilityLabel() == "File menu")
        #expect(fileButton.accessibilityRole() == .popUpButton)
        #expect(fileButton.trackingAreas.contains {
            $0.options.contains(.mouseEnteredAndExited) && $0.options.contains(.activeAlways)
        })

        bar.tearDown()
        #expect(bar.menuTitles.isEmpty)
        #expect(bar.button(named: "File") == nil)
        #expect(bar.activeMenuTitle == nil)
        #expect(fileButton.target == nil)
        #expect(fileButton.action == nil)
        #expect(fileButton.menu == nil)
        #expect(fileButton.trackingAreas.isEmpty)
    }

    @Test @MainActor func teardownAndReapplyPreserveTheOriginalMenuAttachmentAndVisibility() throws {
        _ = NSApplication.shared
        let target = CommandBarTarget()
        let main = makeCommandBarMenu(target: target)
        let fileRoot = try #require(main.items.first { $0.submenu?.title == "File" })
        let fileMenu = try #require(fileRoot.submenu)
        fileMenu.items[0].isHidden = true
        fileMenu.addItem(NSMenuItem(title: "Visible command", action: nil, keyEquivalent: ""))
        let originalItems = fileMenu.items
        let originalHidden = originalItems.map(\.isHidden)
        let originalSupermenu = fileMenu.supermenu
        let bar = WindowCommandBarView(frame: .zero)

        bar.apply(mainMenu: main)
        bar.tearDown()
        #expect(fileRoot.submenu === fileMenu)
        #expect(fileMenu.supermenu === originalSupermenu)
        #expect(fileMenu.items.elementsEqual(originalItems, by: { $0 === $1 }))
        #expect(fileMenu.items.map(\.isHidden) == originalHidden)

        bar.apply(mainMenu: main)
        bar.apply(mainMenu: main)
        #expect(fileRoot.submenu === fileMenu)
        #expect(fileMenu.supermenu === originalSupermenu)
        #expect(fileMenu.items.elementsEqual(originalItems, by: { $0 === $1 }))
        #expect(fileMenu.items.map(\.isHidden) == originalHidden)
        bar.tearDown()
    }
}
