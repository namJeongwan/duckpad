import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
@testable import DuckpadLocalization
import Testing
@testable import DuckpadPresentation

@Suite(.serialized) @MainActor
struct LocalizationTests {
    @Test func settingsPreserveLanguageAndDecodeOlderArchives() throws {
        for language in AppLanguage.allCases {
            let settings = AppSettings(appLanguage: language)
            let data = try JSONEncoder().encode(settings)
            #expect(try JSONDecoder().decode(AppSettings.self, from: data).appLanguage == language)
        }
        let data = try JSONEncoder().encode(AppSettings.defaults)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "appLanguage")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(AppSettings.self, from: legacy).appLanguage == .system)
        object["appLanguage"] = "future-language"
        let future = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(AppSettings.self, from: future).appLanguage == .system)
    }

    @Test func systemPreferencesAndExplicitOverridesResolveDeterministically() {
        #expect(LocalizationCatalog(language: .system, preferredLanguages: ["ko-KR", "en"]).language == .korean)
        #expect(LocalizationCatalog(language: .system, preferredLanguages: ["ja-JP"]).language == .japanese)
        #expect(LocalizationCatalog(language: .system, preferredLanguages: ["pt-BR"]).language == .brazilianPortuguese)
        #expect(LocalizationCatalog(language: .system, preferredLanguages: ["zh-Hans-CN"]).language == .simplifiedChinese)
        #expect(LocalizationCatalog(language: .system, preferredLanguages: ["es-ES"]).language == .english)
        #expect(LocalizationCatalog(language: .german, preferredLanguages: ["ko"]).language == .german)
    }

    @Test func missingTranslationUsesEnglishRatherThanAKey() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        defer { try? FileManager.default.removeItem(at: directory) }
        for locale in ["en", "ko"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(locale + ".lproj"), withIntermediateDirectories: true)
        }
        try Data("\"fallback.test\" = \"English fallback\";".utf8).write(to: directory.appendingPathComponent("en.lproj/Localizable.strings"))
        try Data("\"another.key\" = \"다른 문구\";".utf8).write(to: directory.appendingPathComponent("ko.lproj/Localizable.strings"))
        let catalog = LocalizationCatalog(language: .korean, preferredLanguages: [], resources: try #require(Bundle(url: directory)))
        #expect(catalog.text("fallback.test") == "English fallback")
        #expect(catalog.text("another.key") == "다른 문구")
    }

    @Test func catalogsLoadTranslationsFormatsAndPluralRules() {
        let ko = LocalizationCatalog(language: .korean)
        #expect(ko.text("App Language") == "앱 언어")
        #expect(ko.text("Version %1$@", arguments: ["0.3.0"]) == "버전 0.3.0")
        #expect(ko.text("missing.translation.key") == "missing.translation.key")
        let en = LocalizationCatalog(language: .english)
        #expect(en.text("search.matches", arguments: [1]) == "1 match")
        #expect(en.text("search.matches", arguments: [2]) == "2 matches")
        #expect(en.text("search.matches", arguments: [0]) == "0 matches")
        #expect(LocalizationCatalog(language: .french).text("search.matches", arguments: [1]) == "1 correspondance")
        #expect(LocalizationCatalog(language: .french).text("search.matches", arguments: [2]) == "2 correspondances")
        for language in AppLanguage.allCases where language != .system {
            let catalog = LocalizationCatalog(language: language)
            #expect(!catalog.text("search.replaced", arguments: [2]).contains("%"))
            #expect(!catalog.text("documents.saveBeforeClosing", arguments: [1]).contains("%"))
            if language != .english { #expect(catalog.text("App Language") != "App Language", "Language: \(language.rawValue)") }
        }
    }

    @Test(arguments: AppLanguage.allCases.filter { $0 != .system })
    func translatedMenusKeepRoutingAndBilingualSearch(language: AppLanguage) throws {
        let controller = DuckpadWindowController(workspace: ScratchWorkspaceUseCase(store: InMemorySessionStore()), automaticallyStarts: false)
        defer { controller.close() }
        let recent = URL(fileURLWithPath: "/tmp/File")
        let menu = DuckpadMainMenuFactory.make(target: controller, recentDocumentURLs: [recent])
        let catalog = LocalizationCatalog(language: language)
        MenuLocalization.apply(to: menu, catalog: catalog)
        let search = try #require(menu.items.first { $0.identifier?.rawValue == "Search" }?.submenu)
        let find = try #require(search.items.first { $0.action == #selector(DuckpadWindowController.performShowFind(_:)) })
        #expect(find.title == catalog.text("Find…"))
        #expect(find.keyEquivalent == "f")
        #expect(find.target === controller)
        func allItems(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
        }
        let collapse = try #require(allItems(menu).first { MenuLocalization.sourceKey(for: $0) == "Collapse Current Block" })
        #expect(collapse.accessibilityLabel() == catalog.text("Collapse current code block"))
        // Reapplying is safe even though AppKit supplies selector-based identifiers.
        MenuLocalization.apply(to: menu, catalog: catalog)
        #expect(find.title == catalog.text("Find…"))
        let bar = WindowCommandBarView(frame: NSRect(x: 0, y: 0, width: 1200, height: 27))
        bar.apply(mainMenu: menu)
        #expect(bar.menu(named: "Search") === search)
        #expect(bar.button(named: "Search")?.identifier?.rawValue == "Search")
        #expect(bar.button(named: "Search")?.title == catalog.text("Search"))
        #expect(bar.prepareMenuForPresentation(named: "Search") === search)
        bar.dismissMenu()
        let commands = CommandPaletteRegistry.commands(in: menu)
        let english = CommandPaletteSearch.matchingIndices(in: commands, query: "Find Next")
        let translated = CommandPaletteSearch.matchingIndices(in: commands, query: catalog.text("Find Next"))
        #expect(english.contains { commands[$0].item.action == #selector(DuckpadWindowController.performFindNext(_:)) })
        #expect(translated.contains { commands[$0].item.action == #selector(DuckpadWindowController.performFindNext(_:)) })
        // A user file named like a UI key is never translated.
        func recentItems(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { item in [item] + (item.submenu.map(recentItems) ?? []) }
        }
        #expect(recentItems(menu).first { $0.representedObject as? URL == recent }?.title == "File")
    }

    @Test(arguments: AppLanguage.allCases.filter { $0 != .system })
    func translatedViewsRenderWithoutChangingCategoryIDs(language: AppLanguage) throws {
        // Synchronous MainActor work: no language change spans an await or another UI task.
        let original = L10n.catalog.language
        L10n.configure(language: language)
        defer { L10n.configure(language: original) }
        let settings = DuckpadSettingsWindowController()
        settings.window?.appearance = NSAppearance(named: .darkAqua)
        settings.configure(settings: AppSettings(appLanguage: language)) { .saved($0) }
        defer { settings.close() }
        #expect(settings.appLanguage.numberOfItems == 9)
        #expect(settings.appLanguage.selectedItem?.representedObject as? String == language.rawValue)
        settings.selectCategory("General")
        #expect(settings.selectedCategory == "General")
        settings.window?.orderBack(nil)
        let view = try #require(settings.window?.contentView)
        view.layoutSubtreeIfNeeded()
        #expect(settings.appLanguage.frame.width > 0)
        #expect(settings.appLanguage.convert(settings.appLanguage.bounds, to: view).maxX <= view.bounds.maxX)
        let target = DuckpadAppInfoController(appInfo: .init(version: "0.3.0", build: "7"), loadRelease: { nil })
        let about = DuckpadAboutWindowController(target: target)
        defer { about.close() }
        about.render(.failed)
        about.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(about.updateButton.title == L10n.text("Try Again"))
        if let directory = ProcessInfo.processInfo.environment["DUCKPAD_LOCALIZATION_SNAPSHOTS"] {
            let destination = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for (name, content) in [("preferences", view), ("about", try #require(about.window?.contentView))] {
                let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: destination.appendingPathComponent("\(language.rawValue)-\(name).png"))
            }
        }
    }

    @Test func languagePickerSavesChoiceWithoutChangingTheRunningLanguage() async {
        let controller = DuckpadSettingsWindowController()
        defer { controller.close() }
        var stored = AppSettings.defaults
        controller.configure(settings: stored) { settings in stored = settings; return .saved(settings) }
        controller.appLanguage.selectItem(at: AppLanguage.allCases.firstIndex(of: .japanese)!)
        _ = controller.appLanguage.sendAction(controller.appLanguage.action, to: controller.appLanguage.target)
        for _ in 0..<100 where controller.isUpdating { await Task.yield() }
        #expect(stored.appLanguage == .japanese)
        #expect(L10n.catalog.language == .english)
    }
}
