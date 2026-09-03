import AppKit
import DuckpadApplication
import DuckpadInfrastructure
import Testing
@testable import DuckpadPresentation

@MainActor
private final class CommandPaletteTestTarget: NSObject, NSMenuItemValidation {
    var invocationCount = 0
    var lastArgument: String?
    var unavailableTitles: Set<String> = ["Disabled Command"]

    @objc func performCommand(_ sender: NSMenuItem) {
        invocationCount += 1
        lastArgument = sender.representedObject as? String
    }

    @objc func performPalette(_ sender: NSMenuItem) {}

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        !unavailableTitles.contains(menuItem.title)
    }
}

@MainActor
private func paletteMenu(
    target: CommandPaletteTestTarget,
    includesSecondExtension: Bool = false
) -> NSMenu {
    let root = NSMenu()
    let fileRoot = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    let file = NSMenu(title: "File")
    let save = file.addItem(
        withTitle: "Save All",
        action: #selector(CommandPaletteTestTarget.performCommand(_:)),
        keyEquivalent: "s"
    )
    save.keyEquivalentModifierMask = [.command, .option]
    save.target = target
    save.representedObject = "core.save-all"
    let disabled = file.addItem(
        withTitle: "Disabled Command",
        action: #selector(CommandPaletteTestTarget.performCommand(_:)),
        keyEquivalent: ""
    )
    disabled.target = target
    fileRoot.submenu = file
    root.addItem(fileRoot)

    let extensionRoot = NSMenuItem(title: "Extensions", action: nil, keyEquivalent: "")
    let extensions = NSMenu(title: "Extensions")
    let extensionCommand = extensions.addItem(
        withTitle: "Normalize JSON",
        action: #selector(CommandPaletteTestTarget.performCommand(_:)),
        keyEquivalent: ""
    )
    extensionCommand.target = target
    extensionCommand.representedObject = "plugin.normalize-json"
    if includesSecondExtension {
        let second = extensions.addItem(
            withTitle: "Sort Lines",
            action: #selector(CommandPaletteTestTarget.performCommand(_:)),
            keyEquivalent: ""
        )
        second.target = target
        second.representedObject = "plugin.sort-lines"
    }
    extensionRoot.submenu = extensions
    root.addItem(extensionRoot)

    let viewRoot = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
    let view = NSMenu(title: "View")
    let palette = view.addItem(
        withTitle: "Command Palette…",
        action: #selector(CommandPaletteTestTarget.performPalette(_:)),
        keyEquivalent: "p"
    )
    palette.target = target
    viewRoot.submenu = view
    root.addItem(viewRoot)
    return root
}

@Test @MainActor func commandRegistryUnifiesCorePluginAndNativeMenuCommands() throws {
    _ = NSApplication.shared
    let target = CommandPaletteTestTarget()
    let menu = paletteMenu(target: target)
    let commands = CommandPaletteRegistry.commands(
        in: menu,
        excludingAction: #selector(CommandPaletteTestTarget.performPalette(_:))
    )

    #expect(commands.map(\.title) == ["Save All", "Disabled Command", "Normalize JSON"])
    #expect(commands.map(\.path) == ["File", "File", "Extensions"])
    #expect(commands.map(\.isEnabled) == [true, false, true])
    let save = try #require(commands.first)
    #expect(save.shortcut == "⌥⌘S")
    #expect(save.qualifiedTitle == "File › Save All")
    #expect(commands[2].item.representedObject as? String == "plugin.normalize-json")
}

@Test @MainActor func commandPaletteSearchRanksTitleBeforeMenuPathAndPreservesOriginalItem() throws {
    _ = NSApplication.shared
    let target = CommandPaletteTestTarget()
    let panel = CommandPalettePanel()
    panel.apply(
        menu: paletteMenu(target: target),
        excludingAction: #selector(CommandPaletteTestTarget.performPalette(_:))
    )

    panel.setQuery("normalize json")
    #expect(panel.filteredCommands.map(\.qualifiedTitle) == ["Extensions › Normalize JSON"])
    let selected = try #require(panel.filteredCommands.first?.item)
    var executed: NSMenuItem?
    panel.onExecute = { item, resolvedTarget in
        executed = item
        if let action = item.action {
            NSApplication.shared.sendAction(action, to: resolvedTarget, from: item)
        }
    }
    panel.activateSelectedResult()
    #expect(executed === selected)
    #expect(executed?.representedObject as? String == "plugin.normalize-json")
    #expect(target.invocationCount == 1)
    #expect(target.lastArgument == "plugin.normalize-json")

    panel.setQuery("file save")
    #expect(panel.filteredCommands.map(\.title) == ["Save All"])
    panel.setQuery("⌥⌘s")
    #expect(panel.filteredCommands.map(\.title) == ["Save All"])
}

