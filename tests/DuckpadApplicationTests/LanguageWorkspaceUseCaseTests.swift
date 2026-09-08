import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
import Testing

@MainActor
private final class LanguageEditorFake: LanguageEditorPort {
    var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)?
    var prefix = Data()
    var supported = Set<String>()
    var applications: [EditorLanguageConfiguration] = []
    var themes: [EditorThemePalette] = []
    var applyLanguageResult = true
    var canToggleBlockComment = false
    var blockCommentInvocations = 0
    var blockCommentOutcome: EditorEditOutcome = .accepted(newRevision: 1)
    var activeLanguageID: LanguageID { applications.last?.languageID ?? .plainText }
    var isLanguageStylingFallback = false
    var activeDocumentByteLength = 0
    func display(_ buffer: EditorBufferDescriptor) {}
    func install(_ snapshot: EditorTextSnapshot) {}
    func snapshot(for bufferID: BufferID) -> EditorTextSnapshot? { nil }
    func retire(bufferID: BufferID) {}
    func setInputEnabled(_ isEnabled: Bool) {}
    func focus() {}
    func recoverySnapshot(for bufferID: BufferID) -> EditorRecoverySnapshot? { nil }
    func recoveryCapture(for bufferID: BufferID) -> EditorRecoveryCapture? { nil }
    func acknowledgeRecoverySnapshot(_ snapshot: EditorRecoverySnapshot) {}
    func installRecovery(_ snapshot: EditorRecoverySnapshot) {}
    func detectionPrefix(maximumBytes: Int) -> Data { Data(prefix.prefix(maximumBytes)) }
    func supportsLexer(named name: String) -> Bool { supported.contains(name) }
    func applyLanguage(_ configuration: EditorLanguageConfiguration) -> Bool {
        guard applyLanguageResult else { return false }
        applications.append(configuration); return true
    }
    func applyTheme(_ palette: EditorThemePalette) { themes.append(palette) }
    func toggleLineComment(prefix: String) -> EditorEditOutcome { .accepted(newRevision: 1) }
    func toggleBlockComment() -> EditorEditOutcome {
        blockCommentInvocations += 1
        return blockCommentOutcome
    }
}

@Test @MainActor
func manualLanguageOverridePersistsAndAutoRedetectsAfterSaveAs() async throws {
    let registry = try LanguageManifestLoader().loadBundled()
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
    #expect(await workspace.start() == .saved)
    let editor = LanguageEditorFake()
    editor.supported = Set(registry.definitions.map(\.lexerName))
    editor.prefix = Data("#!/usr/bin/env python3\nprint('duck')".utf8)
    let service = LanguageWorkspaceUseCase(registry: registry, workspace: workspace, editor: editor)
    #expect(service.validateRegistry())
    guard case .ready(let automatic, _) = service.refreshActive() else {
        Issue.record("automatic language did not become ready"); return
    }
    #expect(automatic.languageID.rawValue == "python")
    let tabID = try #require(workspace.activeLanguageContext()?.tabID)
    #expect(await service.setOverride(.manual(LanguageID(rawValue: "swift"))) == .applied(.saved))
    #expect(try workspace.recoverySession().languageOverride(for: tabID) == .manual(LanguageID(rawValue: "swift")))

    let path = "/tmp/DuckpadLanguageTests/sample.py"
    let identity = FileIdentity(canonicalPath: path, device: 1, inode: 2, byteCount: 0, modifiedNanoseconds: 0, contentToken: "empty")
    let binding = FileBinding(canonicalPath: path, encoding: .utf8, byteOrderMark: .absent, lineEnding: .lf, observedIdentity: identity)
    #expect(await workspace.bindSavedFile(tabID: tabID, binding: binding, title: "sample.py", savedRevision: 0) == .applied(.saved))
    #expect(try workspace.recoverySession().languageOverride(for: tabID) == .manual(LanguageID(rawValue: "swift")))
    #expect(await service.setOverride(.automatic) == .applied(.saved))
    guard case .ready(let detected, _) = service.state else { Issue.record("auto reset failed"); return }
    #expect(detected.languageID.rawValue == "python")
}

