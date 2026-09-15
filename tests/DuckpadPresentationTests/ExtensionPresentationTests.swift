import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import DuckpadLocalization
@testable import DuckpadPresentation
import Foundation
import Testing

private actor PresentationExtensionLoader: ExtensionPackageLoaderPort {
    var packages: [LoadedExtensionPackage]
    init(_ package: LoadedExtensionPackage) { packages = [package] }
    init(_ packages: [LoadedExtensionPackage]) { self.packages = packages }
    func discover() async -> ExtensionDiscoveryReport { .init(packages: packages) }
    func replace(_ values: [LoadedExtensionPackage]) { packages = values }
}

private actor PresentationExtensionPolicy: ExtensionGrantStorePort {
    var policy = ExtensionPolicySnapshot()
    func loadPolicy() async throws -> ExtensionPolicySnapshot { policy }
    func savePolicy(_ policy: ExtensionPolicySnapshot) async throws -> ExtensionPolicyCommit { self.policy = policy; return .committed }
}

private actor PresentationExtensionTransport: PluginHostTransport {
    func invoke(_ request: ExtensionHostRequest) async throws -> ExtensionHostResponse { .init(result: .init(edits: [])) }
    func cancel(requestID: UUID) async {}
}

private actor BlockingPresentationExtensionTransport: PluginHostTransport {
    private var requests: [UUID] = []
    private var cancelled: [UUID] = []
    private var released = false
    func invoke(_ request: ExtensionHostRequest) async throws -> ExtensionHostResponse {
        requests.append(request.requestID)
        while !released { await Task.yield() }
        if cancelled.contains(request.requestID) { throw ExtensionFailure.cancelled }
        return .init(result: .init(edits: []))
    }
    func cancel(requestID: UUID) async {
        cancelled.append(requestID)
        released = true
    }
    func requestCount() -> Int { requests.count }
    func cancelCount() -> Int { cancelled.count }
}

@MainActor
private final class PresentationExtensionEditor: ExtensionEditorPort {
    var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)?
    var descriptor: EditorBufferDescriptor?
    var inputEnabledHistory: [Bool] = []
    func display(_ buffer: EditorBufferDescriptor) { descriptor = buffer }
    func install(_ snapshot: EditorTextSnapshot) { descriptor = .init(bufferID: snapshot.bufferID, revision: snapshot.revision) }
    func snapshot(for bufferID: BufferID) -> EditorTextSnapshot? { descriptor.map { .init(bufferID: $0.bufferID, revision: $0.revision, text: "") } }
    func retire(bufferID: BufferID) {}
    func setInputEnabled(_ isEnabled: Bool) { inputEnabledHistory.append(isEnabled) }
    func focus() {}
    func recoverySnapshot(for bufferID: BufferID) -> EditorRecoverySnapshot? { nil }
    func recoveryCapture(for bufferID: BufferID) -> EditorRecoveryCapture? { nil }
    func acknowledgeRecoverySnapshot(_ snapshot: EditorRecoverySnapshot) {}
    func installRecovery(_ snapshot: EditorRecoverySnapshot) {}
    func activeSelectionUTF8Range() -> SearchUTF8Range? { .init(location: 0, length: 0) }
    func captureExtensionInput(tabID: TabID, expectedBuffer: EditorBufferDescriptor, scope: ExtensionCommandContribution.InputScope, maximumBytes: Int) throws(ExtensionFailure) -> ExtensionEditorCapture {
        guard descriptor == expectedBuffer else { throw .staleContext }
        return .init(tabID: tabID, buffer: expectedBuffer, documentByteLength: 0, selection: .init(location: 0, length: 0), scopedUTF8: Data())
    }
    func findActive(_ request: ActiveSearchRequest) throws(SearchFailure) -> SearchUTF8Range? { nil }
    func selectAndReveal(_ range: SearchUTF8Range) {}
    func replaceActive(range: SearchUTF8Range, with replacementUTF8: Data, expectedRevision: UInt64) -> EditorEditOutcome { .rejected(currentRevision: descriptor?.revision ?? 0) }
    func replaceActiveBatch(_ edits: [SearchReplacementEdit], expectedRevision: UInt64, accept: ([EditorIncrementalEdit]) -> EditorEditOutcome) -> EditorEditOutcome { .rejected(currentRevision: descriptor?.revision ?? 0) }
}

