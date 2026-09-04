import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
import Testing

private actor ExtensionLoaderFake: ExtensionPackageLoaderPort {
    var packages: [LoadedExtensionPackage]
    init(_ packages: [LoadedExtensionPackage]) { self.packages = packages }
    func discover() async -> ExtensionDiscoveryReport { ExtensionDiscoveryReport(packages: packages) }
    func replace(_ packages: [LoadedExtensionPackage]) { self.packages = packages }
}

private actor ExtensionPolicyFake: ExtensionGrantStorePort {
    var policy: ExtensionPolicySnapshot
    var saved: [ExtensionPolicySnapshot] = []
    var uncertain = false
    init(_ policy: ExtensionPolicySnapshot = ExtensionPolicySnapshot()) { self.policy = policy }
    func loadPolicy() async throws -> ExtensionPolicySnapshot { policy }
    func savePolicy(_ policy: ExtensionPolicySnapshot) async throws -> ExtensionPolicyCommit {
        saved.append(policy); self.policy = policy
        return uncertain ? .durabilityUncertain : .committed
    }
    func setUncertain(_ value: Bool = true) { uncertain = value }
}

private actor ExtensionTransportFake: PluginHostTransport {
    var requests: [ExtensionHostRequest] = []
    var response = ExtensionHostResponse(result: ExtensionCommandResult(edits: []))
    var isBlocked = false
    var release = false
    var cancelled: [UUID] = []
    func invoke(_ request: ExtensionHostRequest) async throws -> ExtensionHostResponse {
        requests.append(request)
        while isBlocked && !release { try await Task.sleep(for: .milliseconds(1)) }
        if cancelled.contains(request.requestID) { throw ExtensionFailure.cancelled }
        return response
    }
    func cancel(requestID: UUID) async { cancelled.append(requestID); release = true }
    func setResponse(_ value: ExtensionHostResponse) { response = value }
    func block() { isBlocked = true }
    func unblock() { release = true }
    func lastRequest() -> ExtensionHostRequest? { requests.last }
    func requestCount() -> Int { requests.count }
}

private actor ExtensionBlockingSessionStore: SessionStore {
    private var stored: StoredSession?
    private var shouldBlock = false
    private var entered = false
    private var released = false

    func loadSession() async throws(SessionStoreError) -> StoredSession? { stored }
    func commitSession(_ session: ScratchSession, generation: PersistenceGeneration) async throws(SessionStoreError) -> SessionCommitResult {
        if shouldBlock {
            shouldBlock = false; entered = true
            while !released { await Task.yield() }
        }
        if let stored, generation <= stored.generation { return .superseded(durableGeneration: stored.generation) }
        stored = .init(session: session, generation: generation)
        return .committed
    }
    func blockNextCommit() { shouldBlock = true; entered = false; released = false }
    func waitUntilEntered() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !entered && ContinuousClock.now < deadline { await Task.yield() }
    }
    func didEnter() -> Bool { entered }
    func release() { released = true }
}

private actor ExtensionCompletionFlag {
    private var completed = false
    func markCompleted() { completed = true }
    func value() -> Bool { completed }
}

