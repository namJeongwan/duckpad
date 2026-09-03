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
    private var terminationCoordinator: ApplicationTerminationCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installDevelopmentAppIcon()
        let store = InMemorySessionStore()
        let workspace = ScratchWorkspaceUseCase(store: store)
        let editor = ScintillaEditorAdapter()
        let environment = ProcessInfo.processInfo.environment
        let recoveryRoot = environment["DUCKPAD_RECOVERY_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? LocalRecoveryStore.defaultRoot()
        let recoveryStore = LocalRecoveryStore(root: recoveryRoot)
        let recoveryUseCase = SessionRecoveryUseCase(
            workspace: workspace,
            editor: editor,
            store: recoveryStore
        )
        let fileStore = LocalTextFileStore()
        let fileUseCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: fileStore)
        let searchUseCase = SearchWorkspaceUseCase(
            workspace: workspace,
            editor: editor,
            regexEngine: ICURegexEngine()
        )
        let languageRegistry: LanguageRegistry
        let languageConfigurationIssue: String?
        do {
            languageRegistry = try LanguageManifestLoader().loadBundled()
            languageConfigurationIssue = nil
        } catch {
            languageRegistry = LanguageManifestLoader.fallbackRegistry
            languageConfigurationIssue = "Language registry degraded: \(error)"
        }
        let languageUseCase = LanguageWorkspaceUseCase(
            registry: languageRegistry,
            workspace: workspace,
            editor: editor,
            configurationIssue: languageConfigurationIssue
        )
        let extensionsRoot = environment["DUCKPAD_EXTENSIONS_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? LocalExtensionPackageLoader.defaultRoot()
        let policyRoot = environment["DUCKPAD_EXTENSION_POLICY_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? LocalExtensionPreferenceStore.defaultRoot()
        let extensionLoader = LocalExtensionPackageLoader(root: extensionsRoot)
        let extensionPolicy = LocalExtensionPreferenceStore(root: policyRoot)
        let extensionTransport = ProcessPluginHostTransport(executableURL: ProcessPluginHostTransport.siblingOfCurrentExecutable())
        #if DEBUG
        let allowsDevelopmentExtensions = environment["DUCKPAD_ALLOW_DEVELOPMENT_EXTENSIONS"] == "1"
        #else
        let allowsDevelopmentExtensions = false
        #endif
        let extensionUseCase = ExtensionWorkspaceUseCase(
            loader: extensionLoader, grants: extensionPolicy, transport: extensionTransport,
            workspace: workspace, editor: editor, allowsUserExtensions: allowsDevelopmentExtensions
        )
        let panels = NativeFilePanelAdapter()
        let terminationCoordinator = ApplicationTerminationCoordinator()
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
            languageUseCase: languageUseCase,
            extensionUseCase: extensionUseCase
        )
        windowController = controller
        self.terminationCoordinator = terminationCoordinator
        terminationCoordinator.installApplicationRetryHandler {
            NSApplication.shared.terminate(nil)
        }
        installMainMenu(target: controller)
        controller.onExtensionCommandsChanged = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.installMainMenu(target: controller)
        }
        controller.showAndFocus()

        if environment["DUCKPAD_EXTENSION_SMOKE"] == "1" {
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationCoordinator?.applicationShouldTerminate { approved in
            sender.reply(toApplicationShouldTerminate: approved)
        } ?? .terminateNow
    }

    func applicationWillResignActive(_ notification: Notification) {
        Task { @MainActor [weak windowController] in
            _ = await windowController?.flushRecovery()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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
