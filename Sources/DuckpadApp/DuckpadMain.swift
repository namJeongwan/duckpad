import AppKit
import DuckpadApplication
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
        let fileStore = LocalTextFileStore()
        let fileUseCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: fileStore)
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
            terminationCoordinator: terminationCoordinator
        )
        windowController = controller
        self.terminationCoordinator = terminationCoordinator
        installMainMenu(target: controller)
        controller.showAndFocus()

        let environment = ProcessInfo.processInfo.environment
        if let smokePath = environment["DUCKPAD_SMOKE_FILE"] {
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func installMainMenu(target: DuckpadWindowController) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit Duckpad",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let open = fileMenu.addItem(withTitle: "Open…", action: #selector(DuckpadWindowController.performOpenFile(_:)), keyEquivalent: "o")
        open.target = target
        let save = fileMenu.addItem(withTitle: "Save", action: #selector(DuckpadWindowController.performSaveFile(_:)), keyEquivalent: "s")
        save.target = target
        let saveAs = fileMenu.addItem(withTitle: "Save As…", action: #selector(DuckpadWindowController.performSaveFileAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        saveAs.target = target
        fileItem.submenu = fileMenu
        NSApplication.shared.mainMenu = mainMenu
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