@MainActor
private final class ExtensionEditorFake: ExtensionEditorPort {
    var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)?
    var descriptor: EditorBufferDescriptor
    var text: String
    var selection: SearchUTF8Range?
    var batchCount = 0
    var documentCaptureCount = 0
    var selectionCaptureCount = 0
    var snapshotCallCount = 0
    var virtualDocumentByteLength: Int?
    init(_ descriptor: EditorBufferDescriptor, text: String, selection: SearchUTF8Range? = nil) {
        self.descriptor = descriptor; self.text = text; self.selection = selection
    }
    func display(_ buffer: EditorBufferDescriptor) { descriptor = buffer }
    func install(_ snapshot: EditorTextSnapshot) { descriptor = .init(bufferID: snapshot.bufferID, revision: snapshot.revision); text = snapshot.text }
    func snapshot(for bufferID: BufferID) -> EditorTextSnapshot? {
        snapshotCallCount += 1
        return bufferID == descriptor.bufferID
            ? EditorTextSnapshot(bufferID: bufferID, revision: descriptor.revision, text: text)
            : nil
    }
    func retire(bufferID: BufferID) {}
    func setInputEnabled(_ isEnabled: Bool) {}
    func focus() {}
    func recoverySnapshot(for bufferID: BufferID) -> EditorRecoverySnapshot? { nil }
    func recoveryCapture(for bufferID: BufferID) -> EditorRecoveryCapture? { nil }
    func acknowledgeRecoverySnapshot(_ snapshot: EditorRecoverySnapshot) {}
    func installRecovery(_ snapshot: EditorRecoverySnapshot) {}
    func activeSelectionUTF8Range() -> SearchUTF8Range? { selection }
    func captureExtensionInput(tabID: TabID, expectedBuffer: EditorBufferDescriptor, scope: ExtensionCommandContribution.InputScope, maximumBytes: Int) throws(ExtensionFailure) -> ExtensionEditorCapture {
        guard descriptor == expectedBuffer else { throw .staleContext }
        let actualDocument = Data(text.utf8)
        let documentLength = virtualDocumentByteLength ?? actualDocument.count
        let selected = selection ?? .init(location: 0, length: 0)
        guard selected.location >= 0, selected.length >= 0, selected.location <= documentLength,
              selected.length <= documentLength - selected.location else { throw .staleContext }
        let bytes: Data
        switch scope {
        case .selection:
            selectionCaptureCount += 1
            guard selected.length > 0 else { throw .invalidResult("command requires a selection") }
            guard selected.length <= maximumBytes else { throw .limitExceeded("command input") }
            bytes = actualDocument.subdata(in: selected.location..<(selected.location + selected.length))
        case .document:
            guard documentLength <= maximumBytes else { throw .limitExceeded("command input") }
            documentCaptureCount += 1; bytes = actualDocument
        }
        return .init(tabID: tabID, buffer: descriptor, documentByteLength: documentLength, selection: selected, scopedUTF8: bytes)
    }
    func findActive(_ request: ActiveSearchRequest) throws(SearchFailure) -> SearchUTF8Range? { nil }
    func selectAndReveal(_ range: SearchUTF8Range) { selection = range }
    func replaceActive(range: SearchUTF8Range, with replacementUTF8: Data, expectedRevision: UInt64) -> EditorEditOutcome { .rejected(currentRevision: descriptor.revision) }
    func replaceActiveBatch(_ edits: [SearchReplacementEdit], expectedRevision: UInt64, accept: ([EditorIncrementalEdit]) -> EditorEditOutcome) -> EditorEditOutcome {
        guard expectedRevision == descriptor.revision else { return .rejected(currentRevision: descriptor.revision) }
        let bytes = Data(text.utf8)
        var candidate = bytes
        var appEdits: [EditorIncrementalEdit] = []
        var revision = expectedRevision
        for edit in edits {
            guard revision < .max else { return .rejected(currentRevision: revision) }
            let replacement = String(decoding: edit.replacementUTF8, as: UTF8.self)
            candidate.replaceSubrange(edit.range.location..<(edit.range.location + edit.range.length), with: edit.replacementUTF8)
            appEdits.append(.init(bufferID: descriptor.bufferID, expectedRevision: revision,
                                  range: .init(location: edit.range.location, length: edit.range.length), replacement: replacement))
            revision += 1
        }
        let outcome = accept(appEdits)
        if case .accepted(let newRevision) = outcome {
            text = String(decoding: candidate, as: UTF8.self); descriptor = .init(bufferID: descriptor.bufferID, revision: newRevision); batchCount += 1
        }
        return outcome
    }
}

