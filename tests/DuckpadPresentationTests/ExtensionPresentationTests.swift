import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
@testable import DuckpadPresentation
import Foundation
import Testing

private actor PresentationExtensionLoader: ExtensionPackageLoaderPort {
    let packages: [LoadedExtensionPackage]
    init(_ package: LoadedExtensionPackage) { packages = [package] }
    init(_ packages: [LoadedExtensionPackage]) { self.packages = packages }
    func discover() async -> ExtensionDiscoveryReport { .init(packages: packages) }
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
    secondShortcut: String? = nil
) -> LoadedExtensionPackage {
    let id = ExtensionID(rawValue: rawID)
    let commandID = ExtensionCommandID(rawValue: rawCommandID)
    let requests = [ExtensionCapabilityRequest(id: .documentsRead, scope: .selection), ExtensionCapabilityRequest(id: .documentsWrite, scope: .selection)]
    var commands = [ExtensionCommandContribution(
        id: commandID, title: title, operation: 1, inputScope: .selection
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
        manifest: .init(id: id, name: "Sample", version: .init(major: 1, minor: 2, patch: 3),
            api: .init(minimum: .init(major: 1, minor: 0, patch: 0), maximumExclusive: .init(major: 2, minor: 0, patch: 0)),
            publisher: .init(id: "com.duckpad", keyID: "sample"), runtime: .init(kind: "wasm-core", module: "module.wasm", abi: "duckpad-wasm-1"),
            capabilities: requests, contributes: .init(
                commands: commands,
                keybindings: keybindings
            )),
        module: Data(), packageDigest: String(repeating: digestCharacter, count: 64), publisherFingerprint: String(repeating: "2", count: 64),
        signatureDigest: String(repeating: "3", count: 64), capabilitySchemaDigest: String(repeating: "4", count: 64), trustSource: .bundled
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
            .first(where: { $0.title == "Extensions" })?
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
    let extensions = try #require(menu.items.compactMap(\.submenu).first(where: { $0.title == "Extensions" }))
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
                .first(where: { $0.title == "Extensions" })?
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
