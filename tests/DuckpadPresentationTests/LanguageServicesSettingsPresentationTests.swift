import AppKit
import Testing
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization
import DuckpadInfrastructure
@testable import DuckpadPresentation

@Suite(.serialized) @MainActor
struct LanguageServicesSettingsPresentationTests {
    private func registration() async throws -> LanguageServerRegistration {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let loader = LocalExtensionPackageLoader(root: FileManager.default.temporaryDirectory)
        let (package, files) = try await loader.readPackage(at: root.appendingPathComponent("LanguagePlugins/com.duckpad.python.duckpad-plugin"))
        return .init(extensionID: package.manifest.id, packageDigest: package.packageDigest, service: try #require(package.manifest.contributes.languageServices.first), packageFiles: files)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @Test func selectingTyAndFolderInterpreterPersistsOnlyTheCurrentWorkspace() async throws {
        _ = NSApplication.shared
        let controller = DuckpadSettingsWindowController()
        defer { controller.close() }
        let registration = try await registration()
        let owner = SessionID(), other = SessionID()
        let folder = LanguageServiceFolder(id: UUID().uuidString, path: "/tmp/probe", displayName: "probe")
        let original = AppSettings(languageServices: [registration.settingsKey: .init(workspaces: [other.rawValue.uuidString: .init(serverID: "pyright")])])
        var saved: AppSettings?
        controller.configure(settings: original) { saved = $0; return .saved($0) }
        controller.configureLanguageServices([registration])
        controller.configureLanguageWorkspace(id: owner, folders: [folder], selectedFolderID: folder.id, projectRoot: folder.path)
        controller.selectCategory("Language Support")
        let views = descendants(try #require(controller.window?.contentView))
        func popup(_ suffix: String) throws -> NSPopUpButton {
            try #require(views.first { $0.identifier?.rawValue == "duckpad.settings.language-services." + suffix } as? NSPopUpButton)
        }
        let scope = try popup("scope"), server = try popup("server")
        scope.selectItem(at: 2); _ = scope.sendAction(scope.action!, to: scope.target)
        server.select(try #require(server.itemArray.first { $0.representedObject as? String == "ty" }))
        let field = try #require(views.first { $0.identifier?.rawValue == "duckpad.settings.language-services.interpreter" } as? NSTextField)
        field.stringValue = "/tmp/probe/.venv/bin/python"
        let apply = try #require(views.first { $0.identifier?.rawValue == "duckpad.settings.language-services.apply" } as? NSButton)
        _ = apply.sendAction(apply.action!, to: apply.target)
        for _ in 0..<100 where controller.isUpdating { try await Task.sleep(for: .milliseconds(10)) }
        let result = try #require(saved)
        #expect(result.languageServices[registration.settingsKey]?.serverID == nil)
        #expect(result.languageServices[registration.settingsKey]?.workspace(owner).folders[folder.id] == .init(serverID: "ty", interpreterPath: "/tmp/probe/.venv/bin/python"))
        #expect(result.languageServices[registration.settingsKey]?.workspace(other) == original.languageServices[registration.settingsKey]?.workspace(other))
        #expect(field.stringValue == "/tmp/probe/.venv/bin/python")
        // Clearing both overrides restores inheritance rather than pinning today's default.
        server.selectItem(at: 0); field.stringValue = ""
        _ = apply.sendAction(apply.action!, to: apply.target)
        for _ in 0..<100 where controller.isUpdating { try await Task.sleep(for: .milliseconds(10)) }
        #expect(saved?.languageServices[registration.settingsKey]?.workspace(owner).folders[folder.id] == .init())
    }

    @Test func noWorkspaceDisablesScopedChoicesAndRejectsRelativeInterpreterPaths() async throws {
        _ = NSApplication.shared
        let view = LanguageServicesSettingsView()
        view.configureRegistrations([try await registration()])
        var changed = false
        view.onChange = { _ in changed = true }
        view.configureWorkspace(id: nil, folders: [])
        let views = descendants(view)
        let scope = try #require(views.first { $0.identifier?.rawValue == "duckpad.settings.language-services.scope" } as? NSPopUpButton)
        #expect(scope.item(at: 1)?.isEnabled == false)
        #expect(scope.item(at: 2)?.isEnabled == false)
        let field = try #require(views.first { $0.identifier?.rawValue == "duckpad.settings.language-services.interpreter" } as? NSTextField)
        let apply = try #require(views.first { $0.identifier?.rawValue == "duckpad.settings.language-services.apply" } as? NSButton)
        field.stringValue = "relative/python"
        _ = apply.sendAction(apply.action!, to: apply.target)
        #expect(!changed)
        #expect(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("absolute interpreter") })
        view.refreshLocalization(LocalizationCatalog(language: .korean))
        #expect(field.stringValue == "relative/python")
    }
    @Test func noPluginKeepsProviderControlsUnavailable() throws {
        _ = NSApplication.shared
        let view = LanguageServicesSettingsView()
        let views = descendants(view)
        let server = try #require(views.first { $0.identifier?.rawValue == "duckpad.settings.language-services.server" } as? NSPopUpButton)
        let apply = try #require(views.first { $0.identifier?.rawValue == "duckpad.settings.language-services.apply" } as? NSButton)
        #expect(view.selectedRegistration == nil)
        #expect(!server.isEnabled && !apply.isEnabled)
    }

    @Test func workspaceScopeDefaultsAndUnrelatedUpdatesKeepDraftsAndFolderChoices() async throws {
        _ = NSApplication.shared
        let registration = try await registration(), a = SessionID(), b = SessionID()
        let first = LanguageServiceFolder(id: UUID().uuidString, path: "/tmp/first", displayName: "first")
        let second = LanguageServiceFolder(id: UUID().uuidString, path: "/tmp/second", displayName: "second")
        let view = LanguageServicesSettingsView()
        view.configureRegistrations([registration])
        view.configureWorkspace(id: a, folders: [first, second], selectedFolderID: first.id)
        let views = descendants(view)
        func popup(_ id: String) throws -> NSPopUpButton {
            try #require(views.first { $0.identifier?.rawValue == "duckpad.settings.language-services." + id } as? NSPopUpButton)
        }
        let scope = try popup("scope"), folder = try popup("folder"), server = try popup("server")
        let field = try #require(views.first { $0.identifier?.rawValue == "duckpad.settings.language-services.interpreter" } as? NSTextField)
        let apply = try #require(views.first { $0.identifier?.rawValue == "duckpad.settings.language-services.apply" } as? NSButton)
        #expect(scope.indexOfSelectedItem == 1)
        server.select(try #require(server.itemArray.first { $0.representedObject as? String == "ty" }))
        _ = server.sendAction(server.action!, to: server.target)
        field.stringValue = "/tmp/draft/bin/python"
        view.controlTextDidChange(.init(name: NSText.didChangeNotification, object: field))
        let incoming = LanguageServiceSettings(workspaces: [b.rawValue.uuidString: .init(serverID: "pyright")])
        view.render([registration.settingsKey: incoming])
        view.configureWorkspace(id: a, folders: [first, second], selectedFolderID: first.id)
        #expect(field.stringValue == "/tmp/draft/bin/python")
        #expect(server.selectedItem?.representedObject as? String == "ty")
        var saved: [String: LanguageServiceSettings]?
        view.onChange = { saved = $0 }
        _ = apply.sendAction(apply.action!, to: apply.target)
        #expect(saved?[registration.settingsKey]?.workspace(a).serverID == "ty")
        #expect(saved?[registration.settingsKey]?.workspace(b).serverID == "pyright")
        scope.selectItem(at: 2); _ = scope.sendAction(scope.action!, to: scope.target)
        folder.selectItem(at: 1); _ = folder.sendAction(folder.action!, to: folder.target)
        field.stringValue = "/tmp/second/bin/python"
        _ = apply.sendAction(apply.action!, to: apply.target)
        #expect(saved?[registration.settingsKey]?.workspace(a).folders[second.id]?.interpreterPath == "/tmp/second/bin/python")
        #expect(saved?[registration.settingsKey]?.workspace(a).folders[first.id] == nil)
        view.configureWorkspace(id: b, folders: [first], selectedFolderID: first.id)
        #expect(scope.indexOfSelectedItem == 1)
        #expect(field.stringValue.isEmpty)
    }

    @Test func workspaceScopeChoicesAreExplicit() throws {
        _ = NSApplication.shared
        let view = LanguageServicesSettingsView()
        view.refreshLocalization(LocalizationCatalog(language: .english))
        let scope = try #require(descendants(view).first { $0.identifier?.rawValue == "duckpad.settings.language-services.scope" } as? NSPopUpButton)
        #expect(scope.itemTitles == ["All defaults", "Current workspace", "Selected folder"])
    }

}