private func extensionPackage(
    trust: LoadedExtensionPackage.TrustSource = .userImported,
    digest: String = String(repeating: "a", count: 64),
    version: SemanticVersion = .init(major: 1, minor: 0, patch: 0),
    inputScope: ExtensionCommandContribution.InputScope = .selection,
    keybindings: [ExtensionKeybindingContribution] = []
) -> LoadedExtensionPackage {
    let id = ExtensionID(rawValue: "com.example.tools")
    let capabilityScope: ExtensionCapabilityScope = inputScope == .selection ? .selection : .activeDocument
    let capabilities = [
        ExtensionCapabilityRequest(id: .documentsRead, scope: capabilityScope),
        ExtensionCapabilityRequest(id: .documentsWrite, scope: capabilityScope),
    ]
    return LoadedExtensionPackage(
        manifest: ExtensionManifest(id: id, name: "Example Tools", version: version,
            api: .init(minimum: .init(major: 1, minor: 0, patch: 0), maximumExclusive: .init(major: 2, minor: 0, patch: 0)),
            publisher: .init(id: "com.example", keyID: "one"), runtime: .init(kind: "wasm-core", module: "module.wasm", abi: "duckpad-wasm-1"),
            capabilities: capabilities, contributes: .init(
                commands: [
                    .init(id: .init(rawValue: "com.example.tools.sort"), title: "Sort", operation: 7, inputScope: inputScope)
                ],
                keybindings: keybindings
            )),
        module: Data([0]), packageDigest: digest, publisherFingerprint: String(repeating: "b", count: 64),
        signatureDigest: String(repeating: "c", count: 64), capabilitySchemaDigest: String(repeating: "d", count: 64), trustSource: trust
    )
}

@Test @MainActor
func duplicateOrNonCanonicalExtensionKeybindingsRejectThePackage() async {
    let command = ExtensionCommandID(rawValue: "com.example.tools.sort")
    for bindings in [
        [
            ExtensionKeybindingContribution(command: command, key: "cmd+k"),
            ExtensionKeybindingContribution(command: command, key: "cmd+l"),
        ],
        [ExtensionKeybindingContribution(command: command, key: " cmd+k ")],
    ] {
        let package = extensionPackage(keybindings: bindings)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        _ = await workspace.start()
        let editor = ExtensionEditorFake(workspace.snapshot().activeBuffer!, text: "")
        let service = ExtensionWorkspaceUseCase(
            loader: ExtensionLoaderFake([package]),
            grants: ExtensionPolicyFake(),
            transport: ExtensionTransportFake(),
            workspace: workspace,
            editor: editor,
            allowsUserExtensions: true
        )

        await service.refresh()

        #expect(service.state().items.isEmpty)
        #expect(service.state().discoveryFailures[package.manifest.id.rawValue] ==
            .malformedManifest("duplicate, unowned, or non-canonical keybinding"))
    }
}

@Test @MainActor
func fiveHundredMiBDocumentCommandIsRejectedBeforeEditorMaterializesContent() async throws {
    let package = extensionPackage(inputScope: .document)
    let (useCase, workspace, editor, _, _, _) = await extensionFixture(package: package)
    editor.virtualDocumentByteLength = 500 * 1_024 * 1_024
    try await useCase.setEnabled(package.manifest.id, enabled: true)
    let token = try useCase.consentReviewToken(for: package.manifest.id)
    try await useCase.grantReviewed(token, choices: token.requests)
    let revision = workspace.snapshot().activeBuffer?.revision
    await #expect(throws: ExtensionFailure.limitExceeded("command input")) {
        _ = try await useCase.invoke(.init(rawValue: "com.example.tools.sort"))
    }
    #expect(editor.documentCaptureCount == 0); #expect(editor.snapshotCallCount == 0)
    #expect(workspace.snapshot().activeBuffer?.revision == revision); #expect(editor.batchCount == 0)
}

@Test @MainActor
func userPackageCannotShadowBundledIdentityEvenAtHigherVersion() async {
    let bundled = extensionPackage(trust: .bundled, digest: String(repeating: "1", count: 64))
    let user = extensionPackage(trust: .userImported, digest: String(repeating: "2", count: 64), version: .init(major: 9, minor: 0, patch: 0))
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore()); _ = await workspace.start()
    let editor = ExtensionEditorFake(workspace.snapshot().activeBuffer!, text: "")
    let service = ExtensionWorkspaceUseCase(loader: ExtensionLoaderFake([user, bundled]), grants: ExtensionPolicyFake(),
        transport: ExtensionTransportFake(), workspace: workspace, editor: editor, allowsUserExtensions: true)
    await service.refresh()
    #expect(service.state().items.map(\.manifest.version) == [SemanticVersion(major: 1, minor: 0, patch: 0)])
}

