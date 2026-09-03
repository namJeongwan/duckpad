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
        add("New Scratch", #selector(DuckpadWindowController.performNewScratch(_:)), "n", target, to: fileMenu)
        add("New Window", #selector(DuckpadWindowController.performNewWindow(_:)), "n", target, modifiers: [.command, .shift], to: fileMenu)
        add("Open…", #selector(DuckpadWindowController.performOpenFile(_:)), "o", target, to: fileMenu)
        add(
            "Add Folder to Workspace…",
            #selector(DuckpadWindowController.performAddWorkspaceFolder(_:)),
            "o",
            target,
            modifiers: [.command, .control],
            to: fileMenu
        )
        add(
            "Remove Folder from Workspace",
            #selector(DuckpadWindowController.performRemoveWorkspaceFolder(_:)),
            "",
            target,
            modifiers: [],
            to: fileMenu
        )
        fileMenu.addItem(.separator())
        add("Save", #selector(DuckpadWindowController.performSaveFile(_:)), "s", target, to: fileMenu)
        add("Save As…", #selector(DuckpadWindowController.performSaveFileAs(_:)), "s", target, modifiers: [.command, .shift], to: fileMenu)
        fileMenu.addItem(.separator())
        add("Close Tab", #selector(DuckpadWindowController.performCloseActiveTab(_:)), "w", target, to: fileMenu)
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        add("Undo", #selector(DuckpadWindowController.performUndo(_:)), "z", target, to: editMenu)
        add("Redo", #selector(DuckpadWindowController.performRedo(_:)), "z", target, modifiers: [.command, .shift], to: editMenu)
        editMenu.addItem(.separator())
        add("Cut", #selector(DuckpadWindowController.performCut(_:)), "x", target, to: editMenu)
        add("Copy", #selector(DuckpadWindowController.performCopy(_:)), "c", target, to: editMenu)
        add("Paste", #selector(DuckpadWindowController.performPaste(_:)), "v", target, to: editMenu)
        add("Delete", #selector(DuckpadWindowController.performDelete(_:)), "", target, modifiers: [], to: editMenu)
        editMenu.addItem(.separator())
        add("Select All", #selector(DuckpadWindowController.performSelectAll(_:)), "a", target, to: editMenu)
        editMenu.addItem(.separator())
        add("Duplicate Line", #selector(DuckpadWindowController.performDuplicateLine(_:)), "d", target, to: editMenu)
        add(
            "Move Line Up",
            #selector(DuckpadWindowController.performMoveLineUp(_:)),
            String(UnicodeScalar(NSUpArrowFunctionKey)!),
            target,
            modifiers: [.option],
            to: editMenu
        )
        add(
            "Move Line Down",
            #selector(DuckpadWindowController.performMoveLineDown(_:)),
            String(UnicodeScalar(NSDownArrowFunctionKey)!),
            target,
            modifiers: [.option],
            to: editMenu
        )
        add("Delete Line", #selector(DuckpadWindowController.performDeleteLine(_:)), "k", target, modifiers: [.command, .shift], to: editMenu)
        add("Join Lines", #selector(DuckpadWindowController.performJoinLines(_:)), "j", target, modifiers: [.control], to: editMenu)
        editMenu.addItem(.separator())
        add("Indent Line(s)", #selector(DuckpadWindowController.performIndent(_:)), "", target, modifiers: [], to: editMenu)
        add("Unindent Line(s)", #selector(DuckpadWindowController.performUnindent(_:)), "", target, modifiers: [], to: editMenu)
        add("Make Uppercase", #selector(DuckpadWindowController.performUppercase(_:)), "", target, modifiers: [], to: editMenu)
        add("Make Lowercase", #selector(DuckpadWindowController.performLowercase(_:)), "", target, modifiers: [], to: editMenu)
        add("Trim Trailing Whitespace", #selector(DuckpadWindowController.performTrimTrailingWhitespace(_:)), "", target, modifiers: [], to: editMenu)
        editItem.submenu = editMenu

        let searchItem = NSMenuItem()
        mainMenu.addItem(searchItem)
        let searchMenu = NSMenu(title: "Search")
        add("Find…", #selector(DuckpadWindowController.performShowFind(_:)), "f", target, to: searchMenu)
        add("Find Next", #selector(DuckpadWindowController.performFindNext(_:)), "g", target, to: searchMenu)
        add("Find Previous", #selector(DuckpadWindowController.performFindPrevious(_:)), "g", target, modifiers: [.command, .shift], to: searchMenu)
        add("Replace…", #selector(DuckpadWindowController.performShowReplace(_:)), "h", target, to: searchMenu)
        add("Find in Folder…", #selector(DuckpadWindowController.performFindInFolder(_:)), "f", target, modifiers: [.command, .shift], to: searchMenu)
        add("Close Find Panel", #selector(DuckpadWindowController.performCloseFindPanel(_:)), "\u{1b}", target, modifiers: [], to: searchMenu)
        searchMenu.addItem(.separator())
        let f2 = String(UnicodeScalar(NSF2FunctionKey)!)
        add("Toggle Bookmark", #selector(DuckpadWindowController.performToggleBookmark(_:)), f2, target, modifiers: [.command], to: searchMenu)
        add("Next Bookmark", #selector(DuckpadWindowController.performNextBookmark(_:)), f2, target, modifiers: [], to: searchMenu)
        add("Previous Bookmark", #selector(DuckpadWindowController.performPreviousBookmark(_:)), f2, target, modifiers: [.shift], to: searchMenu)
        add("Clear All Bookmarks", #selector(DuckpadWindowController.performClearBookmarks(_:)), f2, target, modifiers: [.command, .shift], to: searchMenu)
        searchItem.submenu = searchMenu

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        add(
            "Workspace Sidebar",
            #selector(DuckpadWindowController.performToggleWorkspaceSidebar(_:)),
            "e",
            target,
            modifiers: [.command, .shift],
            to: viewMenu
        )
        viewMenu.addItem(.separator())
        add("Word Wrap", #selector(DuckpadWindowController.performToggleWordWrap(_:)), "", target, modifiers: [], to: viewMenu)
        add("Show Wrap Symbols", #selector(DuckpadWindowController.performToggleWrapMarker(_:)), "", target, modifiers: [], to: viewMenu)
        viewMenu.addItem(.separator())
        add("Split Editor Right", #selector(DuckpadWindowController.performSplitEditorRight(_:)), "\\", target, to: viewMenu)
        add("Split Editor Down", #selector(DuckpadWindowController.performSplitEditorDown(_:)), "\\", target, modifiers: [.command, .option], to: viewMenu)
        add("Focus Other Editor Pane", #selector(DuckpadWindowController.performFocusOtherEditorPane(_:)), "\\", target, modifiers: [.command, .control], to: viewMenu)
        add("Close Editor Split", #selector(DuckpadWindowController.performCloseEditorSplit(_:)), "\\", target, modifiers: [.command, .shift], to: viewMenu)
        viewItem.submenu = viewMenu

        let tabItem = NSMenuItem()
        mainMenu.addItem(tabItem)
        let tabMenu = NSMenu(title: "Tabs")
        add(
            "Undo Close Tab",
            #selector(DuckpadWindowController.performRestoreLastClosedTab(_:)),
            "t",
            target,
            modifiers: [.command, .shift],
            to: tabMenu
        )
        add(
            "Open Document…",
            #selector(DuckpadWindowController.performShowDocumentSwitcher(_:)),
            "o",
            target,
            modifiers: [.command, .shift],
            to: tabMenu
        )
        tabMenu.addItem(.separator())
        add("Close All Tabs", #selector(DuckpadWindowController.performCloseAllTabs(_:)), "", target, modifiers: [], to: tabMenu)
        add("Close Other Tabs", #selector(DuckpadWindowController.performCloseOtherTabs(_:)), "", target, modifiers: [], to: tabMenu)
        add("Close Tabs to Left", #selector(DuckpadWindowController.performCloseTabsToLeft(_:)), "", target, modifiers: [], to: tabMenu)
        add("Close Tabs to Right", #selector(DuckpadWindowController.performCloseTabsToRight(_:)), "", target, modifiers: [], to: tabMenu)
        add("Close Unchanged Tabs", #selector(DuckpadWindowController.performCloseUnchangedTabs(_:)), "", target, modifiers: [], to: tabMenu)
        add("Close Unpinned Tabs", #selector(DuckpadWindowController.performCloseUnpinnedTabs(_:)), "", target, modifiers: [], to: tabMenu)
        tabMenu.addItem(.separator())
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

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        let minimize = windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        minimize.keyEquivalentModifierMask = [.command]
        let zoom = windowMenu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        zoom.keyEquivalentModifierMask = []
        let fullScreen = windowMenu.addItem(
            withTitle: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        windowMenu.addItem(.separator())
        let front = windowMenu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        front.keyEquivalentModifierMask = []
        windowItem.submenu = windowMenu
        NSApplication.shared.windowsMenu = windowMenu

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
