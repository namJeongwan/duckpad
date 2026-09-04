import AppKit
import DuckpadDomain

@MainActor @objc public protocol DuckpadApplicationCommandTarget: AnyObject {
    func performOpenRecentDocument(_ sender: Any?)
    func performClearRecentDocuments(_ sender: Any?)
}

/// Native command surface kept in Presentation so shortcuts/selectors can be
/// tested without launching the executable target.
@MainActor
public enum DuckpadMainMenuFactory {
    public static func make(
        target: DuckpadWindowController,
        applicationTarget: AnyObject? = nil,
        recentDocumentURLs: [URL] = []
    ) -> NSMenu {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        let settingsTarget: AnyObject = applicationTarget ?? target
        add(
            "Settings…",
            #selector(DuckpadWindowController.performShowSettings(_:)),
            ",",
            settingsTarget,
            to: appMenu
        )
        appMenu.addItem(.separator())
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
        fileMenu.addItem(makeOpenRecentItem(
            applicationTarget: applicationTarget,
            urls: recentDocumentURLs
        ))
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
        add("Save a Copy As…", #selector(DuckpadWindowController.performSaveCopyAs(_:)), "s", target, modifiers: [.command, .option, .shift], to: fileMenu)
        add("Save All", #selector(DuckpadWindowController.performSaveAll(_:)), "s", target, modifiers: [.command, .option], to: fileMenu)
        fileMenu.addItem(.separator())
        add("Close Tab", #selector(DuckpadWindowController.performCloseActiveTab(_:)), "w", target, to: fileMenu)
        fileItem.submenu = fileMenu

        let formatItem = NSMenuItem()
        mainMenu.addItem(formatItem)
        formatItem.submenu = makeFormatMenu(target: target)

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
        editMenu.addItem(.separator())
        add(
            "Complete Current Document Word",
            #selector(DuckpadWindowController.performCompleteCurrentDocumentWord(_:)),
            " ",
            target,
            modifiers: [.control],
            to: editMenu
        )
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
        add("Go to Line / Column…", #selector(DuckpadWindowController.performGoToLine(_:)), "g", target, modifiers: [.control], to: searchMenu)
        add("Go to UTF-8 Offset…", #selector(DuckpadWindowController.performGoToOffset(_:)), "", target, modifiers: [], to: searchMenu)
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
            "Command Palette…",
            #selector(DuckpadWindowController.performShowCommandPalette(_:)),
            "p",
            target,
            modifiers: [.command, .shift],
            to: viewMenu
        )
        viewMenu.addItem(.separator())
        add(
            "Document Symbols…",
            #selector(DuckpadWindowController.performShowDocumentSymbols(_:)),
            "o",
            target,
            modifiers: [.command, .option],
            to: viewMenu
        )
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
        add("Show Whitespace", #selector(DuckpadWindowController.performToggleWhitespace(_:)), "", target, modifiers: [], to: viewMenu)
        add("Show Line Endings", #selector(DuckpadWindowController.performToggleLineEndings(_:)), "", target, modifiers: [], to: viewMenu)
        viewMenu.addItem(.separator())
        add("Zoom In", #selector(DuckpadWindowController.performZoomIn(_:)), "+", target, to: viewMenu)
        add("Zoom Out", #selector(DuckpadWindowController.performZoomOut(_:)), "-", target, to: viewMenu)
        add("Actual Size", #selector(DuckpadWindowController.performResetZoom(_:)), "0", target, to: viewMenu)
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
        add("Choose Language…", #selector(DuckpadWindowController.performShowLanguageChooser(_:)), "", target, modifiers: [], to: languageMenu)
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

    private static func makeOpenRecentItem(
        applicationTarget: AnyObject?,
        urls: [URL]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Open Recent")
        var seen: Set<URL> = []
        var recent: [URL] = []
        for url in urls {
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized).inserted else { continue }
            recent.append(standardized)
            if recent.count == 10 { break }
        }
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No Recent Documents", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for url in recent {
                let title = recentTitle(for: url, among: recent)
                let recentItem = NSMenuItem(
                    title: title,
                    action: #selector(DuckpadApplicationCommandTarget.performOpenRecentDocument(_:)),
                    keyEquivalent: ""
                )
                recentItem.target = applicationTarget
                recentItem.representedObject = url
                recentItem.toolTip = url.path
                recentItem.setAccessibilityLabel("Open recent document \(title)")
                recentItem.setAccessibilityValue(url.path)
                menu.addItem(recentItem)
            }
            menu.addItem(.separator())
            let clear = NSMenuItem(
                title: "Clear Menu",
                action: #selector(DuckpadApplicationCommandTarget.performClearRecentDocuments(_:)),
                keyEquivalent: ""
            )
            clear.target = applicationTarget
            menu.addItem(clear)
        }
        item.submenu = menu
        return item
    }

    private static func recentTitle(for url: URL, among urls: [URL]) -> String {
        let peers = urls.filter { $0.lastPathComponent == url.lastPathComponent }
        guard peers.count > 1 else { return url.lastPathComponent }
        let parentComponents = peers.map {
            $0.deletingLastPathComponent().standardizedFileURL.pathComponents.filter { $0 != "/" }
        }
        let own = url.deletingLastPathComponent().standardizedFileURL.pathComponents.filter { $0 != "/" }
        let maximumDepth = parentComponents.map(\.count).max() ?? 1
        for depth in 1...maximumDepth {
            let labels = parentComponents.map { $0.suffix(depth).joined(separator: "/") }
            guard Set(labels).count == peers.count else { continue }
            return "\(url.lastPathComponent) — \(own.suffix(depth).joined(separator: "/"))"
        }
        return "\(url.lastPathComponent) — \(url.deletingLastPathComponent().path)"
    }

    static func makeFormatMenu(target: DuckpadWindowController) -> NSMenu {
        let formatMenu = NSMenu(title: "Format")

        let encodingItem = NSMenuItem(title: "Convert and Save Encoding", action: nil, keyEquivalent: "")
        let encodingMenu = NSMenu(title: "Convert and Save Encoding")
        add("UTF-8 without BOM", #selector(DuckpadWindowController.performConvertToUTF8(_:)), "", target, modifiers: [], to: encodingMenu)
        add("UTF-8 with BOM", #selector(DuckpadWindowController.performConvertToUTF8BOM(_:)), "", target, modifiers: [], to: encodingMenu)
        encodingMenu.addItem(.separator())
        add("UTF-16 LE with BOM", #selector(DuckpadWindowController.performConvertToUTF16LittleEndian(_:)), "", target, modifiers: [], to: encodingMenu)
        add("UTF-16 LE without BOM", #selector(DuckpadWindowController.performConvertToUTF16LittleEndianWithoutBOM(_:)), "", target, modifiers: [], to: encodingMenu)
        add("UTF-16 BE with BOM", #selector(DuckpadWindowController.performConvertToUTF16BigEndian(_:)), "", target, modifiers: [], to: encodingMenu)
        add("UTF-16 BE without BOM", #selector(DuckpadWindowController.performConvertToUTF16BigEndianWithoutBOM(_:)), "", target, modifiers: [], to: encodingMenu)
        encodingItem.submenu = encodingMenu
        formatMenu.addItem(encodingItem)

        let endingsItem = NSMenuItem(title: "Convert and Save Line Endings", action: nil, keyEquivalent: "")
        let endingsMenu = NSMenu(title: "Convert and Save Line Endings")
        add("Unix (LF)", #selector(DuckpadWindowController.performConvertToLF(_:)), "", target, modifiers: [], to: endingsMenu)
        add("Windows (CRLF)", #selector(DuckpadWindowController.performConvertToCRLF(_:)), "", target, modifiers: [], to: endingsMenu)
        add("Classic Mac (CR)", #selector(DuckpadWindowController.performConvertToCR(_:)), "", target, modifiers: [], to: endingsMenu)
        endingsItem.submenu = endingsMenu
        formatMenu.addItem(endingsItem)

        formatMenu.addItem(.separator())
        let openItem = NSMenuItem(title: "Open Using Encoding", action: nil, keyEquivalent: "")
        let openMenu = NSMenu(title: "Open Using Encoding")
        add("Open as UTF-8…", #selector(DuckpadWindowController.performOpenAsUTF8(_:)), "", target, modifiers: [], to: openMenu)
        add("Open as UTF-16 LE…", #selector(DuckpadWindowController.performOpenAsUTF16LittleEndian(_:)), "", target, modifiers: [], to: openMenu)
        add("Open as UTF-16 BE…", #selector(DuckpadWindowController.performOpenAsUTF16BigEndian(_:)), "", target, modifiers: [], to: openMenu)
        openItem.submenu = openMenu
        formatMenu.addItem(openItem)
        return formatMenu
    }

    private static func add(
        _ title: String,
        _ action: Selector,
        _ keyEquivalent: String,
        _ target: AnyObject,
        modifiers: NSEvent.ModifierFlags = [.command],
        to menu: NSMenu
    ) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
    }
}
