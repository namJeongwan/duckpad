import AppKit
import DuckpadDomain

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

        let languageItem = NSMenuItem()
        mainMenu.addItem(languageItem)
        let languageMenu = NSMenu(title: "Language")
        add("Auto", #selector(DuckpadWindowController.performAutomaticLanguage(_:)), "", target, modifiers: [], to: languageMenu)
        let plain = languageMenu.addItem(
            withTitle: "Plain Text",
            action: #selector(DuckpadWindowController.performChooseLanguage(_:)),
            keyEquivalent: ""
        )
        plain.target = target
        plain.representedObject = LanguageID.plainText.rawValue
        languageMenu.addItem(.separator())
        var currentGroup: String?
        for definition in target.languageDefinitions where definition.id != .plainText {
            if currentGroup != definition.group {
                if currentGroup != nil { languageMenu.addItem(.separator()) }
                let heading = NSMenuItem(title: definition.group, action: nil, keyEquivalent: "")
                heading.isEnabled = false
                languageMenu.addItem(heading)
                currentGroup = definition.group
            }
            let item = languageMenu.addItem(
                withTitle: definition.displayName,
                action: #selector(DuckpadWindowController.performChooseLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = definition.id.rawValue
            item.indentationLevel = 1
        }
        languageMenu.addItem(.separator())
        add("Toggle Line Comment", #selector(DuckpadWindowController.performToggleLineComment(_:)), "/", target, to: languageMenu)
        add("Language Command Palette…", #selector(DuckpadWindowController.performShowLanguageChooser(_:)), "p", target, modifiers: [.command, .shift], to: languageMenu)
        languageItem.submenu = languageMenu

        let extensionsItem = NSMenuItem(); mainMenu.addItem(extensionsItem)
        let extensionsMenu = NSMenu(title: "Extensions")
        add("Manage Extensions…", #selector(DuckpadWindowController.performShowExtensions(_:)), "", target, modifiers: [], to: extensionsMenu)
        if !target.extensionCommands.isEmpty { extensionsMenu.addItem(.separator()) }
        for command in target.extensionCommands {
            let item = extensionsMenu.addItem(withTitle: command.title, action: #selector(DuckpadWindowController.performExtensionCommand(_:)), keyEquivalent: "")
            item.target = target; item.representedObject = command.id.rawValue
            item.setAccessibilityLabel("Extension command: \(command.title)")
        }
        extensionsItem.submenu = extensionsMenu
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
