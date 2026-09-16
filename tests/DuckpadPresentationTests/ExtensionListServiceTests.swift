import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
@testable import DuckpadPresentation
import Foundation
import Testing

private actor ListStorageFake: ExtensionServiceStorage {
    var state = Data()
    func load(_ identity: ExtensionServiceRegistration) async throws -> Data { state }
    func save(_ data: Data, for identity: ExtensionServiceRegistration) async throws { state = data }
}
@MainActor private final class ListInvokerFake: ExtensionServiceInvoking {
    var servicePolicyGeneration: UInt64 = 0
    var enabled = true
    var blockSelection = false
    var blockPreview = false
    var previewStarted = false
    var selectedStarted = false
    var events: [String] = []
    var items = [("one", "hello")]
    var retentionDays: UInt32 = 7
    let registration = ExtensionServiceRegistration(
        command: .init(id: .init(rawValue: "com.test.history.show"), title: "Clipboard History", operation: 1, inputScope: .service),
        extensionID: .init(rawValue: "com.test.history"), publisherFingerprint: String(repeating: "a", count: 64),
        packageDigest: String(repeating: "b", count: 64), capabilities: [.clipboardRead, .clipboardWrite, .pluginStorage, .uiList])
    func serviceCommands() -> [ExtensionServiceRegistration] { enabled ? [registration] : [] }
    func validateServiceAccess(_ commandID: ExtensionCommandID, expectedDigest: String) async throws {
        if !enabled { throw ExtensionFailure.cancelled }
    }
    func invokeService(_ commandID: ExtensionCommandID, input: Data) async throws -> Data {
        var offset = 4
        func integer() -> Int {
            defer { offset += 4 }
            return input[offset..<offset+4].enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        }
        let stateLength = integer(); offset += stateLength
        let eventLength = integer(); let event = String(decoding: input[offset..<offset+eventLength], as: UTF8.self)
        offset += eventLength
        let payloadLength = integer(); let payload = String(decoding: input[offset..<offset+payloadLength], as: UTF8.self)
        events.append(event)
        if event == "retention" { retentionDays = UInt32(payload) ?? 7 }
        if event == "preview" {
            previewStarted = true
            while blockPreview { try await Task.sleep(for: .milliseconds(5)) }
        }
        if event == "select" {
            selectedStarted = true
            while blockSelection { try await Task.sleep(for: .milliseconds(5)) }
        }
        var out = Data()
        func number(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { out.append(contentsOf: $0) } }
        func string(_ value: String) { number(UInt32(value.utf8.count)); out.append(contentsOf: value.utf8) }
        number(2); number(0); number(UInt32(items.count))
        for item in items { string(item.0); string(String(item.1.prefix(160).split(separator: "\n", omittingEmptySubsequences: false).first ?? "")); number(0) }
        string((event == "select" || event == "preview") ? items.first(where: { $0.0 == payload })?.1 ?? "" : "")
        number(retentionDays)
        return out
    }
}