@MainActor
private func extensionFixture(package: LoadedExtensionPackage = extensionPackage()) async -> (ExtensionWorkspaceUseCase, ScratchWorkspaceUseCase, ExtensionEditorFake, ExtensionLoaderFake, ExtensionPolicyFake, ExtensionTransportFake) {
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore()); _ = await workspace.start()
    let descriptor = workspace.snapshot().activeBuffer!
    let editor = ExtensionEditorFake(descriptor, text: "앞🙂\nz\na\n뒤🙂", selection: .init(location: Data("앞🙂\n".utf8).count, length: 4))
    let loader = ExtensionLoaderFake([package]); let policy = ExtensionPolicyFake(); let transport = ExtensionTransportFake()
    let useCase = ExtensionWorkspaceUseCase(loader: loader, grants: policy, transport: transport, workspace: workspace, editor: editor, allowsUserExtensions: true)
    await useCase.refresh()
    return (useCase, workspace, editor, loader, policy, transport)
}

@Test @MainActor
func consentTokenIsAtomicIdentityBoundAndSelectionPayloadIsLeastPrivilege() async throws {
    let (useCase, workspace, editor, _, _, transport) = await extensionFixture()
    let id = ExtensionID(rawValue: "com.example.tools")
    try await useCase.setEnabled(id, enabled: true)
    let token = try useCase.consentReviewToken(for: id)
    try await useCase.grantReviewed(token, choices: token.requests)
    await transport.setResponse(ExtensionHostResponse(result: ExtensionCommandResult(edits: [
        .init(range: .init(location: editor.selection!.location, length: 4), replacementUTF8: Data("a\nz\n".utf8))
    ])))
    _ = try await useCase.invoke(.init(rawValue: "com.example.tools.sort"))
    let request = try #require(await transport.lastRequest())
    #expect(request.context.inputScope == .selection)
    #expect(String(decoding: request.context.utf8, as: UTF8.self) == "z\na\n")
    #expect(editor.text == "앞🙂\na\nz\n뒤🙂")
    #expect(editor.batchCount == 1)
    #expect(editor.selectionCaptureCount == 1); #expect(editor.snapshotCallCount == 0)
    #expect(workspace.snapshot().activeBuffer?.revision == 1)
}

@Test @MainActor
func selectionResultIsNoOpOrExactCapturedRangeAndNeverEscapesGrant() async throws {
    let (useCase, workspace, editor, _, _, transport) = await extensionFixture()
    let id = ExtensionID(rawValue: "com.example.tools")
    try await useCase.setEnabled(id, enabled: true)
    let token = try useCase.consentReviewToken(for: id); try await useCase.grantReviewed(token, choices: token.requests)
    let original = editor.text; let revision = workspace.snapshot().activeBuffer!.revision

    await transport.setResponse(.init(result: .init(edits: [], status: "already sorted")))
    let noOp = try await useCase.invoke(.init(rawValue: "com.example.tools.sort"))
    #expect(noOp.edits.isEmpty); #expect(editor.text == original); #expect(workspace.snapshot().activeBuffer?.revision == revision)

    let escaped: [[ExtensionTextEdit]] = [
        [.init(range: .init(location: 0, length: 1), replacementUTF8: Data("x".utf8))],
        [.init(range: .init(location: 12, length: 1), replacementUTF8: Data("x".utf8))],
        [.init(range: .init(location: 7, length: 2), replacementUTF8: Data("x".utf8))],
        [.init(range: .init(location: 8, length: 4), replacementUTF8: Data("x".utf8)),
         .init(range: .init(location: 9, length: 1), replacementUTF8: Data("y".utf8))],
    ]
    for edits in escaped {
        await transport.setResponse(.init(result: .init(edits: edits)))
        await #expect(throws: ExtensionFailure.invalidResult("selection transform must return exactly one edit equal to the captured selection")) {
            _ = try await useCase.invoke(.init(rawValue: "com.example.tools.sort"))
        }
        #expect(editor.text == original); #expect(workspace.snapshot().activeBuffer?.revision == revision); #expect(editor.batchCount == 0)
    }
}

