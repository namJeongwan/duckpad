import AppKit

/// Native command surface kept in Presentation so shortcuts/selectors can be
/// tested without launching the executable target.
@MainActor
public enum DuckpadMainMenuFactory {
    public static func make(target: DuckpadWindowController) -> NSMenu {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit Duckpad",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        add("Open…", #selector(DuckpadWindowController.performOpenFile(_:)), "o", target, to: fileMenu)
        add("Save", #selector(DuckpadWindowController.performSaveFile(_:)), "s", target, to: fileMenu)
        add("Save As…", #selector(DuckpadWindowController.performSaveFileAs(_:)), "s", target, modifiers: [.command, .shift], to: fileMenu)
        fileMenu.addItem(.separator())
        add("Close Tab", #selector(DuckpadWindowController.performCloseActiveTab(_:)), "w", target, to: fileMenu)
        fileItem.submenu = fileMenu

        let searchItem = NSMenuItem()
        mainMenu.addItem(searchItem)
        let searchMenu = NSMenu(title: "Search")
        add("Find…", #selector(DuckpadWindowController.performShowFind(_:)), "f", target, to: searchMenu)
        add("Find Next", #selector(DuckpadWindowController.performFindNext(_:)), "g", target, to: searchMenu)
        add("Find Previous", #selector(DuckpadWindowController.performFindPrevious(_:)), "g", target, modifiers: [.command, .shift], to: searchMenu)
        add("Replace…", #selector(DuckpadWindowController.performShowReplace(_:)), "h", target, to: searchMenu)
        add("Close Find Panel", #selector(DuckpadWindowController.performCloseFindPanel(_:)), "\u{1b}", target, modifiers: [], to: searchMenu)
        searchItem.submenu = searchMenu

        let tabItem = NSMenuItem()
        mainMenu.addItem(tabItem)
        let tabMenu = NSMenu(title: "Tabs")
        add(
            "Next Tab in Visual Order",
            #selector(DuckpadWindowController.performNextTab(_:)),
            String(UnicodeScalar(NSRightArrowFunctionKey)!),
            target,
            modifiers: [.command, .option],
            to: tabMenu
        )
        add(
            "Previous Tab in Visual Order",
            #selector(DuckpadWindowController.performPreviousTab(_:)),
            String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            target,
            modifiers: [.command, .option],
            to: tabMenu
        )
        add("Last Used Tab", #selector(DuckpadWindowController.performLastUsedTab(_:)), "\t", target, modifiers: [.control], to: tabMenu)
        add("Previous in Tab History", #selector(DuckpadWindowController.performLastUsedTab(_:)), "\t", target, modifiers: [.control, .shift], to: tabMenu)
        tabMenu.addItem(.separator())
        add("Move Tab Left", #selector(DuckpadWindowController.performMoveActiveTabLeft(_:)), "[", target, modifiers: [.command, .shift], to: tabMenu)
        add("Move Tab Right", #selector(DuckpadWindowController.performMoveActiveTabRight(_:)), "]", target, modifiers: [.command, .shift], to: tabMenu)
        tabItem.submenu = tabMenu
        return mainMenu
    }

    private static func add(
        _ title: String,
        _ action: Selector,
        _ keyEquivalent: String,
        _ target: DuckpadWindowController,
        modifiers: NSEvent.ModifierFlags = [.command],
        to menu: NSMenu
    ) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
    }
}
