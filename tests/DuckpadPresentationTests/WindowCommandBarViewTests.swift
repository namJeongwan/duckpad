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

        bar.tearDown()
        #expect(bar.menuTitles.isEmpty)
        #expect(bar.button(named: "File") == nil)
        #expect(bar.activeMenuTitle == nil)
    }
}