@Test @MainActor
func staleConsentAndOverlappingResultFailWithoutMutation() async throws {
    let (useCase, workspace, editor, _, _, transport) = await extensionFixture()
    let id = ExtensionID(rawValue: "com.example.tools")
    try await useCase.setEnabled(id, enabled: true)
    let stale = try useCase.consentReviewToken(for: id)
    try await useCase.grantReviewed(stale, choices: stale.requests)
    await #expect(throws: ExtensionFailure.staleContext) { try await useCase.grantReviewed(stale, choices: stale.requests) }
    await transport.setResponse(ExtensionHostResponse(result: ExtensionCommandResult(edits: [
        .init(range: .init(location: 8, length: 1), replacementUTF8: Data("x".utf8)),
        .init(range: .init(location: 8, length: 0), replacementUTF8: Data("y".utf8)),
    ])))
    let before = (editor.text, workspace.snapshot().activeBuffer)
    await #expect(throws: (any Error).self) { _ = try await useCase.invoke(.init(rawValue: "com.example.tools.sort")) }
    #expect(editor.text == before.0); #expect(workspace.snapshot().activeBuffer == before.1); #expect(editor.batchCount == 0)
}

@Test @MainActor
func durableDisableAndPublisherRevocationSurviveRefreshAndRequireDeliberateReset() async throws {
    let package = extensionPackage(trust: .bundled)
    let (useCase, _, _, _, policy, _) = await extensionFixture(package: package)
    let id = package.manifest.id
    #expect(useCase.state().items.first?.enabled == true)
    try await useCase.setEnabled(id, enabled: false)
    await useCase.refresh()
    #expect(useCase.state().items.first?.enabled == false)
    try await useCase.setEnabled(id, enabled: true)
    let revoke = try useCase.revocationReviewToken(for: id)
    try await useCase.revokePublisher(revoke)
    await useCase.refresh()
    #expect(useCase.state().items.first?.issue == .untrustedPublisher)
    await #expect(throws: ExtensionFailure.untrustedPublisher) { try await useCase.setEnabled(id, enabled: true) }
    try await useCase.resetPublisherRevocation(for: id)
    #expect(useCase.state().items.first?.enabled == false)
    #expect(useCase.state().items.first?.granted.isEmpty == true)
    #expect((await policy.policy).revokedPublisherFingerprints.isEmpty)
}

@Test @MainActor
func concurrentInvokeCannotLoseFirstRequestAndCancelIsRequestScoped() async throws {
    let (useCase, _, _, _, _, transport) = await extensionFixture()
    let id = ExtensionID(rawValue: "com.example.tools")
    try await useCase.setEnabled(id, enabled: true)
    let token = try useCase.consentReviewToken(for: id); try await useCase.grantReviewed(token, choices: token.requests)
    await transport.block()
    let first = Task { try await useCase.invoke(.init(rawValue: "com.example.tools.sort")) }
    while await transport.requestCount() == 0 { await Task.yield() }
    await #expect(throws: ExtensionFailure.busy) { _ = try await useCase.invoke(.init(rawValue: "com.example.tools.sort")) }
    await useCase.cancelInvocation()
    await #expect(throws: ExtensionFailure.cancelled) { _ = try await first.value }
    #expect(await transport.cancelled.count == 1)
}

@Test @MainActor
func uncertainPolicyCommitLatchesUserAuthorityOffUntilNewProcessState() async throws {
    let package = extensionPackage()
    let (useCase, workspace, editor, loader, policy, transport) = await extensionFixture(package: package)
    await policy.setUncertain()

    await #expect(throws: ExtensionFailure.hostUnavailable("extension policy durability uncertain")) {
        try await useCase.setEnabled(package.manifest.id, enabled: true)
    }
    #expect(useCase.state().items.first?.enabled == false)
    #expect(useCase.state().discoveryFailures["preferences"] == .hostUnavailable("policy durability uncertain; user extensions disabled until restart"))

    await policy.setUncertain(false)
    await useCase.refresh()
    #expect(useCase.state().items.first?.enabled == false)
    await #expect(throws: ExtensionFailure.hostUnavailable("extension policy durability uncertain; restart required")) {
        try await useCase.setEnabled(package.manifest.id, enabled: true)
    }
    await #expect(throws: ExtensionFailure.hostUnavailable("extension policy durability uncertain; restart required")) {
        _ = try await useCase.invoke(.init(rawValue: "com.example.tools.sort"))
    }

    let restarted = ExtensionWorkspaceUseCase(
        loader: loader, grants: policy, transport: transport,
        workspace: workspace, editor: editor, allowsUserExtensions: true
    )
    await restarted.refresh()
    #expect(restarted.state().items.first?.enabled == true)
}