private func presentationPackage(
    id rawID: String = "com.duckpad.sample",
    command rawCommandID: String = "com.duckpad.sample.sort",
    title: String = "Sort",
    shortcut: String? = "cmd+option+k",
    digestCharacter: Character = "1",
    secondCommand rawSecondCommandID: String? = nil,
    secondShortcut: String? = nil,
    service: Bool = false,
    native: Bool = false,
    version: SemanticVersion = .init(major: 1, minor: 2, patch: 3)
) -> LoadedExtensionPackage {
    let id = ExtensionID(rawValue: rawID)
    let commandID = ExtensionCommandID(rawValue: rawCommandID)
    let requests: [ExtensionCapabilityRequest] = service
        ? [.init(id: .clipboardRead, scope: .application), .init(id: .clipboardWrite, scope: .application),
           .init(id: .pluginStorage, scope: .application), .init(id: .uiList, scope: .application)] + (native ? [.init(id: .nativeCode, scope: .application)] : [])
        : [.init(id: .documentsRead, scope: .selection), .init(id: .documentsWrite, scope: .selection)]
    var commands = [ExtensionCommandContribution(
        id: commandID, title: title, operation: 1, inputScope: service ? .service : .selection
    )]
    var keybindings = shortcut.map { [ExtensionKeybindingContribution(command: commandID, key: $0)] } ?? []
    if let rawSecondCommandID {
        let secondCommandID = ExtensionCommandID(rawValue: rawSecondCommandID)
        commands.append(.init(id: secondCommandID, title: title, operation: 2, inputScope: .selection))
        if let secondShortcut {
            keybindings.append(.init(command: secondCommandID, key: secondShortcut))
        }
    }
    return LoadedExtensionPackage(
        manifest: .init(id: id, name: "Sample", version: version,
            api: .init(minimum: .init(major: 1, minor: 0, patch: 0), maximumExclusive: .init(major: 2, minor: 0, patch: 0)),
            publisher: .init(id: "com.duckpad", keyID: "sample"), runtime: .init(kind: native ? "native" : "wasm-core", module: native ? "module.dylib" : "module.wasm", abi: native ? "duckpad-native-1" : "duckpad-wasm-1"),
            capabilities: requests, contributes: .init(
                commands: commands,
                keybindings: keybindings
            )),
        module: Data(), packageDigest: String(repeating: digestCharacter, count: 64), publisherFingerprint: String(repeating: "2", count: 64),
        signatureDigest: String(repeating: "3", count: 64), capabilitySchemaDigest: String(repeating: "4", count: 64), trustSource: .bundled, nativeFiles: native ? ["module.dylib": Data()] : nil
    )
}

@Test @MainActor
func equalTitleExtensionShortcutCollisionUsesCommandIDAsStableTieBreak() async throws {
    _ = NSApplication.shared
    let package = presentationPackage(
        command: "com.duckpad.sample.z-command",
        title: "Same Title",
        shortcut: "cmd+option+k",
        digestCharacter: "3",
        secondCommand: "com.duckpad.sample.a-command",
        secondShortcut: "command+alt+k"
    )
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
    let editor = PresentationExtensionEditor()
    let service = ExtensionWorkspaceUseCase(
        loader: PresentationExtensionLoader(package),
        grants: PresentationExtensionPolicy(),
        transport: PresentationExtensionTransport(),
        workspace: workspace,
        editor: editor
    )
    let controller = DuckpadWindowController(
        workspace: workspace,
        editorAdapter: editor,
        editorView: NSView(),
        extensionUseCase: service,
        automaticallyStarts: false
    )
    controller.start()
    await controller.waitForStartup()

    let menu = DuckpadMainMenuFactory.make(target: controller)
    let commands = try #require(
        menu.items.compactMap(\.submenu)
            .first(where: { $0.title == "Plugins" })?
            .items.filter { $0.representedObject is String }
    )
    #expect(commands.map { $0.representedObject as? String } == [
        "com.duckpad.sample.a-command", "com.duckpad.sample.z-command",
    ])
    #expect(commands[0].keyEquivalent == "k")
    #expect(commands[1].keyEquivalent.isEmpty)
    #expect(commands[1].toolTip?.contains("conflicts with another command") == true)
    controller.close()
}