@Test @MainActor
func unresolvedLexerAndBrokenPackagingStayVisiblyDegraded() throws {
    let registry = try LanguageManifestLoader().loadBundled()
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
    let editor = LanguageEditorFake()
    editor.supported = ["null"]
    let unresolved = LanguageWorkspaceUseCase(registry: registry, workspace: workspace, editor: editor)
    #expect(!unresolved.validateRegistry())
    guard case .degraded(let reason) = unresolved.state else { Issue.record("must degrade"); return }
    #expect(reason.contains("Unavailable Lexilla"))

    let packaged = LanguageWorkspaceUseCase(
        registry: LanguageManifestLoader.fallbackRegistry,
        workspace: workspace, editor: editor,
        configurationIssue: "manifest missing"
    )
    #expect(!packaged.validateRegistry())
    #expect(packaged.state == .degraded("manifest missing"))
}

@Test @MainActor
func recoveredUnavailableManualLanguageUsesPlainLexerUntilExplicitAutoReset() async throws {
    let missingID = LanguageID(rawValue: "removed-language")
    var restored = ScratchSession()
    let tabID = restored.addUntitled()
    try restored.setLanguageOverride(.manual(missingID), for: tabID)
    let store = InMemorySessionStore(session: restored)
    let workspace = ScratchWorkspaceUseCase(store: store)
    #expect(await workspace.start() == .saved)

    let registry = try LanguageManifestLoader().loadBundled()
    let editor = LanguageEditorFake()
    editor.supported = Set(registry.definitions.map(\.lexerName))
    editor.prefix = Data("#!/usr/bin/env python3\nprint('duck')".utf8)
    let service = LanguageWorkspaceUseCase(
        registry: registry,
        workspace: workspace,
        editor: editor
    )

    #expect(service.validateAndRefresh() == .unavailableManual(
        requestedID: missingID,
        fallback: .plainText
    ))
    #expect(editor.applications.last?.languageID == .plainText)
    #expect(editor.applications.last?.lexerName == "null")
    #expect(try workspace.recoverySession().languageOverride(for: tabID) == .manual(missingID))
    let before = workspace.snapshot().activeBuffer

    #expect(await service.setOverride(.automatic) == .applied(.saved))
    guard case .ready(let detection, _) = service.state else {
        Issue.record("explicit Auto did not restore available detection")
        return
    }
    #expect(detection.languageID.rawValue == "python")
    #expect(workspace.snapshot().activeBuffer == before)
    #expect(try workspace.recoverySession().languageOverride(for: tabID) == .automatic)
}

@Test @MainActor
func languageConfigurationIsNoOpUntilStyleBudgetBoundaryChanges() async throws {
    let registry = try LanguageManifestLoader().loadBundled()
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
    #expect(await workspace.start() == .saved)
    let editor = LanguageEditorFake()
    editor.supported = Set(registry.definitions.map(\.lexerName))
    editor.prefix = Data("int main() {}".utf8)
    editor.activeDocumentByteLength = 500
    let service = LanguageWorkspaceUseCase(
        registry: registry, workspace: workspace, editor: editor,
        maximumStyleBytes: 1_024
    )
    #expect(service.validateRegistry())
    _ = service.refreshActive()
    let initialCount = editor.applications.count
    for _ in 0..<1_000 { _ = service.refreshActive() }
    #expect(editor.applications.count == initialCount)
    editor.activeDocumentByteLength = 2_000
    _ = service.refreshActive()
    #expect(editor.applications.count == initialCount + 1)
    editor.activeDocumentByteLength = 500
    _ = service.refreshActive()
    #expect(editor.applications.count == initialCount + 2)
}