@Test @MainActor
func terminationSuspensionWaitsUntilIdleAndBlocksNewInvocation() async throws {
    let (useCase, _, _, _, _, transport) = await extensionFixture()
    let id = ExtensionID(rawValue: "com.example.tools")
    try await useCase.setEnabled(id, enabled: true)
    let token = try useCase.consentReviewToken(for: id)
    try await useCase.grantReviewed(token, choices: token.requests)
    await transport.block()

    let invocation = Task { try await useCase.invoke(.init(rawValue: "com.example.tools.sort")) }
    while await transport.requestCount() == 0 { await Task.yield() }
    await useCase.suspendInvocationsAndWait()
    await #expect(throws: ExtensionFailure.cancelled) { _ = try await invocation.value }

    await #expect(throws: ExtensionFailure.cancelled) {
        _ = try await useCase.invoke(.init(rawValue: "com.example.tools.sort"))
    }
    useCase.resumeInvocations()
    await transport.setResponse(.init(result: .init(edits: [])))
    _ = try await useCase.invoke(.init(rawValue: "com.example.tools.sort"))
    #expect(await transport.requestCount() == 2)
}

@Test @MainActor
func terminationSuspensionJoinsInvocationHeldAtWorkspaceReservation() async throws {
    let store = ExtensionBlockingSessionStore()
    let workspace = ScratchWorkspaceUseCase(store: store)
    _ = await workspace.start()
    let descriptor = workspace.snapshot().activeBuffer!
    let editor = ExtensionEditorFake(descriptor, text: "앞🙂\nz\na\n뒤🙂", selection: .init(location: 8, length: 4))
    let package = extensionPackage()
    let policy = ExtensionPolicyFake()
    let transport = ExtensionTransportFake()
    let useCase = ExtensionWorkspaceUseCase(
        loader: ExtensionLoaderFake([package]), grants: policy, transport: transport,
        workspace: workspace, editor: editor, allowsUserExtensions: true
    )
    await useCase.refresh()
    try await useCase.setEnabled(package.manifest.id, enabled: true)
    let consent = try useCase.consentReviewToken(for: package.manifest.id)
    try await useCase.grantReviewed(consent, choices: consent.requests)
    await transport.setResponse(.init(result: .init(edits: [
        .init(range: .init(location: 8, length: 4), replacementUTF8: Data("a\nz\n".utf8))
    ])))

    await store.blockNextCommit()
    let holder = Task { await workspace.flushPersistence() }
    await store.waitUntilEntered()
    let invocation = Task { try await useCase.invoke(.init(rawValue: "com.example.tools.sort")) }
    while await transport.requestCount() == 0 { await Task.yield() }
    await Task.yield()

    let completion = ExtensionCompletionFlag()
    let barrier = Task {
        await useCase.suspendInvocationsAndWait()
        await completion.markCompleted()
    }
    await Task.yield()
    #expect(await completion.value() == false)
    await store.release()
    _ = await holder.value
    await barrier.value
    #expect(await completion.value())
    await #expect(throws: ExtensionFailure.cancelled) { _ = try await invocation.value }
    #expect(editor.text == "앞🙂\nz\na\n뒤🙂")
    #expect(editor.batchCount == 0)
    #expect(workspace.snapshot().activeBuffer?.revision == descriptor.revision)
}

@Test @MainActor
func disablingDuringInvocationCancelsExactRequestAndSuppressesLateMutation() async throws {
    let (useCase, workspace, editor, _, _, transport) = await extensionFixture()
    let id = ExtensionID(rawValue: "com.example.tools")
    try await useCase.setEnabled(id, enabled: true)
    let token = try useCase.consentReviewToken(for: id); try await useCase.grantReviewed(token, choices: token.requests)
    await transport.setResponse(ExtensionHostResponse(result: ExtensionCommandResult(edits: [
        .init(range: .init(location: 8, length: 4), replacementUTF8: Data("a\nz\n".utf8))
    ])))
    await transport.block()
    let before = (editor.text, workspace.snapshot().activeBuffer)
    let task = Task { try await useCase.invoke(.init(rawValue: "com.example.tools.sort")) }
    while await transport.requestCount() == 0 { await Task.yield() }
    try await useCase.setEnabled(id, enabled: false)
    await #expect(throws: ExtensionFailure.cancelled) { _ = try await task.value }
    #expect(editor.text == before.0); #expect(workspace.snapshot().activeBuffer == before.1); #expect(editor.batchCount == 0)
}