@Test @MainActor
func asyncExtensionRefreshRebuildsAuthorizedMenuAndDisclosesConsentIdentity() async throws {
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
    let editor = PresentationExtensionEditor(); let package = presentationPackage()
    let service = ExtensionWorkspaceUseCase(loader: PresentationExtensionLoader(package), grants: PresentationExtensionPolicy(),
        transport: PresentationExtensionTransport(), workspace: workspace, editor: editor)
    let controller = DuckpadWindowController(workspace: workspace, editorAdapter: editor, editorView: NSView(), extensionUseCase: service, automaticallyStarts: false)
    var menu = DuckpadMainMenuFactory.make(target: controller)
    controller.onExtensionCommandsChanged = { menu = DuckpadMainMenuFactory.make(target: controller) }
    #expect(controller.extensionCommands.isEmpty)
    controller.start(); await controller.waitForStartup()
    #expect(controller.extensionCommands.map(\.id) == [ExtensionCommandID(rawValue: "com.duckpad.sample.sort")])
    let extensions = try #require(menu.items.compactMap(\.submenu).first(where: { $0.title == "Plugins" }))
    let command = try #require(extensions.items.first(where: { $0.representedObject as? String == "com.duckpad.sample.sort" }))
    #expect(command.accessibilityLabel() == "Extension command: Sort")
    #expect(command.keyEquivalent == "k")
    #expect(command.keyEquivalentModifierMask == [.command, .option])
    #expect(command.accessibilityValue() as? String == "Keyboard shortcut Command-Option-K")
    let disclosure = try #require(controller.extensionReviewDisclosure(for: package.manifest.id, revoking: false))
    #expect(disclosure.contains("com.duckpad")); #expect(disclosure.contains(String(repeating: "2", count: 64)))
    #expect(disclosure.contains("1.2.3")); #expect(disclosure.contains(String(repeating: "1", count: 64)))
    #expect(disclosure.contains("documents.read [selection]")); #expect(disclosure.contains("until revoked"))
    controller.close()
}

@Test @MainActor
func extensionShortcutsFailClosedOnCoreCollisionOrMalformedDeclaration() async throws {
    _ = NSApplication.shared
    for (declaration, expectedMessage) in [
        ("cmd+option+s", "conflicts with another command"),
        ("cmd+option+/", "conflicts with another command"),
        ("shift+k", "not a supported macOS key combination"),
        ("cmd+cmd+k", "not a supported macOS key combination"),
        ("cmd+\u{7f}", "not a supported macOS key combination"),
    ] {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = PresentationExtensionEditor()
        let service = ExtensionWorkspaceUseCase(
            loader: PresentationExtensionLoader(presentationPackage(shortcut: declaration)),
            grants: PresentationExtensionPolicy(),
            transport: PresentationExtensionTransport(),
            workspace: workspace,
            editor: editor
        )
        let controller = DuckpadWindowController(
            workspace: workspace,
            editorAdapter: editor,
            editorView: NSView(),
            extensionUseCase: service,
            automaticallyStarts: false
        )
        controller.start()
        await controller.waitForStartup()
        let menu = DuckpadMainMenuFactory.make(target: controller)
        let command = try #require(
            menu.items.compactMap(\.submenu)
                .first(where: { $0.title == "Plugins" })?
                .items.first(where: { $0.representedObject as? String == "com.duckpad.sample.sort" })
        )
        #expect(command.keyEquivalent.isEmpty)
        #expect(command.keyEquivalentModifierMask.isEmpty)
        #expect(command.toolTip?.contains(expectedMessage) == true)
        controller.close()
    }
}

@Test @MainActor
func applicationTerminationCancelsAndJoinsExtensionBeforeApproval() async throws {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
    let editor = PresentationExtensionEditor()
    let package = presentationPackage()
    let transport = BlockingPresentationExtensionTransport()
    let service = ExtensionWorkspaceUseCase(
        loader: PresentationExtensionLoader(package), grants: PresentationExtensionPolicy(),
        transport: transport, workspace: workspace, editor: editor
    )
    let coordinator = ApplicationTerminationCoordinator()
    let controller = DuckpadWindowController(
        workspace: workspace, editorAdapter: editor, editorView: NSView(),
        terminationCoordinator: coordinator, extensionUseCase: service,
        automaticallyStarts: false
    )
    controller.start()
    await controller.waitForStartup()

    let command = NSMenuItem()
    command.representedObject = "com.duckpad.sample.sort"
    controller.performExtensionCommand(command)
    while await transport.requestCount() == 0 { await Task.yield() }

    let approved = await withCheckedContinuation { continuation in
        #expect(coordinator.applicationShouldTerminate { continuation.resume(returning: $0) } == .terminateLater)
    }
    #expect(approved)
    #expect(await transport.cancelCount() == 1)
    #expect(editor.inputEnabledHistory.last == false)
    controller.close()
}

