import AppKit
import Darwin
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadPresentation

@MainActor
final class DuckpadAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation,
    DuckpadApplicationCommandTarget {
    private var windowController: DuckpadWindowController?
    private var windowControllers: [ObjectIdentifier: DuckpadWindowController] = [:]
    private var windowEditors: [ObjectIdentifier: ScintillaEditorAdapter] = [:]
    private var windowRecoveryRoots: [ObjectIdentifier: URL] = [:]
    private var settingsWindowController: DuckpadSettingsWindowController?
    private let terminationCoordinator = ApplicationTerminationCoordinator()
    private var environment: [String: String] = [:]
    private var recoveryBase: URL!
    private var fileStore: LocalTextFileStore!
    private var folderSearchStore: LocalFolderSearchFileStore!
    private var workspaceRootStore: LocalWorkspaceRootStore!
    private var extensionLoader: LocalExtensionPackageLoader!
    private var extensionPolicy: LocalExtensionPreferenceStore!
    private var extensionTransport: (any PluginHostTransport)!
    private var languageRegistry: LanguageRegistry!
    private var languageConfigurationIssue: String?
    private var settingsUseCase: AppSettingsUseCase!
    private var pendingFinderOpenRequests: [[URL]] = []
    private var runtimeIsReady = false
    private var systemRecentDocumentReadCount = 0

    private struct WindowRuntime {
        let controller: DuckpadWindowController
        let workspace: ScratchWorkspaceUseCase
        let editor: ScintillaEditorAdapter
        let recoveryUseCase: SessionRecoveryUseCase
        let fileUseCase: FileDocumentUseCase
        let searchUseCase: SearchWorkspaceUseCase
        let workspaceBrowserUseCase: WorkspaceBrowserUseCase
        let languageUseCase: LanguageWorkspaceUseCase
        let documentIntelligenceUseCase: DocumentIntelligenceUseCase
        let extensionUseCase: ExtensionWorkspaceUseCase
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installDevelopmentAppIcon()
        environment = ProcessInfo.processInfo.environment
        let settingsArchive = environment["DUCKPAD_SETTINGS_FILE"].map {
            URL(fileURLWithPath: $0, isDirectory: false)
        } ?? LocalAppSettingsStore.defaultArchiveURL()
        settingsUseCase = AppSettingsUseCase(store: LocalAppSettingsStore(archiveURL: settingsArchive))
        Task { @MainActor [weak self] in
            guard let self else { return }
            let initialSettings = await settingsUseCase.start().settings
            apply(initialSettings)
            finishLaunching()
        }
    }

    private func finishLaunching() {
        let securityScopeSmokeNamespace = environment["DUCKPAD_SECURITY_SCOPE_SMOKE_NAMESPACE"].flatMap {
            $0.range(of: #"^[a-zA-Z0-9-]{1,64}$"#, options: .regularExpression) == nil ? nil : $0
        }
        if let namespace = securityScopeSmokeNamespace {
            recoveryBase = LocalRecoveryStore.defaultRoot().deletingLastPathComponent()
                .appendingPathComponent("SecurityScopeSmoke", isDirectory: true)
                .appendingPathComponent(namespace, isDirectory: true)
        } else {
            recoveryBase = environment["DUCKPAD_RECOVERY_ROOT"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? LocalRecoveryStore.defaultRoot()
        }
        let bookmarkArchive = environment["DUCKPAD_DOCUMENT_BOOKMARKS_FILE"].map {
            URL(fileURLWithPath: $0, isDirectory: false)
        } ?? securityScopeSmokeNamespace.map {
            recoveryBase.deletingLastPathComponent()
                .appendingPathComponent("\($0)-document-bookmarks.json", isDirectory: false)
        } ?? LocalTextFileStore.defaultBookmarkArchiveURL()
        fileStore = LocalTextFileStore(bookmarkArchiveURL: bookmarkArchive)
        folderSearchStore = LocalFolderSearchFileStore()
        let workspaceRootsArchive = environment["DUCKPAD_WORKSPACE_ROOTS_FILE"].map {
            URL(fileURLWithPath: $0, isDirectory: false)
        } ?? LocalWorkspaceRootStore.defaultArchiveURL()
        workspaceRootStore = LocalWorkspaceRootStore(archiveURL: workspaceRootsArchive)
        do {
            languageRegistry = try LanguageManifestLoader().loadBundled()
            languageConfigurationIssue = nil
        } catch {
            languageRegistry = LanguageManifestLoader.fallbackRegistry
            languageConfigurationIssue = "Language registry degraded: \(error)"
        }
        let extensionsRoot = environment["DUCKPAD_EXTENSIONS_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? LocalExtensionPackageLoader.defaultRoot()
        let policyRoot = environment["DUCKPAD_EXTENSION_POLICY_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? LocalExtensionPreferenceStore.defaultRoot()
        extensionLoader = LocalExtensionPackageLoader(root: extensionsRoot)
        extensionPolicy = LocalExtensionPreferenceStore(root: policyRoot)
        if Bundle.main.bundleURL.pathExtension == "app" {
            extensionTransport = XPCPluginHostTransport()
        } else {
            extensionTransport = ProcessPluginHostTransport(
                executableURL: ProcessPluginHostTransport.siblingOfCurrentExecutable()
            )
        }
        let runtime = makeWindowRuntime(recoveryRoot: recoveryBase)
        let controller = runtime.controller
        let workspace = runtime.workspace
        let editor = runtime.editor
        let recoveryUseCase = runtime.recoveryUseCase
        let fileUseCase = runtime.fileUseCase
        let searchUseCase = runtime.searchUseCase
        let workspaceBrowserUseCase = runtime.workspaceBrowserUseCase
        let languageUseCase = runtime.languageUseCase
        let documentIntelligenceUseCase = runtime.documentIntelligenceUseCase
        let extensionUseCase = runtime.extensionUseCase
        windowController = controller
        terminationCoordinator.installApplicationRetryHandler {
            NSApplication.shared.terminate(nil)
        }
        register(runtime, recoveryRoot: recoveryBase)
        controller.showAndFocus()
        runtimeIsReady = true
        drainPendingFinderOpenRequests()
        restoreAdditionalWindows()

        if environment["DUCKPAD_PERFORMANCE_LAUNCH_SMOKE"] == "1" {
            Task { @MainActor in
                await controller.waitForStartup()
                precondition(systemRecentDocumentReadCount == 0, "performance launch read system recent documents")
                print("DUCKPAD_PERF_READY=1 RECENTS=0")
                fflush(stdout)
                Darwin._exit(0)
            }
        } else if let expectedPath = environment["DUCKPAD_SECURITY_SCOPE_SMOKE_WRITE"] {
            Task { @MainActor in
                await controller.waitForStartup()
                let expected = URL(fileURLWithPath: expectedPath).standardizedFileURL.path
                for _ in 0..<4_000 {
                    if workspace.activeFileContext()?.binding?.canonicalPath == expected { break }
                    await Task.yield()
                }
                guard workspace.activeFileContext()?.binding?.canonicalPath == expected,
                      workspace.activeFileContext()?.binding?.securityScopedBookmark != nil,
                      let view = editor.activeScintillaView else {
                    preconditionFailure("security-scope smoke did not bind a bookmarked Finder document")
                }
                view.insertCommittedText("bookmark-relaunch")
                guard case .saved = await recoveryUseCase.flush() else {
                    preconditionFailure("security-scope smoke recovery flush failed")
                }
                print("Duckpad security-scope smoke wrote bookmarked recovery")
                fflush(stdout); Darwin._exit(86)
            }
        } else if let expectedPath = environment["DUCKPAD_SECURITY_SCOPE_SMOKE_VERIFY"] {
            Task { @MainActor in
                await controller.waitForStartup()
                let expected = URL(fileURLWithPath: expectedPath).standardizedFileURL.path
                guard workspace.activeFileContext()?.binding?.canonicalPath == expected,
                      workspace.activeFileContext()?.binding?.securityScopedBookmark != nil else {
                    preconditionFailure("security-scoped bookmark was not restored after relaunch")
                }
                let saveOutcome = await fileUseCase.saveActive()
                let savedText = try? String(contentsOf: URL(fileURLWithPath: expected), encoding: .utf8)
                guard case .saved = saveOutcome, savedText == "bookmark-relaunch" else {
                    FileHandle.standardError.write(Data(
                        "restored security-scoped document could not be saved: \(saveOutcome), bytes: \(savedText ?? "<unreadable>")\n".utf8
                    ))
                    Darwin._exit(87)
                }
                guard case .saved = await recoveryUseCase.reset() else {
                    preconditionFailure("security-scope smoke recovery cleanup failed")
                }
                await fileUseCase.releaseAllSecurityScopedAccess()
                let bookmarkCleanup = await fileUseCase.clearPersistedSecurityScopedBookmarks()
                precondition(bookmarkCleanup == nil, "security-scope bookmark cleanup failed")
                print("Duckpad security-scope smoke restored bookmark and saved after relaunch")
                fflush(stdout); Darwin._exit(0)
            }
        } else if let expectedPath = environment["DUCKPAD_FINDER_SMOKE_EXPECT"] {
            Task { @MainActor in
                await controller.waitForStartup()
                let expected = URL(fileURLWithPath: expectedPath).standardizedFileURL.path
                for _ in 0..<4_000 {
                    if workspace.activeFileContext()?.binding?.canonicalPath == expected { break }
                    await Task.yield()
                }
                precondition(
                    workspace.activeFileContext()?.binding?.canonicalPath == expected,
                    "Finder/Open With request did not bind the requested document"
                )
                print("Duckpad Finder smoke ready: LaunchServices -> queued open -> bound document")
                fflush(stdout)
                Darwin._exit(0)
            }
        } else if environment["DUCKPAD_SETTINGS_SMOKE"] == "1" {
            Task { @MainActor in
                await controller.waitForStartup()
                let requested = AppSettings(
                    appearanceMode: .dark,
                    defaultWordWrapEnabled: false,
                    defaultWrapMarkerVisible: true
                )
                guard case .saved(let saved) = await settingsUseCase.update(requested) else {
                    preconditionFailure("settings smoke could not persist preferences")
                }
                apply(saved)
                controller.close()
                precondition(windowControllers.isEmpty, "last document window remained retained")
                performShowSettings()
                precondition(settingsWindowController?.window?.isVisible == true, "Settings unavailable without documents")
                createAdditionalWindow()
                guard let reopened = windowControllers.values.first,
                      let reopenedEditor = windowEditors[ObjectIdentifier(reopened)] else {
                    preconditionFailure("settings smoke could not reopen a document window")
                }
                await reopened.waitForStartup()
                precondition(!reopenedEditor.isWordWrapEnabled, "reopened window missed word-wrap default")
                precondition(reopenedEditor.isWrapMarkerVisible, "reopened window missed wrap-marker default")
                print("Duckpad settings smoke ready: durable defaults + zero-window Settings + reopened window")
                fflush(stdout)
                Darwin._exit(0)
            }
        } else if environment["DUCKPAD_MULTIWINDOW_SMOKE"] == "1" {
            controller.performNewWindow()
            Task { @MainActor in
                for controller in windowControllers.values {
                    await controller.waitForStartup()
                    let flushed = await controller.flushRecovery()
                    precondition(flushed, "window recovery flush failed")
                }
                precondition(windowControllers.count == 2, "new-window command did not retain two controllers")
                precondition(terminationCoordinator.attachedWindowCount == 2, "termination coordinator missed a window")
                precondition(Set(windowControllers.values.compactMap { $0.window.map(ObjectIdentifier.init) }).count == 2)
                print("Duckpad multi-window smoke ready: 2 independent native windows with recovery")
                fflush(stdout)
                Darwin._exit(0)
            }
        } else if let expectedText = environment["DUCKPAD_MULTIWINDOW_CLOSE_RESTORED_SMOKE"],
                  let expected = Int(expectedText), expected > 1 {
            Task { @MainActor in
                for _ in 0..<2_000 where windowControllers.count < expected { await Task.yield() }
                precondition(windowControllers.count == expected, "additional window was not restored before close")
                let primaryRoot = recoveryBase.standardizedFileURL
                guard let pair = windowRecoveryRoots.first(where: { $0.value != primaryRoot }),
                      let restored = windowControllers[pair.key] else {
                    preconditionFailure("restored additional window is unavailable")
                }
                restored.close()
                let approved = await withCheckedContinuation { continuation in
                    let reply = terminationCoordinator.applicationShouldTerminate {
                        continuation.resume(returning: $0)
                    }
                    precondition(reply == .terminateLater, "close cleanup was not joined")
                }
                precondition(approved, "close cleanup prevented termination")
                precondition(!FileManager.default.fileExists(atPath: pair.value.path))
                print("Duckpad multi-window close cleanup removed the restored window")
                fflush(stdout)
                Darwin._exit(0)
            }
        } else if let expectedText = environment["DUCKPAD_MULTIWINDOW_RESTORE_SMOKE"],
                  let expected = Int(expectedText), expected > 0 {
            Task { @MainActor in
                for _ in 0..<2_000 where windowControllers.count < expected { await Task.yield() }
                precondition(windowControllers.count == expected, "additional windows were not restored")
                for controller in windowControllers.values { await controller.waitForStartup() }
                precondition(terminationCoordinator.attachedWindowCount == expected)
                precondition(Set(windowControllers.values.compactMap { $0.window.map(ObjectIdentifier.init) }).count == expected)
                print("Duckpad multi-window recovery restored \(expected) native windows")
                fflush(stdout)
                Darwin._exit(0)
            }
        } else if environment["DUCKPAD_EXTENSION_ISOLATION_SMOKE"] == "1" {
            Task { @MainActor in
                await controller.waitForStartup()
                let timeoutRequest = extensionIsolationRequest(
                    requestID: UUID(),
                    timeoutMilliseconds: 75
                )
                do {
                    _ = try await extensionTransport.invoke(timeoutRequest)
                    preconditionFailure("looping XPC module unexpectedly completed")
                } catch let failure as ExtensionFailure {
                    precondition(failure == .timedOut, "looping XPC module was not timed out: \(failure)")
                } catch {
                    preconditionFailure("looping XPC timeout was untyped: \(error)")
                }

                let cancelledID = UUID()
                let cancelledTask = Task {
                    try await extensionTransport.invoke(extensionIsolationRequest(
                        requestID: cancelledID,
                        timeoutMilliseconds: 10_000
                    ))
                }
                try? await Task.sleep(for: .milliseconds(75))
                await extensionTransport.cancel(requestID: cancelledID)
                do {
                    _ = try await cancelledTask.value
                    preconditionFailure("cancelled looping XPC module unexpectedly completed")
                } catch let failure as ExtensionFailure {
                    precondition(failure == .cancelled, "looping XPC module was not cancelled: \(failure)")
                } catch {
                    preconditionFailure("looping XPC cancellation was untyped: \(error)")
                }

                guard let view = editor.activeScintillaView else {
                    preconditionFailure("extension isolation smoke editor missing")
                }
                view.insertCommittedText("z\na")
                view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 3))
                await workspace.waitForPendingPersistence()
                do {
                    _ = try await extensionUseCase.invoke(
                        ExtensionCommandID(rawValue: "com.duckpad.text-tools.sortSelectedLines")
                    )
                } catch {
                    FileHandle.standardError.write(Data(
                        "fresh XPC service did not recover after teardown: \(error)\n".utf8
                    ))
                    Darwin._exit(88)
                }
                precondition(
                    editor.snapshot(for: workspace.snapshot().activeBuffer!.bufferID)?.text == "a\nz",
                    "fresh XPC service returned an invalid edit"
                )
                print("Duckpad XPC isolation smoke ready: timeout + cancel teardown + fresh service")
                fflush(stdout); Darwin._exit(0)
            }
        } else if environment["DUCKPAD_EXTENSION_SMOKE"] == "1" {
            Task { @MainActor in
                await controller.waitForStartup()
                guard let view = editor.activeScintillaView else { preconditionFailure("extension smoke editor missing") }
                let original = "앞🙂\nz\na\n뒤🙂"
                view.insertCommittedText(original)
                let prefix = Data("앞🙂\n".utf8).count
                let selectionLength = Data("z\na\n".utf8).count
                view.setPrimarySelectionUTF8Range(NSRange(location: prefix, length: selectionLength))
                await workspace.waitForPendingPersistence()
                do {
                    _ = try await extensionUseCase.invoke(ExtensionCommandID(rawValue: "com.duckpad.text-tools.sortSelectedLines"))
                } catch {
                    FileHandle.standardError.write(Data("Duckpad extension smoke failed: \(error)\n".utf8))
                    preconditionFailure("extension smoke invocation failed: \(error)")
                }
                guard editor.snapshot(for: workspace.snapshot().activeBuffer!.bufferID)?.text == "앞🙂\na\nz\n뒤🙂" else {
                    preconditionFailure("extension selection command changed bytes outside its grant scope")
                }
                view.undo()
                guard editor.snapshot(for: workspace.snapshot().activeBuffer!.bufferID)?.text == original else {
                    preconditionFailure("extension command was not one native undo group")
                }
                print("Duckpad extension smoke ready: signed package -> isolated WAMR host -> scoped grouped edit")
                fflush(stdout); Darwin._exit(0)
            }
        } else if environment["DUCKPAD_LANGUAGE_SMOKE"] == "1" {
            Task { @MainActor in
                await controller.waitForStartup()
                guard let view = editor.activeScintillaView else {
                    preconditionFailure("language smoke editor missing")
                }
                view.insertCommittedText("let duck = \"한글 🦆\"\n")
                _ = await languageUseCase.setOverride(.manual(LanguageID(rawValue: "swift")))
                guard editor.activeLanguageID.rawValue == "swift", view.lexerName == "cpp",
                      view.style(atUTF8Position: 0) == 5 else {
                    preconditionFailure("Swift Lexilla styling smoke failed")
                }
                let functionHeaderUTF8 = view.documentByteLength
                view.insertCommittedText("func foldedDuck() {\n    let value = 1\n}\n")
                view.setPrimarySelectionUTF8Range(
                    NSRange(location: Int(functionHeaderUTF8), length: 0)
                )
                for _ in 0..<2_000 where !editor.canCollapseCurrentFold {
                    await Task.yield()
                }
                let foldingBytes = view.contentUTF8
                let foldingRevision = view.revision
                guard editor.collapseCurrentFold(),
                      view.contractedFoldHeaderLines(maximumCount: 10).map(\.intValue) == [1],
                      editor.expandCurrentFold(),
                      view.contractedFoldHeaderLines(maximumCount: 10).isEmpty,
                      view.contentUTF8 == foldingBytes,
                      view.revision == foldingRevision else {
                    preconditionFailure("Swift folding smoke failed or mutated document state")
                }
                let revision = view.revision
                languageUseCase.applyTheme(.dark)
                guard view.revision == revision else { preconditionFailure("theme mutated text revision") }
                _ = await languageUseCase.setOverride(.manual(LanguageID(rawValue: "python")))
                guard editor.activeLanguageID.rawValue == "python", view.lexerName == "python" else {
                    preconditionFailure("Python lexer switch smoke failed")
                }
                print("Duckpad language smoke ready: Lexilla 5.5.3 Swift/Python + folding + dark palette")
                fflush(stdout)
                Darwin._exit(0)
            }
        } else if environment["DUCKPAD_INTELLIGENCE_SMOKE"] == "1" {
            Task { @MainActor in
                await controller.waitForStartup()
                guard let view = editor.activeScintillaView else {
                    preconditionFailure("document intelligence smoke editor missing")
                }
                let text = "func paddle() {}\npaddling pad"
                view.insertCommittedText(text)
                await workspace.waitForPendingPersistence()
                let completion = await documentIntelligenceUseCase.complete()
                guard case .presented(let count) = completion, count == 2,
                      view.isCompletionActive else {
                    preconditionFailure("current-document completion did not present exact candidates")
                }
                let outline = await documentIntelligenceUseCase.outline()
                guard case .ready(let result) = outline,
                      result.symbols.map(\.name) == ["paddle"] else {
                    preconditionFailure("document symbol outline did not parse the active buffer")
                }
                print("Duckpad document intelligence smoke ready: completion + symbol outline")
                fflush(stdout)
                Darwin._exit(0)
            }
        } else if let formatSmokePath = environment["DUCKPAD_FORMAT_SMOKE_FILE"] {
            Task { @MainActor in
                await controller.waitForStartup()
                let url = URL(fileURLWithPath: formatSmokePath)
                let original = "한\r둘🙂"
                do {
                    try TextFileCodec.encode(
                        original,
                        encoding: .utf16LittleEndian,
                        byteOrderMark: .absent
                    ).write(to: url)
                } catch {
                    preconditionFailure("format smoke seed failed: \(error)")
                }
                guard case .opened = await fileUseCase.open(url, assuming: .utf16LittleEndian),
                      controller.fileFormatStatusSmokeState().encoding == .utf16LittleEndian,
                      controller.fileFormatStatusSmokeState().lineEnding == .cr else {
                    preconditionFailure("explicit UTF-16 LE open did not publish format state")
                }
                guard case .saved = await fileUseCase.saveActive(conversion: TextFileConversion(
                    encoding: .utf8,
                    byteOrderMark: .present,
                    lineEnding: .crlf
                )), let saved = try? Data(contentsOf: url),
                saved.starts(with: Data([0xEF, 0xBB, 0xBF])),
                String(data: saved.dropFirst(3), encoding: .utf8) == "한\r\n둘🙂" else {
                    preconditionFailure("UTF-8 BOM/CRLF conversion did not persist exact bytes")
                }
                print("Duckpad format smoke ready: UTF-16 LE open -> UTF-8 BOM + CRLF")
                fflush(stdout)
                Darwin._exit(0)
            }
        } else if environment["DUCKPAD_SEARCH_SMOKE"] == "1" {
            Task { @MainActor in
                await controller.waitForStartup()
                guard let view = editor.activeScintillaView else {
                    preconditionFailure("search smoke editor missing")
                }
                view.insertCommittedText("duck 한글🙂 duck")
                let regex = SearchQuery(
                    pattern: "한글(?=🙂)",
                    options: SearchOptions(mode: .regularExpression, matchCase: true)
                )
                guard try await searchUseCase.find(regex) != nil else {
                    preconditionFailure("search smoke regex find failed")
                }
                let replaced = try await searchUseCase.replaceAll(
                    SearchQuery(pattern: "duck", replacement: "goose", options: SearchOptions(matchCase: true))
                )
                guard replaced == 2,
                      editor.snapshot(for: workspace.snapshot().activeBuffer!.bufferID)?.text == "goose 한글🙂 goose" else {
                    preconditionFailure("search smoke replace failed")
                }
                print("Duckpad search smoke ready: ICU regex + 2 grouped replacements")
                fflush(stdout)
                Darwin._exit(0)
            }
        } else if let workspaceRootPath = environment["DUCKPAD_WORKSPACE_SMOKE_ROOT"] {
            Task { @MainActor in
                await controller.waitForStartup()
                _ = await workspaceBrowserUseCase.start()
                let state = await workspaceBrowserUseCase.addRoot(
                    URL(fileURLWithPath: workspaceRootPath, isDirectory: true)
                )
                guard case .ready(let roots) = state,
                      let root = roots.first(where: { $0.canonicalPath == workspaceRootPath }),
                      try await workspaceBrowserUseCase.children(
                        rootID: root.id,
                        relativeDirectory: ""
                      ).contains(where: { $0.name == "smoke.txt" }),
                      controller.workspaceSidebarSmokeState().rootCount == 1 else {
                    preconditionFailure("workspace browser smoke failed")
                }
                print("Duckpad workspace smoke ready: persisted root + lazy native outline")
                fflush(stdout)
                Darwin._exit(0)
            }
        } else if environment["DUCKPAD_TAB_SMOKE"] == "1" {
            Task { @MainActor in
                await controller.waitForStartup()
                for _ in 1..<50 { _ = await workspace.addScratch() }
                let tabs = workspace.snapshot().tabs
                _ = await workspace.setPinned(tabs[0].id, isPinned: true)
                _ = await workspace.moveTab(tabs[10].id, to: 40)
                _ = await workspace.navigateTabs(.lastUsed)
                controller.window?.setContentSize(NSSize(width: 300, height: 360))
                let state = controller.tabWorkspaceSmokeState()
                precondition(state.tabCount == 50, "tab smoke lost a document")
                precondition(state.rowCount > 1, "tab smoke did not wrap")
                precondition(state.selectedTabIsVisible, "tab smoke hid the active tab")
                print("Duckpad tab smoke ready: \(state.tabCount) tabs, \(state.rowCount) rows")
                if environment["DUCKPAD_SMOKE_EXIT"] == "1" {
                    fflush(stdout)
                    Darwin._exit(0)
                }
            }
        } else if let expected = environment["DUCKPAD_RECOVERY_SMOKE_VERIFY"] {
            Task { @MainActor in
                await controller.waitForStartup()
                guard let active = workspace.snapshot().activeBuffer,
                      let recovered = editor.recoverySnapshot(for: active.bufferID),
                      String(data: recovered.utf8, encoding: .utf8) == expected else {
                    preconditionFailure("recovery smoke verification failed")
                }
                print("Duckpad recovery smoke restored \(workspace.snapshot().tabs.count) tab(s)")
                fflush(stdout)
                Darwin._exit(0)
            }
        } else if let text = environment["DUCKPAD_RECOVERY_SMOKE_WRITE"] {
            Task { @MainActor in
                await controller.waitForStartup()
                guard let view = editor.activeScintillaView else {
                    preconditionFailure("recovery smoke editor missing")
                }
                view.insertCommittedText(text)
                await recoveryUseCase.waitForPendingAutosave()
                print("Duckpad recovery smoke autosaved before forced exit")
                fflush(stdout)
                Darwin._exit(86)
            }
        } else if let smokePath = environment["DUCKPAD_SMOKE_FILE"] {
            Task { @MainActor in
                await controller.waitForStartup()
                let open = await fileUseCase.open(URL(fileURLWithPath: smokePath))
                guard case .opened = open else { preconditionFailure("file smoke open failed: \(open)") }
                let save = await fileUseCase.saveActive()
                guard case .saved = save else { preconditionFailure("file smoke save failed: \(save)") }
                print("Duckpad file smoke round-trip ready: \(smokePath)")
                if environment["DUCKPAD_SMOKE_EXIT"] == "1" { NSApplication.shared.terminate(nil) }
            }
        } else if environment["DUCKPAD_SMOKE_EXIT"] == "1" {
            precondition(editor.activeScintillaView != nil, "production Scintilla view was not hosted")
            print("Duckpad smoke window ready with Scintilla \(ScintillaEditorAdapter.engineVersion)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func extensionIsolationRequest(
        requestID: UUID,
        timeoutMilliseconds: UInt32
    ) -> ExtensionHostRequest {
        ExtensionHostRequest(
            requestID: requestID,
            module: Self.nonTerminatingWasmModule,
            context: ExtensionInvocationContext(
                extensionID: ExtensionID(rawValue: "com.duckpad.isolation-smoke"),
                commandID: ExtensionCommandID(rawValue: "com.duckpad.isolation-smoke.loop"),
                operation: 0,
                inputScope: .document,
                tabID: TabID(),
                bufferID: BufferID(),
                revision: 0,
                selection: ExtensionUTF8Range(location: 0, length: 0),
                utf8: Data()
            ),
            limits: ExtensionHostLimits(timeoutMilliseconds: timeoutMilliseconds)
        )
    }

    private static let nonTerminatingWasmModule = Data([
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x0c, 0x02,
        0x60, 0x03, 0x7f, 0x7f, 0x7f, 0x01, 0x7f,
        0x60, 0x00, 0x01, 0x7f,
        0x03, 0x04, 0x03, 0x00, 0x01, 0x01,
        0x05, 0x04, 0x01, 0x01, 0x01, 0x01,
        0x07, 0x4c, 0x04,
        0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00,
        0x0e, 0x64, 0x75, 0x63, 0x6b, 0x70, 0x61, 0x64, 0x5f, 0x69, 0x6e, 0x76, 0x6f, 0x6b, 0x65, 0x00, 0x00,
        0x16, 0x64, 0x75, 0x63, 0x6b, 0x70, 0x61, 0x64, 0x5f, 0x6f, 0x75, 0x74, 0x70, 0x75, 0x74, 0x5f, 0x70, 0x6f, 0x69, 0x6e, 0x74, 0x65, 0x72, 0x00, 0x01,
        0x15, 0x64, 0x75, 0x63, 0x6b, 0x70, 0x61, 0x64, 0x5f, 0x6f, 0x75, 0x74, 0x70, 0x75, 0x74, 0x5f, 0x6c, 0x65, 0x6e, 0x67, 0x74, 0x68, 0x00, 0x02,
        0x0a, 0x15, 0x03,
        0x09, 0x00, 0x03, 0x40, 0x0c, 0x00, 0x0b, 0x41, 0x00, 0x0b,
        0x04, 0x00, 0x41, 0x00, 0x0b,
        0x04, 0x00, 0x41, 0x00, 0x0b,
    ])

    private func makeWindowRuntime(
        recoveryRoot: URL,
        verifiedRecoveryRoot: VerifiedRecoveryRoot? = nil
    ) -> WindowRuntime {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let settings = settingsUseCase.state.settings
        let editor = ScintillaEditorAdapter(defaultViewState: EditorViewState(
            wordWrapEnabled: settings.defaultWordWrapEnabled,
            wrapMarkerVisible: settings.defaultWrapMarkerVisible
        ))
        let recoveryStore = verifiedRecoveryRoot.map { LocalRecoveryStore(verifiedRoot: $0) }
            ?? LocalRecoveryStore(root: recoveryRoot)
        let recoveryUseCase = SessionRecoveryUseCase(
            workspace: workspace,
            editor: editor,
            store: recoveryStore
        )
        let fileUseCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: fileStore)
        let searchUseCase = SearchWorkspaceUseCase(
            workspace: workspace,
            editor: editor,
            regexEngine: ICURegexEngine()
        )
        let folderSearchUseCase = FolderSearchUseCase(
            store: folderSearchStore,
            regexEngine: ICURegexEngine()
        )
        let workspaceBrowserUseCase = WorkspaceBrowserUseCase(store: workspaceRootStore)
        let languageUseCase = LanguageWorkspaceUseCase(
            registry: languageRegistry,
            workspace: workspace,
            editor: editor,
            configurationIssue: languageConfigurationIssue
        )
        let documentIntelligenceUseCase = DocumentIntelligenceUseCase(editor: editor)
        #if DEBUG
        let allowsDevelopmentExtensions = environment["DUCKPAD_ALLOW_DEVELOPMENT_EXTENSIONS"] == "1"
        #else
        let allowsDevelopmentExtensions = false
        #endif
        let extensionUseCase = ExtensionWorkspaceUseCase(
            loader: extensionLoader,
            grants: extensionPolicy,
            transport: extensionTransport,
            workspace: workspace,
            editor: editor,
            allowsUserExtensions: allowsDevelopmentExtensions
        )
        let panels = NativeFilePanelAdapter()
        let controller = DuckpadWindowController(
            workspace: workspace,
            editorAdapter: editor,
            editorView: editor.view,
            fileUseCase: fileUseCase,
            filePanels: panels,
            fileConflictPresenter: panels,
            dirtyDecisionPresenter: panels,
            recoveryUseCase: recoveryUseCase,
            terminationCoordinator: terminationCoordinator,
            searchUseCase: searchUseCase,
            folderSearchUseCase: folderSearchUseCase,
            workspaceBrowserUseCase: workspaceBrowserUseCase,
            languageUseCase: languageUseCase,
            documentIntelligenceUseCase: documentIntelligenceUseCase,
            extensionUseCase: extensionUseCase
        )
        return WindowRuntime(
            controller: controller,
            workspace: workspace,
            editor: editor,
            recoveryUseCase: recoveryUseCase,
            fileUseCase: fileUseCase,
            searchUseCase: searchUseCase,
            workspaceBrowserUseCase: workspaceBrowserUseCase,
            languageUseCase: languageUseCase,
            documentIntelligenceUseCase: documentIntelligenceUseCase,
            extensionUseCase: extensionUseCase
        )
    }

    private func register(_ runtime: WindowRuntime, recoveryRoot: URL) {
        let controller = runtime.controller
        let identifier = ObjectIdentifier(controller)
        windowControllers[identifier] = controller
        windowEditors[identifier] = runtime.editor
        windowRecoveryRoots[identifier] = recoveryRoot.standardizedFileURL
        controller.onNewWindowRequested = { [weak self] in self?.createAdditionalWindow() }
        controller.onSettingsRequested = { [weak self] in self?.showSettings() }
        controller.onBecameKey = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.installMainMenu(target: controller)
        }
        controller.onExtensionCommandsChanged = { [weak self, weak controller] in
            guard let self, let controller, controller.window?.isKeyWindow == true else { return }
            self.installMainMenu(target: controller)
        }
        controller.onDocumentURLUsed = { [weak self] url in
            guard let self else { return }
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            if let target = self.activeDocumentController {
                self.installMainMenu(target: target)
            }
        }
        controller.onClosed = { [weak self, weak controller] in
            guard let self, let controller else { return }
            let identifier = ObjectIdentifier(controller)
            self.windowRecoveryRoots.removeValue(forKey: identifier)
            self.windowEditors.removeValue(forKey: identifier)
            self.windowControllers.removeValue(forKey: identifier)
            if self.windowController === controller {
                self.windowController = self.windowControllers.values.first
            }
        }
        installMainMenu(target: controller)
    }

    private func createAdditionalWindow() {
        guard windowControllers.count < 32 else {
            NSSound.beep()
            return
        }
        let recoveryRoot = additionalRecoveryContainer
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let runtime = makeWindowRuntime(recoveryRoot: recoveryRoot)
        register(runtime, recoveryRoot: recoveryRoot)
        runtime.controller.showAndFocus()
    }

    private var additionalRecoveryContainer: URL {
        recoveryBase.deletingLastPathComponent().appendingPathComponent(
            recoveryBase.lastPathComponent + "-Windows",
            isDirectory: true
        )
    }

    private func restoreAdditionalWindows() {
        guard environment["DUCKPAD_MULTIWINDOW_SMOKE"] != "1" else { return }
        let container = additionalRecoveryContainer
        Task { @MainActor [weak self] in
            let roots = await Task.detached(priority: .utility) {
                LocalRecoveryStore.discoverVerifiedRoots(in: container)
            }.value
            guard let self else { return }
            let activeRoots = Set(self.windowRecoveryRoots.values.map(\.standardizedFileURL))
            for root in roots where !activeRoots.contains(root.displayURL.standardizedFileURL) {
                let runtime = self.makeWindowRuntime(
                    recoveryRoot: root.displayURL,
                    verifiedRecoveryRoot: root
                )
                self.register(runtime, recoveryRoot: root.displayURL)
                runtime.controller.showWindow(nil)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let result = terminationCoordinator.applicationShouldTerminate { approved in
            sender.reply(toApplicationShouldTerminate: approved)
        }
        return result
    }

    func applicationWillResignActive(_ notification: Notification) {
        let controllers = Array(windowControllers.values)
        Task { @MainActor in
            for controller in controllers { _ = await controller.flushRecovery() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let controller = windowControllers.values.first { controller.showAndFocus() }
            else { createAdditionalWindow() }
        }
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0, isDirectory: false) }
        guard runtimeIsReady else {
            pendingFinderOpenRequests.append(urls)
            return
        }
        openDocumentURLs(urls, replyTo: sender)
    }

    @objc func performOpenRecentDocument(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let url = item.representedObject as? URL else { return }
        openDocumentURLs([url], replyTo: nil)
    }

    @objc func performClearRecentDocuments(_ sender: Any?) {
        guard terminationCoordinator.permitsApplicationCommands else { return }
        NSDocumentController.shared.clearRecentDocuments(sender)
        let task = Task { [fileStore] in _ = try? await fileStore?.clearPersistedSecurityScopedBookmarks() }
        terminationCoordinator.trackApplicationTask(task)
        if let target = activeDocumentController { installMainMenu(target: target) }
    }

    private var activeDocumentController: DuckpadWindowController? {
        windowControllers.values.first(where: { $0.window?.isKeyWindow == true })
            ?? windowController
            ?? windowControllers.values.first
    }

    private func openDocumentURLs(_ urls: [URL], replyTo application: NSApplication?) {
        guard terminationCoordinator.permitsApplicationCommands else {
            application?.reply(toOpenOrPrint: .failure)
            return
        }
        if activeDocumentController == nil { createAdditionalWindow() }
        guard let controller = activeDocumentController else {
            application?.reply(toOpenOrPrint: .failure)
            return
        }
        controller.showAndFocus()
        controller.openExternalURLs(urls) { succeeded in
            application?.reply(toOpenOrPrint: succeeded ? .success : .failure)
        }
    }

    private func drainPendingFinderOpenRequests() {
        guard runtimeIsReady, !pendingFinderOpenRequests.isEmpty else { return }
        let requests = pendingFinderOpenRequests
        pendingFinderOpenRequests.removeAll()
        for urls in requests { openDocumentURLs(urls, replyTo: NSApplication.shared) }
    }

    private func installMainMenu(target: DuckpadWindowController) {
        let recentDocumentURLs: [URL]
        if environment["DUCKPAD_PERFORMANCE_LAUNCH_SMOKE"] == "1" {
            recentDocumentURLs = []
        } else {
            systemRecentDocumentReadCount += 1
            recentDocumentURLs = NSDocumentController.shared.recentDocumentURLs
        }
        let menu = DuckpadMainMenuFactory.make(
            target: target,
            applicationTarget: self,
            recentDocumentURLs: recentDocumentURLs
        )
        NSApplication.shared.mainMenu = menu
        target.applicationMainMenuDidChange(menu)
    }

    @objc func performShowSettings(_ sender: Any? = nil) {
        guard terminationCoordinator.permitsApplicationCommands else { return }
        showSettings()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performShowSettings(_:)) {
            return terminationCoordinator.permitsApplicationCommands
        }
        if menuItem.action == #selector(performOpenRecentDocument(_:))
            || menuItem.action == #selector(performClearRecentDocuments(_:)) {
            return terminationCoordinator.permitsApplicationCommands
        }
        return true
    }

    private func showSettings() {
        let settingsWindow = settingsWindowController ?? DuckpadSettingsWindowController()
        settingsWindowController = settingsWindow
        settingsWindow.acceptsUpdates = { [weak self] in
            self?.terminationCoordinator.permitsApplicationCommands == true
        }
        settingsWindow.onUpdateTaskStarted = { [weak self] task in
            self?.terminationCoordinator.trackApplicationTask(task)
        }
        settingsWindow.present(settings: settingsUseCase.state.settings) { [weak self] settings in
            guard let self else { return .failed(.writeFailed("application unavailable")) }
            let outcome = await self.settingsUseCase.update(settings)
            switch outcome {
            case .saved(let saved), .savedWithWarning(let saved, _): self.apply(saved)
            case .failed: break
            }
            return outcome
        }
    }

    private func apply(_ settings: AppSettings) {
        switch settings.appearanceMode {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
        for editor in windowEditors.values {
            editor.setDefaultViewOptions(
                wordWrapEnabled: settings.defaultWordWrapEnabled,
                wrapMarkerVisible: settings.defaultWrapMarkerVisible
            )
        }
        for controller in windowControllers.values { controller.refreshAppearance() }
    }

    private func installDevelopmentAppIcon() {
        let iconURL = Bundle.main.url(forResource: "Duckpad", withExtension: "icns")
            ?? Bundle.module.url(forResource: "Duckpad", withExtension: "icns")
        guard let url = iconURL,
              let image = NSImage(contentsOf: url) else {
            assertionFailure("Bundled Duckpad.icns is missing or invalid")
            return
        }
        NSApplication.shared.applicationIconImage = image
    }
}

@main
enum DuckpadMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = DuckpadAppDelegate()
        application.delegate = delegate
        application.run()
    }
}