@Test @MainActor
func tabSwitchDuringHostAwaitRejectsStaleResultWithoutReservingOrMutating() async throws {
    let (useCase, workspace, editor, _, _, transport) = await extensionFixture()
    let id = ExtensionID(rawValue: "com.example.tools")
    try await useCase.setEnabled(id, enabled: true)
    let token = try useCase.consentReviewToken(for: id); try await useCase.grantReviewed(token, choices: token.requests)
    await transport.setResponse(ExtensionHostResponse(result: ExtensionCommandResult(edits: [
        .init(range: .init(location: 8, length: 4), replacementUTF8: Data("a\nz\n".utf8))
    ])))
    await transport.block()
    let before = editor.text
    let task = Task { try await useCase.invoke(.init(rawValue: "com.example.tools.sort")) }
    while await transport.requestCount() == 0 { await Task.yield() }
    _ = await workspace.addScratch()
    await transport.unblock()
    await #expect(throws: ExtensionFailure.staleContext) { _ = try await task.value }
    #expect(editor.text == before); #expect(editor.batchCount == 0)
}

@Test @MainActor
func heldWorkspaceTransactionRejectsLateMutationAfterEveryAuthorityWithdrawal() async throws {
    enum Withdrawal: CaseIterable { case cancel, disable, revoke, removeWriteGrant }
    for withdrawal in Withdrawal.allCases {
        let store = ExtensionBlockingSessionStore()
        let workspace = ScratchWorkspaceUseCase(store: store); _ = await workspace.start()
        let descriptor = workspace.snapshot().activeBuffer!
        let editor = ExtensionEditorFake(descriptor, text: "앞🙂\nz\na\n뒤🙂", selection: .init(location: 8, length: 4))
        let package = extensionPackage(); let loader = ExtensionLoaderFake([package])
        let policy = ExtensionPolicyFake(); let transport = ExtensionTransportFake()
        let useCase = ExtensionWorkspaceUseCase(loader: loader, grants: policy, transport: transport, workspace: workspace, editor: editor, allowsUserExtensions: true)
        await useCase.refresh(); try await useCase.setEnabled(package.manifest.id, enabled: true)
        let consent = try useCase.consentReviewToken(for: package.manifest.id)
        try await useCase.grantReviewed(consent, choices: consent.requests)
        await transport.setResponse(.init(result: .init(edits: [
            .init(range: .init(location: 8, length: 4), replacementUTF8: Data("a\nz\n".utf8))
        ])))

        await store.blockNextCommit()
        let holder = Task { await workspace.flushPersistence() }
        await store.waitUntilEntered(); #expect(await store.didEnter())
        let invocation = Task { try await useCase.invoke(.init(rawValue: "com.example.tools.sort")) }
        let deadline = ContinuousClock.now + .seconds(2)
        while await transport.requestCount() == 0 && ContinuousClock.now < deadline { await Task.yield() }
        #expect(await transport.requestCount() == 1)
        await Task.yield()

        switch withdrawal {
        case .cancel: await useCase.cancelInvocation()
        case .disable: try await useCase.setEnabled(package.manifest.id, enabled: false)
        case .revoke: try await useCase.revokePublisher(useCase.revocationReviewToken(for: package.manifest.id))
        case .removeWriteGrant:
            let review = try useCase.consentReviewToken(for: package.manifest.id)
            try await useCase.grantReviewed(review, choices: [.init(id: .documentsRead, scope: .selection)])
        }
        await store.release(); _ = await holder.value
        await #expect(throws: (any Error).self) { _ = try await invocation.value }
        #expect(editor.text == "앞🙂\nz\na\n뒤🙂"); #expect(editor.batchCount == 0)
        #expect(workspace.snapshot().activeBuffer?.revision == descriptor.revision)
        let released = await workspace.reserveEditorBatch(bufferID: descriptor.bufferID, expectedRevision: descriptor.revision, editCount: 1)
        #expect(released != nil)
        if let released { workspace.cancelEditorBatch(released) }
    }
}