@Suite(.serialized) struct ExtensionListServiceTests {
    @MainActor private func dock() -> (NSWindow, NSSplitView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let split = NSSplitView(frame: window.contentLayoutRect)
        split.isVertical = true; split.dividerStyle = .thin
        let editor = NSView(frame: split.bounds); editor.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(editor)
        window.contentView = split
        return (window, split)
    }
    @MainActor private func wait(_ predicate: () -> Bool) async {
        for _ in 0..<200 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(10)) }
        Issue.record("List service did not reach expected state")
    }
    @Test @MainActor func closeMenuDismissesFocusedPluginButKeepsEditorCloseBehavior() async throws {
        _ = NSApplication.shared
        let clipboard = NSPasteboard.withUniqueName()
        let host = ExtensionListServiceHost(storage: ListStorageFake(), pasteboard: clipboard)
        let invoker = ListInvokerFake(); host.synchronize(invoker)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let controller = DuckpadWindowController(workspace: workspace, automaticallyStarts: false)
        controller.configureExtensionServices(host)
        defer { host.unregister(invoker); controller.close(); clipboard.clearContents() }
        controller.start(); await controller.waitForStartup()
        let window = try #require(controller.window)
        let split = try #require(window.contentView?.subviews.compactMap { $0 as? NSSplitView }.first)
        let menu = DuckpadMainMenuFactory.make(target: controller)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let controls = descendants(host.panel)
        let search = try #require(controls.compactMap { $0 as? NSSearchField }.first)
        let table = try #require(controls.compactMap { $0 as? NSTableView }.first)
        let preview = try #require(controls.compactMap { $0 as? NSTextView }.first)
        let button = try #require(controls.compactMap { $0 as? NSButton }.first)
        let before = workspace.snapshot().tabs
        var restored = 0
        for target: NSView in [search, table, preview, button] {
            host.show(invoker.registration.command.id, in: split, onClose: { restored += 1 }) { nil }
            #expect(window.makeFirstResponder(target))
            #expect(menu.performKeyEquivalent(with: key))
            #expect(host.panel.superview == nil)
            #expect(workspace.snapshot().tabs == before)
            #expect(invoker.enabled)
        }
        #expect(restored == 4)
        controller.performNewScratch()
        await wait { workspace.snapshot().tabs.count == before.count + 1 }
        host.show(invoker.registration.command.id, in: split) { nil }
        #expect(window.makeFirstResponder(controller.editor.textView))
        #expect(menu.performKeyEquivalent(with: key))
        await wait { workspace.snapshot().tabs.count == before.count }
        #expect(host.panel.superview === split)
    }

    @Test @MainActor func survivingWindowKeepsOneObserverAndNewerRevocationWins() async {
        _ = NSApplication.shared
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.clearContents() }
        let host = ExtensionListServiceHost(storage: ListStorageFake(), pasteboard: clipboard)
        let first = ListInvokerFake(), second = ListInvokerFake()
        host.synchronize(first); host.synchronize(second); host.unregister(second)
        clipboard.clearContents(); clipboard.setString("after second window closed", forType: .string)
        host.pollClipboard()
        await wait { first.events.contains("capture") }
        #expect(second.events.isEmpty)
        second.enabled = false; second.servicePolicyGeneration = 1
        host.synchronize(second)
        let count = first.events.count
        host.synchronize(first) // stale grants must not resurrect a denied service
        clipboard.clearContents(); clipboard.setString("after revocation", forType: .string)
        host.pollClipboard()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(first.events.count == count)
        host.unregister(first); host.unregister(second)
    }
    @Test @MainActor func delayedSelectionCannotPasteIntoReopenedPanelOrAfterClose() async {
        _ = NSApplication.shared
        let clipboard = NSPasteboard.withUniqueName()
        let host = ExtensionListServiceHost(storage: ListStorageFake(), pasteboard: clipboard)
        let invoker = ListInvokerFake(); host.synchronize(invoker)
        defer { host.panel.close(); host.unregister(invoker); clipboard.clearContents() }
        let (window, split) = dock()
        defer { window.close() }
        var firstPaste = "", secondPaste = ""
        host.show(invoker.registration.command.id, in: split) { { firstPaste = $0; return true } }
        await wait { invoker.events.contains("query") }
        invoker.blockSelection = true
        host.panel.onEvent?("select", "one", "")
        await wait { invoker.selectedStarted }
        host.show(invoker.registration.command.id, in: split) { { secondPaste = $0; return true } }
        invoker.blockSelection = false
        await wait { invoker.events.filter { $0 == "query" }.count == 2 }
        #expect(firstPaste.isEmpty && secondPaste.isEmpty)
        invoker.selectedStarted = false; invoker.blockSelection = true
        host.panel.onEvent?("select", "one", "")
        await wait { invoker.selectedStarted }
        host.panel.close(); invoker.blockSelection = false
        try? await Task.sleep(for: .milliseconds(100))
        #expect(firstPaste.isEmpty && secondPaste.isEmpty)
    }
    @Test @MainActor func sidebarStaysDockedAfterRepeatedPasteAndMovesBetweenWindows() async {
        _ = NSApplication.shared
        let clipboard = NSPasteboard.withUniqueName()
        let host = ExtensionListServiceHost(storage: ListStorageFake(), pasteboard: clipboard)
        let invoker = ListInvokerFake(); host.synchronize(invoker)
        let (first, left) = dock(), (second, right) = dock()
        defer { host.panel.close(); host.unregister(invoker); first.close(); second.close(); clipboard.clearContents() }
        var document = "first", pasted: [String] = []
        var restoredFocus = false
        host.show(invoker.registration.command.id, in: left) {
            let target = document
            return { pasted.append(target + ":" + $0); return true }
        }
        await wait { invoker.events.contains("query") }
        #expect(host.panel.superview === left)
        #expect(left.arrangedSubviews.last === host.panel)
        #expect(host.panel.window === first)
        first.makeKeyAndOrderFront(nil)
        first.contentView?.layoutSubtreeIfNeeded()
        #expect(host.panel.frame.width >= 300 && host.panel.frame.width <= 600)
        left.setPosition(550, ofDividerAt: 0)
        first.contentView?.layoutSubtreeIfNeeded()
        #expect(host.panel.frame.width > 400)
        #expect(left.arrangedSubviews[0].frame.maxX <= host.panel.frame.minX)
        #expect(first.minSize.width >= 760)
        first.setContentSize(NSSize(width: first.minSize.width, height: 280))
        first.contentView?.layoutSubtreeIfNeeded()
        #expect(host.panel.frame.maxX <= left.bounds.width + 1)
        #expect(left.arrangedSubviews[0].frame.width > 0)
        first.setContentSize(NSSize(width: 1000, height: 650))
        func allButtons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(allButtons) }
        #expect(allButtons(host.panel).allSatisfy { $0.keyEquivalent != "\r" })
        // Changing documents after opening uses the target at selection time.
        document = "second"
        host.panel.onEvent?("select", "one", "")
        await wait { pasted.count == 1 }
        document = "third"
        host.panel.onEvent?("select", "one", "")
        await wait { pasted.count == 2 }
        #expect(pasted == ["second:hello", "third:hello"])
        #expect(host.panel.superview === left)
        host.show(invoker.registration.command.id, in: right, onClose: { restoredFocus = true }) { { pasted.append($0); return true } }
        #expect(left.arrangedSubviews.count == 1)
        #expect(first.minSize.width < 760)
        #expect(host.panel.superview === right)
        host.close(in: left) // closing another owner window cannot dismiss this dock
        #expect(host.panel.superview === right)
        host.close(in: right)
        #expect(host.panel.superview == nil)
        #expect(restoredFocus)
    }

    @Test @MainActor func sequentialPasteAdvancesStopsAndIgnoresItsOwnClipboardWrite() async throws {
        _ = NSApplication.shared
        let clipboard = NSPasteboard.withUniqueName()
        let host = ExtensionListServiceHost(storage: ListStorageFake(), pasteboard: clipboard)
        let invoker = ListInvokerFake(); invoker.items = [("one", "first"), ("two", "second"), ("three", "third")]
        host.synchronize(invoker)
        let (window, split) = dock()
        defer { host.panel.close(); host.unregister(invoker); window.close(); clipboard.clearContents() }
        var pasted: [String] = [], allowPaste = true
        host.show(invoker.registration.command.id, in: split) { { text in
            guard allowPaste else { return false }
            pasted.append(text)
            clipboard.clearContents(); clipboard.setString(text, forType: .string)
            return true
        } }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let next = try #require(descendants(host.panel).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "duckpad.plugin.list.paste-next" })
        let table = try #require(descendants(host.panel).compactMap { $0 as? NSTableView }.first)
        await wait { table.numberOfRows == 3 }
        let period = try #require(descendants(host.panel).compactMap { $0 as? NSPopUpButton }.first)
        #expect(period.itemArray.map(\.tag) == [1, 3, 7])
        period.selectItem(withTag: 3)
        NSApplication.shared.sendAction(try #require(period.action), to: period.target, from: period)
        await wait { invoker.retentionDays == 3 && period.selectedTag() == 3 }
        next.performClick(nil)
        await wait { pasted.count == 1 && table.selectedRow == 1 }
        host.pollClipboard()
        #expect(!invoker.events.contains("capture"))
        // Target validation failed: don't advance or consume a sequence item.
        allowPaste = false; next.performClick(nil)
        await wait { invoker.events.filter { $0 == "select" }.count == 2 && next.isEnabled }
        #expect(table.selectedRow == 1 && pasted.count == 1)
        allowPaste = true
        invoker.blockSelection = true; next.performClick(nil)
        await wait { invoker.selectedStarted && !next.isEnabled }
        next.performClick(nil) // no duplicate queued while the guest is busy
        invoker.blockSelection = false
        await wait { pasted.count == 2 && table.selectedRow == 2 }
        next.performClick(nil)
        await wait { pasted.count == 3 && !next.isEnabled }
        #expect(pasted == ["first", "second", "third"])
        #expect(host.panel.superview === split)
        // Background render cannot restart an exhausted sequence.
        host.panel.onEvent?("query", "", "")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!next.isEnabled)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(next.isEnabled)
    }

    @Test @MainActor func previewShowsFullTextWithoutPastingAndCellsAreCentered() async throws {
        _ = NSApplication.shared
        let clipboard = NSPasteboard.withUniqueName()
        clipboard.setString("untouched clipboard", forType: .string)
        let host = ExtensionListServiceHost(storage: ListStorageFake(), pasteboard: clipboard)
        let invoker = ListInvokerFake()
        let fullText = "fn main() {\n    println!(\"안녕하세요\");\n}\n" + String(repeating: "long text ", count: 100)
        invoker.items = [("one", fullText), ("two", "second item\n    indentation")]
        host.synchronize(invoker)
        let (window, split) = dock()
        defer { host.panel.close(); host.unregister(invoker); window.close(); clipboard.clearContents() }
        var pasteCount = 0
        host.show(invoker.registration.command.id, in: split) { { _ in pasteCount += 1; return true } }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let table = try #require(descendants(host.panel).compactMap { $0 as? NSTableView }.first)
        let preview = try #require(descendants(host.panel).compactMap { $0 as? NSTextView }.first { $0.accessibilityIdentifier() == "duckpad.plugin.list.preview" })
        await wait { preview.string == fullText }
        #expect(!preview.isEditable && preview.isSelectable)
        #expect(pasteCount == 0)
        #expect(clipboard.string(forType: .string) == "untouched clipboard")
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(table)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
            let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
            cell.layoutSubtreeIfNeeded()
            let label = try #require(cell.textField)
            #expect(abs(label.frame.midY - cell.bounds.midY) < 0.6)
            #expect(label.frame.minY >= 0 && label.frame.maxY <= cell.bounds.height)
            #expect(preview.enclosingScrollView!.frame.height > 80)
            if let directory = ProcessInfo.processInfo.environment["DUCKPAD_LIST_SCREENSHOT_DIR"],
               let bitmap = host.panel.bitmapImageRepForCachingDisplay(in: host.panel.bounds) {
                host.panel.cacheDisplay(in: host.panel.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(appearance.rawValue + ".png"))
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", String(window.windowNumber), directory + "/window-" + appearance.rawValue + ".png"]
                try capture.run(); capture.waitUntilExit()
            }
        }
        // In-flight preview for a previous selection must not replace the current one.
        invoker.blockPreview = true; invoker.previewStarted = false
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        await wait { invoker.previewStarted }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        invoker.blockPreview = false
        await wait { preview.string == fullText }
        #expect(pasteCount == 0 && !invoker.events.contains("select"))
        invoker.blockPreview = true; invoker.previewStarted = false
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        await wait { invoker.previewStarted }
        host.panel.close(); invoker.blockPreview = false
        try? await Task.sleep(for: .milliseconds(80))
        #expect(preview.string.isEmpty)
        #expect(pasteCount == 0)
    }

}