@Test @MainActor func commandPaletteNeverExecutesACommandThatMenuValidationDisabled() {
    _ = NSApplication.shared
    let target = CommandPaletteTestTarget()
    let panel = CommandPalettePanel()
    panel.apply(menu: paletteMenu(target: target))
    panel.setQuery("Disabled Command")
    var executions = 0
    panel.onExecute = { _, _ in executions += 1 }

    panel.activateSelectedResult()

    #expect(executions == 0)
    #expect(target.invocationCount == 0)
}

@Test @MainActor func activationRevalidatesTheCapturedTargetImmediatelyBeforeDispatch() {
    _ = NSApplication.shared
    let target = CommandPaletteTestTarget()
    let panel = CommandPalettePanel()
    panel.apply(menu: paletteMenu(target: target))
    panel.setQuery("Save All")
    #expect(panel.filteredCommands.first?.isEnabled == true)
    target.unavailableTitles.insert("Save All")
    var executions = 0
    panel.onExecute = { _, _ in executions += 1 }

    panel.activateSelectedResult()

    #expect(executions == 0)
    #expect(target.invocationCount == 0)
}

@Test @MainActor func nilTargetCommandPinsTheResponderResolvedBeforePresentation() throws {
    _ = NSApplication.shared
    let target = CommandPaletteTestTarget()
    let menu = paletteMenu(target: target)
    let save = try #require(menu.items[0].submenu?.items.first)
    save.target = nil
    let commands = CommandPaletteRegistry.commands(
        in: menu,
        targetResolver: { _, _ in target }
    )
    let command = try #require(commands.first(where: { $0.title == "Save All" }))
    #expect(command.target === target)

    if let action = command.item.action, let resolvedTarget = command.target {
        NSApplication.shared.sendAction(action, to: resolvedTarget, from: command.item)
    }

    #expect(target.invocationCount == 1)
    #expect(target.lastArgument == "core.save-all")
}

@Test @MainActor func hostedPaletteRefreshesItsLiveMenuAndClosesWithHostOrTermination() async throws {
    _ = NSApplication.shared
    let target = CommandPaletteTestTarget()
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
    let controller = DuckpadWindowController(workspace: workspace, automaticallyStarts: false)
    controller.start()
    await controller.waitForStartup()
    controller.showAndFocus()
    defer { controller.close() }

    controller.commandPalettePanel.present(
        menu: paletteMenu(target: target),
        excludingAction: nil,
        relativeTo: controller.tabStrip.documentSwitcher
    )
    #expect(controller.commandPalettePanel.isPresented)
    controller.applicationMainMenuDidChange(
        paletteMenu(target: target, includesSecondExtension: true)
    )
    #expect(controller.commandPalettePanel.commands.contains(where: { $0.title == "Sort Lines" }))

    #expect(controller.beginTerminationReviewAdmission())
    #expect(!controller.commandPalettePanel.isPresented)
}

@Test @MainActor func hostedPaletteClosesWithItsHostWindowAndHonorsReduceMotionPolicy() {
    _ = NSApplication.shared
    let target = CommandPaletteTestTarget()
    let panel = CommandPalettePanel()
    let anchor = NSButton(title: "Commands", target: nil, action: nil)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.contentView = anchor
    window.orderFront(nil)
    panel.present(menu: paletteMenu(target: target), excludingAction: nil, relativeTo: anchor)
    #expect(panel.isPresented)

    window.close()

    #expect(!panel.isPresented)
    #expect(CommandPalettePresentationPolicy.popoverAnimates(reduceMotion: false))
    #expect(!CommandPalettePresentationPolicy.popoverAnimates(reduceMotion: true))
}