@Test @MainActor
func appliedConfigurationCarriesTheDetectedCommentSyntax() async throws {
    let registry = try LanguageManifestLoader().loadBundled()
    let fixtures = [
        (filename: "sample.c", prefix: "#include <stdio.h>", languageID: LanguageID(rawValue: "c")),
        (filename: "sample.html", prefix: "<!doctype html><html></html>", languageID: LanguageID(rawValue: "html")),
        (filename: "plain.unknown", prefix: "plain note", languageID: .plainText),
    ]

    for (index, fixture) in fixtures.enumerated() {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        #expect(await workspace.start() == .saved)
        let tabID = try #require(workspace.activeLanguageContext()?.tabID)
        let path = "/tmp/DuckpadLanguageTests/\(fixture.filename)"
        let identity = FileIdentity(
            canonicalPath: path,
            device: 1,
            inode: UInt64(index + 1),
            byteCount: 0,
            modifiedNanoseconds: 0,
            contentToken: "empty"
        )
        let binding = FileBinding(
            canonicalPath: path,
            encoding: .utf8,
            byteOrderMark: .absent,
            lineEnding: .lf,
            observedIdentity: identity
        )
        #expect(await workspace.bindSavedFile(
            tabID: tabID,
            binding: binding,
            title: fixture.filename,
            savedRevision: 0
        ) == .applied(.saved))
        let editor = LanguageEditorFake()
        editor.supported = Set(registry.definitions.map(\.lexerName))
        editor.prefix = Data(fixture.prefix.utf8)
        let service = LanguageWorkspaceUseCase(registry: registry, workspace: workspace, editor: editor)

        #expect(service.validateRegistry())
        guard case .ready(let detection, _) = service.refreshActive() else {
            Issue.record("\(fixture.languageID.rawValue) did not become ready")
            continue
        }
        #expect(detection.languageID == fixture.languageID)
        #expect(editor.applications.last?.comments == registry[fixture.languageID]?.capabilities.comments)
    }
}

@Test @MainActor
func blockCommentRoutesOnlyWhenLanguageStateIsReadyAndEditorIsCapable() async throws {
    let registry = try LanguageManifestLoader().loadBundled()
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
    #expect(await workspace.start() == .saved)
    let editor = LanguageEditorFake()
    editor.supported = Set(registry.definitions.map(\.lexerName))
    editor.prefix = Data("#include <stdio.h>".utf8)
    editor.blockCommentOutcome = .accepted(newRevision: 7)
    let service = LanguageWorkspaceUseCase(registry: registry, workspace: workspace, editor: editor)

    #expect(service.toggleBlockComment() == nil)
    #expect(editor.blockCommentInvocations == 0)
    #expect(service.validateRegistry())
    _ = service.refreshActive()
    #expect(service.toggleBlockComment() == nil)
    #expect(editor.blockCommentInvocations == 0)

    editor.canToggleBlockComment = true
    #expect(service.toggleBlockComment() == .accepted(newRevision: 7))
    #expect(editor.blockCommentInvocations == 1)
}

@Test @MainActor
func blockCommentUseCaseDoesNotResolveOrPassDelimiters() async throws {
    let registry = try LanguageManifestLoader().loadBundled()
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
    #expect(await workspace.start() == .saved)
    let editor = LanguageEditorFake()
    editor.supported = Set(registry.definitions.map(\.lexerName))
    editor.prefix = Data("#include <stdio.h>".utf8)
    editor.canToggleBlockComment = true
    editor.blockCommentOutcome = .rejected(currentRevision: 4)
    let service = LanguageWorkspaceUseCase(registry: registry, workspace: workspace, editor: editor)

    #expect(service.validateRegistry())
    _ = service.refreshActive()
    #expect(service.toggleBlockComment() == .rejected(currentRevision: 4))
    #expect(editor.blockCommentInvocations == 1)
}

@Test @MainActor
func failedLanguageApplicationDoesNotPublishReadyCommentCapability() async throws {
    let registry = try LanguageManifestLoader().loadBundled()
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
    #expect(await workspace.start() == .saved)
    let editor = LanguageEditorFake()
    editor.supported = Set(registry.definitions.map(\.lexerName))
    editor.prefix = Data("#include <stdio.h>".utf8)
    editor.canToggleBlockComment = true
    let service = LanguageWorkspaceUseCase(registry: registry, workspace: workspace, editor: editor)

    #expect(service.validateRegistry())
    _ = service.refreshActive()
    let previousConfiguration = try #require(editor.applications.last)
    editor.applyLanguageResult = false
    #expect(await service.setOverride(.manual(LanguageID(rawValue: "html"))) == .applied(.saved))
    #expect(editor.applications.last == previousConfiguration)
    #expect(editor.canToggleBlockComment)
    guard case .degraded = service.state else {
        Issue.record("failed application must degrade the service")
        return
    }
    #expect(service.toggleBlockComment() == nil)
    #expect(editor.blockCommentInvocations == 0)
}
