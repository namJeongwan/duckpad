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
private func makeCommandBarMenu(
    target: CommandBarTarget,
    overridingMenus: [String: NSMenu] = [:]
) -> NSMenu {
    let main = NSMenu()
    let app = NSMenuItem(title: "Duckpad", action: nil, keyEquivalent: "")
    app.submenu = NSMenu(title: "Duckpad")
    main.addItem(app)
    for title in WindowCommandBarView.presentedMenuTitles {
        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = overridingMenus[title] ?? NSMenu(title: title)
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
    // Native menu tracking mutates NSApplication's process-wide event loop.
    // Run this UI probe in its own test process, not before unrelated AppKit tests.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_NATIVE_MENU_PROBE"] == "1"))
    @MainActor func nativeMenuTrackingLoopSwitchesToTheHoveredSibling() throws {
        let target = CommandBarTarget()
        let (window, bar) = hostCommandBar(mainMenu: makeCommandBarMenu(target: target), appearance: .darkAqua)
        defer { bar.tearDown(); window.contentView = nil; window.close() }
        let file = try #require(bar.button(named: "File"))
        let edit = try #require(bar.button(named: "Edit"))
        window.makeKeyAndOrderFront(nil)
        window.pointerLocation = file.convert(NSPoint(x: file.bounds.midX, y: file.bounds.midY), to: nil)
        var sawEdit = false
        var ticks = 0
        let tick: @MainActor @Sendable () -> Void = {
            ticks += 1
            if bar.activeMenuTitle == "Edit" {
                sawEdit = true
                bar.dismissMenu()
            } else if bar.activeMenuTitle == "File" {
                window.pointerLocation = edit.convert(NSPoint(x: edit.bounds.midX, y: edit.bounds.midY), to: nil)
            }
            if ticks >= 25 { bar.dismissMenu() }
        }
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate() }
        file.performClick(nil)
        #expect(sawEdit)
        #expect(bar.activeMenuTitle == nil)
    }

    @Test @MainActor func openMenuFollowsPointerAcrossTitlesAndStopsAfterDismissal() throws {
        let target = CommandBarTarget()
        let file = MenuPresentationSpy(title: "File")
        let edit = MenuPresentationSpy(title: "Edit")
        let search = MenuPresentationSpy(title: "Search")
        let (window, bar) = hostCommandBar(
            mainMenu: makeCommandBarMenu(target: target, overridingMenus: ["File": file, "Edit": edit, "Search": search]),
            appearance: .darkAqua
        )
        defer { bar.tearDown(); window.contentView = nil; window.close() }
        let fileButton = try #require(bar.button(named: "File"))
        let editButton = try #require(bar.button(named: "Edit"))
        let searchButton = try #require(bar.button(named: "Search"))
        func point(_ button: NSButton) -> NSPoint {
            button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        }
        file.onPresent = {
            #expect(bar.activeMenuTitle == "File")
            bar.trackMenuPointer(at: NSPoint(x: -100, y: -100))
            #expect(bar.activeMenuTitle == "File")
            bar.trackMenuPointer(at: point(editButton))
        }
        edit.onPresent = {
            #expect(bar.activeMenuTitle == "Edit")
            bar.trackMenuPointer(at: point(searchButton))
        }
        search.onPresent = { bar.dismissMenu() }
        fileButton.performClick(nil)
        #expect(file.presentationCount == 1)
        #expect(edit.presentationCount == 1)
        #expect(search.presentationCount == 1)
        #expect(bar.activeMenuTitle == nil)
        bar.trackMenuPointer(at: point(fileButton))
        #expect(file.presentationCount == 1)
    }

    @Test @MainActor func commandBarUsesFamiliarOrderAndOriginalMenuTrees() throws {
        _ = NSApplication.shared
        let target = CommandBarTarget()
        let main = makeCommandBarMenu(target: target)
        let fileMenu = try #require(main.items.first { $0.submenu?.title == "File" }?.submenu)
        let fileCommand = try #require(fileMenu.items.first)
        let bar = WindowCommandBarView(frame: .zero)

        bar.apply(mainMenu: main)

        #expect(bar.menuTitles == [
            "File", "Edit", "Search", "View", "Encoding",
            "Language", "Preferences", "Tools", "Plugins", "Window", "Help",
        ])
        #expect(bar.menu(named: "File") === fileMenu)
        #expect(bar.menu(named: "File")?.items.first === fileCommand)
        #expect(fileCommand.action == #selector(CommandBarTarget.performCommand(_:)))
        #expect(fileCommand.target === target)
        #expect(fileCommand.keyEquivalent == "k")
        let fileButton = try #require(bar.button(named: "File"))
        #expect(fileButton.pullsDown)
        #expect(fileButton.menu === fileMenu)
        #expect(fileButton.target === bar)
        #expect(fileButton.action == NSSelectorFromString("showMenu:"))
        #expect(!fileCommand.isHidden)
    }

    @Test @MainActor func menuContentStartsImmediatelyBelowItsCommandBarButton() throws {
        _ = NSApplication.shared
        let target = CommandBarTarget()
        let languageMenu = MenuPresentationSpy(title: "Language")
        let main = makeCommandBarMenu(
            target: target,
            overridingMenus: ["Language": languageMenu]
        )
        let (window, bar) = hostCommandBar(mainMenu: main, appearance: .darkAqua)
        defer {
            bar.tearDown()
            window.contentView = nil
            window.close()
        }
        let languageButton = try #require(bar.button(named: "Language"))
        let action = try #require(languageButton.action)
        let actionTarget = try #require(languageButton.target)

        #expect(NSApplication.shared.sendAction(action, to: actionTarget, from: languageButton))

        let location = try #require(languageMenu.presentedLocation)
        #expect(languageMenu.presentedItem == nil)
        #expect(languageMenu.presentedView === bar)
        let buttonFrame = languageButton.convert(languageButton.bounds, to: bar)
        #expect(location == NSPoint(x: buttonFrame.minX, y: bar.bounds.minY - 1))
        #expect(location.y < buttonFrame.minY)
    }

    @Test @MainActor func popupTriggerPreservesTypedKeyboardAndAccessibilityPresentation() throws {
        _ = NSApplication.shared
        let target = CommandBarTarget()
        let languageMenu = MenuPresentationSpy(title: "Language")
        let main = makeCommandBarMenu(
            target: target,
            overridingMenus: ["Language": languageMenu]
        )
        let (window, bar) = hostCommandBar(mainMenu: main, appearance: .darkAqua)
        defer {
            bar.tearDown()
            window.contentView = nil
            window.close()
        }
        let languageButton: NSPopUpButton = try #require(bar.button(named: "Language"))

        #expect(languageButton.accessibilityPerformShowMenu())
        #expect(languageMenu.presentationCount == 1)

        let space = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ))
        languageButton.keyDown(with: space)
        #expect(languageMenu.presentationCount == 2)

        languageButton.performClick(nil)
        #expect(languageMenu.presentationCount == 3)
    }

    @Test @MainActor func popupTriggerIgnoresNonNativeKeyboardGestures() throws {
        _ = NSApplication.shared
        let target = CommandBarTarget()
        let languageMenu = MenuPresentationSpy(title: "Language")
        let main = makeCommandBarMenu(
            target: target,
            overridingMenus: ["Language": languageMenu]
        )
        let (window, bar) = hostCommandBar(mainMenu: main, appearance: .darkAqua)
        defer {
            bar.tearDown()
            window.contentView = nil
            window.close()
        }
        let languageButton = try #require(bar.button(named: "Language"))
        let gestures: [(String, UInt16, NSEvent.ModifierFlags)] = [
            (" ", 49, [.shift]),
            ("\r", 36, []),
            ("\r", 76, [.numericPad]),
            ("\u{F701}", 125, [.numericPad]),
        ]

        for (characters, keyCode, modifiers) in gestures {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ))
            languageButton.keyDown(with: event)
        }

        #expect(languageMenu.presentationCount == 0)
    }

    @Test @MainActor func disabledPopupTriggerNeverPresentsItsMenu() throws {
        _ = NSApplication.shared
        let target = CommandBarTarget()
        let languageMenu = MenuPresentationSpy(title: "Language")
        let main = makeCommandBarMenu(
            target: target,
            overridingMenus: ["Language": languageMenu]
        )
        let (window, bar) = hostCommandBar(mainMenu: main, appearance: .darkAqua)
        defer {
            bar.tearDown()
            window.contentView = nil
            window.close()
        }
        let languageButton = try #require(bar.button(named: "Language"))
        languageButton.isEnabled = false

        languageButton.performClick(nil)
        #expect(!languageButton.accessibilityPerformPress())
        #expect(!languageButton.accessibilityPerformShowMenu())

        let mouseDown = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: languageButton.convert(
                NSPoint(x: languageButton.bounds.midX, y: languageButton.bounds.midY),
                to: nil
            ),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        languageButton.mouseDown(with: mouseDown)

        #expect(languageMenu.presentationCount == 0)
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

            if let directory = ProcessInfo.processInfo.environment["DUCKPAD_CHROME_TEST_IMAGES"] {
                let bitmap = try #require(bar.bitmapImageRepForCachingDisplay(in: bar.bounds))
                bar.cacheDisplay(in: bar.bounds, to: bitmap)
                let destination = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(
                    to: destination.appendingPathComponent("menus-\(appearance == .aqua ? "light" : "dark").png")
                )
            }

            _ = bar.prepareMenuForPresentation(named: "File")
            #expect(bar.activeMenuTitle == "File")
            #expect(file.layer?.backgroundColor != restingFile)
            NotificationCenter.default.post(
                name: NSMenu.didEndTrackingNotification,
                object: bar.menu(named: "File")
            )
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
