import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadPresentation

/// Runs before opening normal settings/recovery stores, using test text only.
@MainActor
enum BuiltInFormattingSmoke {
    static func run() async {
        var stage = "startup"
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-format-smoke-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
            let editor = ScintillaEditorAdapter()
            let formatter = BundledPrettierFormatter()
            let formatting = DocumentFormattingUseCase(workspace: workspace, editor: editor, formatter: formatter)
            let files = FileDocumentUseCase(workspace: workspace, editor: editor,
                store: LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent("access.json")))
            files.formattingUseCase = formatting
            let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: LocalMarkdownImageAccess(), editorAdapter: editor, editorView: editor.view,
                fileUseCase: files, formattingUseCase: formatting)
            await controller.waitForStartup()
            controller.showAndFocus()
            guard let view = editor.activeScintillaView, let context = workspace.activeFileContext() else { throw FormattingFailure.unavailable }
            let input = "{\"한글\":1}"
            let expected = "{ \"한글\": 1 }\n"
            view.insertCommittedText(input)
            _ = await workspace.setLanguageOverride(.manual(LanguageID(rawValue: "json")), for: context.tabID)
            let menu = DuckpadMainMenuFactory.make(target: controller)
            NSApplication.shared.mainMenu = menu
            stage = "format command binding"
            func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
            guard let item = items(menu).first(where: { $0.action == #selector(DuckpadWindowController.performFormatDocument(_:)) }),
                  item.keyEquivalent == "f", item.keyEquivalentModifierMask == [.shift, .option],
                  controller.validateMenuItem(item) else { throw FormattingFailure.unavailable }
            NSApplication.shared.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(200))
            let menuOnly = ProcessInfo.processInfo.environment["DUCKPAD_FORMATTING_SMOKE_MENU_ONLY"] == "1"
            if !menuOnly && controller.window?.isKeyWindow == true {
                stage = "synthetic keyboard event dispatch"
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift, .option],
                    timestamp: 0, windowNumber: controller.window?.windowNumber ?? 0, context: nil,
                    characters: "Ï", charactersIgnoringModifiers: "F", isARepeat: false, keyCode: 3),
                    menu.performKeyEquivalent(with: event) else { throw FormattingFailure.unavailable }
            } else {
                stage = "menu action dispatch"
                print(menuOnly
                    ? "SKIP: keyboard event delivery (explicit menu-only smoke); checking the menu action instead"
                    : "SKIP: keyboard event delivery (window server did not grant a key window); checking the menu action instead")
                guard NSApplication.shared.sendAction(item.action!, to: item.target, from: item) else { throw FormattingFailure.unavailable }
            }
            stage = "formatted text"
            let deadline = ContinuousClock.now + .seconds(20)
            while view.contentUTF8 != Data(expected.utf8), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard view.contentUTF8 == Data(expected.utf8) else { throw FormattingFailure.timedOut }
            stage = "native Undo"
            view.undo()
            guard view.contentUTF8 == Data(input.utf8) else { throw FormattingFailure.unavailable }
            var settings = AppSettings()
            settings.formatting.formatOnSave = true
            controller.applyPreferences(settings)
            stage = "format on save"
            let output = root.appendingPathComponent("formatted.json")
            let saveOutcome = await files.saveAs(output)
            switch saveOutcome {
            case .saved:
                guard try String(contentsOf: output, encoding: .utf8) == expected else { throw FormattingFailure.unavailable }
                print("PASS: format on save writes the formatted document")
            case .failed(.store(.permissionDenied)) where ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil:
                print("SKIP: native save-panel grant in sandbox; file-save integration is covered by the editor tests")
            default:
                throw NSError(domain: "DuckpadFormattingSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: String(describing: saveOutcome)])
            }
            stage = "settings persistence"
            let settingsStore = LocalAppSettingsStore(archiveURL: root.appendingPathComponent("settings.json"))
            try await settingsStore.save(settings)
            guard try await settingsStore.load()?.formatting.formatOnSave == true else { throw FormattingFailure.unavailable }
            stage = "additional parsers"
            for (parser, text) in [("typescript", "const n:number=1"), ("xml", "<a x = '1'/>"), ("sql", "select a from t where id=1")] {
                _ = try await formatter.format(.init(text: text, parser: parser))
            }
            print("PASS: bundled formatting, menu action and shortcut configuration, native Undo, and persisted settings")
            controller.close()
            fflush(stdout)
            Darwin._exit(0)
        } catch {
            print("FAIL: built-in formatting smoke [\(stage)]: \(error)")
            fflush(stdout)
            Darwin._exit(1)
        }
    }
}