@Test @MainActor
func deniedTerminationReopensInvocationAndEditorAdmission() async throws {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
    let editor = PresentationExtensionEditor()
    let package = presentationPackage()
    let transport = PresentationExtensionTransport()
    let service = ExtensionWorkspaceUseCase(
        loader: PresentationExtensionLoader(package), grants: PresentationExtensionPolicy(),
        transport: transport, workspace: workspace, editor: editor
    )
    let controller = DuckpadWindowController(
        workspace: workspace, editorAdapter: editor, editorView: NSView(),
        extensionUseCase: service, automaticallyStarts: false
    )
    controller.start()
    await controller.waitForStartup()
    let descriptor = try #require(workspace.snapshot().activeBuffer)
    #expect(workspace.acceptEditorEdit(.init(
        bufferID: descriptor.bufferID, expectedRevision: descriptor.revision,
        range: .init(location: 0, length: 0), replacement: "x"
    )) == .accepted(newRevision: descriptor.revision + 1))

    // No dirty-decision presenter means termination is denied after the gate
    // has closed. Both editor and invocation admission must be restored.
    #expect(await controller.reviewDirtyDocumentsForTermination() == false)
    #expect(editor.inputEnabledHistory.suffix(2) == [false, true])
    editor.display(try #require(workspace.snapshot().activeBuffer))
    _ = try await service.invoke(.init(rawValue: "com.duckpad.sample.sort"))
    controller.close()
}

@Test @MainActor
func clipboardServiceAppearsInToolsWithOneShortcutAndTracksActivation() async throws {
    _ = NSApplication.shared
    let package = presentationPackage(id: "com.duckpad.clipboard-history", command: "com.duckpad.clipboard-history.show",
        title: "Clipboard History", shortcut: "cmd+option+v", service: true)
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
    let editor = PresentationExtensionEditor()
    let service = ExtensionWorkspaceUseCase(loader: PresentationExtensionLoader(package),
        grants: PresentationExtensionPolicy(), transport: PresentationExtensionTransport(), workspace: workspace, editor: editor)
    let controller = DuckpadWindowController(workspace: workspace, editorAdapter: editor, editorView: NSView(),
        extensionUseCase: service, automaticallyStarts: false)
    defer { controller.close() }
    var menu = DuckpadMainMenuFactory.make(target: controller)
    controller.onExtensionCommandsChanged = { menu = DuckpadMainMenuFactory.make(target: controller) }
    controller.start(); await controller.waitForStartup()
    let tools = try #require(menu.items.compactMap(\.submenu).first { $0.title == L10n.text("Tools") })
    let commandID = "com.duckpad.clipboard-history.show"
    let command = try #require(tools.items.first { $0.representedObject as? String == commandID })
    #expect(command.title == L10n.text("Clipboard History"))
    #expect(command.keyEquivalent == "v")
    #expect(command.keyEquivalentModifierMask == [.command, .option])
    #expect(command.target === controller)
    #expect(command.action == #selector(DuckpadWindowController.performExtensionCommand(_:)))
    func matches(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            (item.representedObject as? String == commandID ? [item] : []) + (item.submenu.map(matches) ?? [])
        }
    }
    #expect(matches(menu).count == 1)
    MenuLocalization.apply(to: menu, catalog: LocalizationCatalog(language: .korean))
    #expect(command.title == "클립보드 기록")
    #expect(tools.title == "도구")
    #expect(command.keyEquivalent == "v")
    MenuLocalization.apply(to: menu, catalog: LocalizationCatalog(language: .english))
    #expect(command.title == "Clipboard History")
    try await service.setEnabled(package.manifest.id, enabled: false)
    #expect(matches(menu).isEmpty)
    try await service.setEnabled(package.manifest.id, enabled: true)
    #expect(matches(menu).isEmpty) // Re-enabling still requires renewed grants.
    let review = try service.consentReviewToken(for: package.manifest.id)
    try await service.grantReviewed(review, choices: Set(package.manifest.capabilities))
    #expect(matches(menu).count == 1)
}

