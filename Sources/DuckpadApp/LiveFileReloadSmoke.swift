import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadLocalization
import DuckpadPresentation

/// Packaged regression, invoked only with an explicitly isolated smoke file.
@MainActor enum LiveFileReloadSmoke {
    static func run(controller: DuckpadWindowController, editor: ScintillaEditorAdapter,
                    files: FileDocumentUseCase, url: URL) async {
        precondition(url.path.contains("/SecurityScopeSmoke/"), "live reload smoke requires an isolated fixture")
        files.setLiveReloadEnabled(false)
        guard case .opened(let tabID) = await files.open(url), let view = editor.activeScintillaView,
              let content = controller.window?.contentView else { preconditionFailure("live reload fixture did not open") }
        controller.showAndFocus()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func button(_ action: String) -> NSButton {
            guard let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.action == NSSelectorFromString(action) }) else {
                preconditionFailure("live reload control missing")
            }
            return button
        }
        let reload = button("performReloadExternalFile:"), keep = button("performKeepEditingExternalFile:")
        func wait(_ condition: () -> Bool) async {
            for _ in 0..<500 {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(10))
            }
            preconditionFailure("live reload smoke timed out")
        }
        func sheetButton(_ title: String) -> NSButton {
            guard let sheet = controller.window?.attachedSheet?.contentView,
                  let button = descendants(sheet).compactMap({ $0 as? NSButton }).first(where: { $0.title == L10n.text(title) }) else {
                preconditionFailure("live reload sheet control missing")
            }
            return button
        }
        do {
            let original = view.contentUTF8
            try FileManager.default.removeItem(at: url)
            let missing = await files.refreshFromDisk(tabID: tabID)
            precondition(missing == .store(.notFound(url.path)), "missing file failure was lost")
            reload.performClick(nil)
            await wait { controller.window?.attachedSheet != nil }
            let labels = descendants(controller.window!.attachedSheet!.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }
            precondition(labels.contains(L10n.text("This file is no longer available.")), "reload did not explain the missing file")
            precondition(view.contentUTF8 == original, "failed reload changed editor contents")
            try Data("available again".utf8).write(to: url)
            sheetButton("Retry").performClick(nil)
            await wait { view.contentUTF8 == Data("available again".utf8) && controller.window?.attachedSheet == nil }
            precondition(files.externalChanges[tabID] == nil, "successful retry retained warning")

            view.insertCommittedText("unsaved ")
            let unsaved = view.contentUTF8
            try Data("external one".utf8).write(to: url)
            _ = await files.refreshFromDisk(tabID: tabID)
            precondition(files.externalChanges[tabID] == .conflict, "external edit was not reported")
            keep.performClick(nil)
            _ = await files.refreshFromDisk(tabID: tabID)
            precondition(files.externalChanges[tabID] == nil && view.contentUTF8 == unsaved, "acknowledged warning repeated or edits were lost")
            try Data("external two".utf8).write(to: url)
            _ = await files.refreshFromDisk(tabID: tabID)
            precondition(files.externalChanges[tabID] == .conflict, "new external version was suppressed")
            reload.performClick(nil)
            await wait { controller.window?.attachedSheet != nil }
            sheetButton("Cancel").performClick(nil)
            await wait { controller.window?.attachedSheet == nil }
            precondition(view.contentUTF8 == unsaved, "canceling reload changed unsaved edits")
            reload.performClick(nil)
            await wait { controller.window?.attachedSheet != nil }
            sheetButton("Reload").performClick(nil)
            await wait { view.contentUTF8 == Data("external two".utf8) && controller.window?.attachedSheet == nil }
            precondition(files.externalChanges[tabID] == nil, "confirmed reload retained warning")
            print("Duckpad live reload smoke ready: missing-file explanation + Retry + Keep Editing + new version + Cancel + confirmed reload")
            fflush(stdout)
        } catch { preconditionFailure("live reload fixture failed: \(error)") }
    }
}
