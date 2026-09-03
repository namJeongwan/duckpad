import AppKit
import Darwin
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadPresentation

@MainActor
final class DuckpadAppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: DuckpadWindowController?
    private var windowControllers: [ObjectIdentifier: DuckpadWindowController] = [:]
    private var windowRecoveryRoots: [ObjectIdentifier: URL] = [:]
    private let terminationCoordinator = ApplicationTerminationCoordinator()
    private var environment: [String: String] = [:]
    private var recoveryBase: URL!
    private var fileStore: LocalTextFileStore!
    private var folderSearchStore: LocalFolderSearchFileStore!
    private var workspaceRootStore: LocalWorkspaceRootStore!
    private var extensionLoader: LocalExtensionPackageLoader!
    private var extensionPolicy: LocalExtensionPreferenceStore!
    private var extensionTransport: ProcessPluginHostTransport!
    private var languageRegistry: LanguageRegistry!
    private var languageConfigurationIssue: String?

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
        recoveryBase = environment["DUCKPAD_RECOVERY_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? LocalRecoveryStore.defaultRoot()
        fileStore = LocalTextFileStore()
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
        extensionTransport = ProcessPluginHostTransport(executableURL: ProcessPluginHostTransport.siblingOfCurrentExecutable())
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
        restoreAdditionalWindows()

        if environment["DUCKPAD_MULTIWINDOW_SMOKE"] == "1" {
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
                let revision = view.revision
                languageUseCase.applyTheme(.dark)
                guard view.revision == revision else { preconditionFailure("theme mutated text revision") }
                _ = await languageUseCase.setOverride(.manual(LanguageID(rawValue: "python")))
                guard editor.activeLanguageID.rawValue == "python", view.lexerName == "python" else {
                    preconditionFailure("Python lexer switch smoke failed")
                }
                print("Duckpad language smoke ready: Lexilla 5.5.3 Swift/Python + dark palette")
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

    private func makeWindowRuntime(
        recoveryRoot: URL,
        verifiedRecoveryRoot: VerifiedRecoveryRoot? = nil
    ) -> WindowRuntime {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
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
        windowRecoveryRoots[identifier] = recoveryRoot.standardizedFileURL
        controller.onNewWindowRequested = { [weak self] in self?.createAdditionalWindow() }
        controller.onBecameKey = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.installMainMenu(target: controller)
        }
        controller.onExtensionCommandsChanged = { [weak self, weak controller] in
            guard let self, let controller, controller.window?.isKeyWindow == true else { return }
            self.installMainMenu(target: controller)
        }
        controller.onClosed = { [weak self, weak controller] in
            guard let self, let controller else { return }
            let identifier = ObjectIdentifier(controller)
            self.windowRecoveryRoots.removeValue(forKey: identifier)
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

    private func installMainMenu(target: DuckpadWindowController) {
        NSApplication.shared.mainMenu = DuckpadMainMenuFactory.make(target: target)
    }

    private func installDevelopmentAppIcon() {
        guard let url = Bundle.module.url(forResource: "Duckpad", withExtension: "icns"),
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