@Test @MainActor
func signedNativeClipboardInstallsDocksAndStopsWhenDisabled() async throws {
    guard let path = ProcessInfo.processInfo.environment["DUCKPAD_NATIVE_CLIPBOARD_PACKAGE"] else {
        print("SKIP: set DUCKPAD_NATIVE_CLIPBOARD_PACKAGE to a signed native Clipboard package")
        return
    }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-native-host-test-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let loader = LocalExtensionPackageLoader(root: root.appendingPathComponent("Extensions"), bundledPackages: [])
    try await loader.install(from: URL(fileURLWithPath: path))
    let discovery = await loader.discover()
    #expect(discovery.failures.isEmpty)
    let package = try #require(discovery.packages.first)
    #expect(package.manifest.runtime.kind == "native")
    #expect(package.nativeFiles?["locale-ja.strings"] != nil)
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
    let editor = PresentationExtensionEditor()
    let service = ExtensionWorkspaceUseCase(loader: loader, grants: PresentationExtensionPolicy(),
        transport: PresentationExtensionTransport(), workspace: workspace, editor: editor, allowsUserExtensions: true)
    let controller = DuckpadWindowController(workspace: workspace, editorAdapter: editor, editorView: NSView(), extensionUseCase: service, automaticallyStarts: false)
    let nativeStore = ManagedNativePackageStore(root: root.appendingPathComponent("NativePluginModules"))
    let host = ExtensionListServiceHost(storage: LocalExtensionServiceStorage(root: root.appendingPathComponent("PluginData")), nativeStorageRoot: root.appendingPathComponent("PluginData"), prepareNativePackage: { _ = try await nativeStore.install(files: $0) })
    controller.configureExtensionServices(host)
    defer { controller.close() }
    controller.start(); await controller.waitForStartup()
    #expect(controller.extensionCommands.isEmpty)
    try await service.setEnabled(package.manifest.id, enabled: true)
    #expect(controller.extensionCommands.isEmpty)
    let review = try service.consentReviewToken(for: package.manifest.id)
    try await service.grantReviewed(review, choices: Set(package.manifest.capabilities))
    #expect(controller.extensionCommands.count == 1)
    let nativeRegistration = try #require(service.serviceCommands().first)
    try await host.prepareNativeInstallation(for: package.manifest.id)
    let reopened = try NativePluginInstallation.open(nativeRegistration, root: root.appendingPathComponent("NativePluginModules"))
    #expect(reopened.directory.lastPathComponent == package.packageDigest + ".duckpad-plugin")
    #expect(try await nativeStore.install(files: #require(package.nativeFiles)) == package.packageDigest)
    host.synchronize(service)
    let disclosure = try #require(controller.extensionReviewDisclosure(for: package.manifest.id, revoking: false))
    #expect(disclosure.contains("runs inside Duckpad"))
    #expect(!disclosure.contains("No direct filesystem"))
    let menu = DuckpadMainMenuFactory.make(target: controller)
    let tools = try #require(menu.items.compactMap(\.submenu).first { $0.title == "Tools" })
    let item = try #require(tools.items.first { $0.representedObject as? String == package.manifest.contributes.commands[0].id.rawValue })
    #expect(item.keyEquivalent == "v" && item.keyEquivalentModifierMask == [.command, .option])
    controller.performExtensionCommand(item)
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let content = try #require(controller.window?.contentView)
    let deadline = ContinuousClock.now + .seconds(2)
    while !descendants(content).contains(where: { $0.accessibilityIdentifier() == "duckpad.plugin.list.sidebar" }), ContinuousClock.now < deadline { await Task.yield() }
    let panel = try #require(descendants(content).first { $0.accessibilityIdentifier() == "duckpad.plugin.list.sidebar" })
    #expect(String(reflecting: type(of: panel)).contains("DuckpadClipboardNative"))
    #expect(panel.superview is NSSplitView)
    let window = try #require(controller.window)
    let tabIDs = workspace.snapshot().tabs.map(\.id)
    let closeKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
    #expect(window.makeFirstResponder(panel))
    #expect(window.performKeyEquivalent(with: closeKey))
    #expect(panel.superview == nil)
    #expect(workspace.snapshot().tabs.map(\.id) == tabIDs)
    #expect(service.serviceCommands().count == 1) // Closing does not disable collection.
    controller.performExtensionCommand(item)
    let reopenDeadline = ContinuousClock.now + .seconds(2)
    while panel.superview == nil, ContinuousClock.now < reopenDeadline { await Task.yield() }
    #expect(panel.superview is NSSplitView)
    // Copying or running native data through the WASM transport is never allowed.
    await #expect(throws: ExtensionFailure.self) { try await service.invokeService(package.manifest.contributes.commands[0].id, input: Data()) }
    try await service.setEnabled(package.manifest.id, enabled: false)
    #expect(panel.superview == nil)
    #expect(controller.extensionCommands.isEmpty)
    let authorizedResource = reopened.directory.appendingPathComponent("locale-ja.strings")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authorizedResource.path)
    try Data("tampered".utf8).write(to: authorizedResource)
    #expect(throws: NativePluginInstallation.Failure.self) {
        try NativePluginInstallation.open(nativeRegistration, root: root.appendingPathComponent("NativePluginModules"))
    }
    // Installed native resources remain intact; mutation is rejected on rediscovery.
    let installed = root.appendingPathComponent("Extensions/\(package.manifest.id.rawValue)@\(package.manifest.version).duckpad-plugin")
    try Data("tampered".utf8).write(to: installed.appendingPathComponent("locale-ja.strings"))
    let tampered = await loader.discover()
    #expect(tampered.packages.isEmpty)
    #expect(!tampered.failures.isEmpty)
}

@Test @MainActor
func pluginUpdateButtonChecksAutomaticallyAndStagesUntilRelaunch() async throws {
    _ = NSApplication.shared
    let old = presentationPackage(service: true, native: true)
    let new = presentationPackage(digestCharacter: "5", service: true, native: true, version: .init(major: 1, minor: 3, patch: 0))
    let loader = PresentationExtensionLoader(old)
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
    let service = ExtensionWorkspaceUseCase(loader: loader, grants: PresentationExtensionPolicy(), transport: PresentationExtensionTransport(), workspace: workspace, editor: PresentationExtensionEditor())
    await service.refresh()
    let manager = ExtensionsManagerPanel()
    defer { manager.close() }
    let catalog = LocalizationCatalog(language: .japanese)
    manager.refreshLocalization(catalog: catalog)
    manager.render(service.state())
    let release = ExtensionUpdate(extensionID: old.manifest.id, version: new.manifest.version, downloadURL: URL(string: "https://github.com/example/sample/releases/download/v1.3.0/plugin.zip")!, sha256: String(repeating: "0", count: 64), publisherID: old.manifest.publisher.id, keyID: old.manifest.publisher.keyID)
    let updater = ExtensionUpdateController(useCase: service, panel: manager,
        check: { _ in [old.manifest.id: release] },
        prepare: { release, _ in PreparedExtensionUpdate(release: release, package: new, files: [:]) },
        install: { _ in await loader.replace([old, new]) }, onError: { error in Issue.record("Update failed: \(error)") })
    service.onStateChange = { state in manager.render(state); updater.registryChanged(state) }
    defer { service.onStateChange = nil }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let root = try #require(manager.window?.contentView)
    let button = try #require(descendants(root).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "duckpad.extensions.update" })
    let status = try #require(descendants(root).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "duckpad.extensions.update-status" })
    let deadline = ContinuousClock.now + .seconds(3)
    while !button.isEnabled, ContinuousClock.now < deadline { await Task.yield() }
    #expect(button.title == catalog.text("Update to %1$@", arguments: ["1.3.0"]))
    #expect(button.isEnabled)
    button.performClick(nil)
    while service.state().items.first?.pendingVersion == nil, ContinuousClock.now < deadline { await Task.yield() }
    // Wait for the completion label after registry refresh.
    while status.stringValue != catalog.text("Plugin Update Will Apply Next Launch"), ContinuousClock.now < deadline { await Task.yield() }
    #expect(service.state().items.first?.manifest.version == old.manifest.version)
    #expect(service.state().items.first?.pendingVersion == new.manifest.version)
    #expect(!button.isEnabled)
    #expect(status.stringValue == catalog.text("Plugin Update Will Apply Next Launch"))
    withExtendedLifetime(updater) {}
}
