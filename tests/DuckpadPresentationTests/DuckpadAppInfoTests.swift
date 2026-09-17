import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization
import DuckpadInfrastructure
@testable import DuckpadPresentation
import Testing

@Suite(.serialized) @MainActor struct DuckpadAppInfoTests {
    @Test func escapeClosesAboutWithAButtonFocusedAndCanReopen() throws {
        _ = NSApplication.shared
        let target = DuckpadAppInfoController(loadRelease: { nil })
        let about = DuckpadAboutWindowController(target: target)
        defer { about.close() }
        let window = try #require(about.window)
        about.showWindow(nil)
        window.makeFirstResponder(about.updateButton)
        #expect(window.isVisible)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        #expect(window.performKeyEquivalent(with: escape))
        #expect(!window.isVisible)
        about.showWindow(nil)
        #expect(window.isVisible)
        window.cancelOperation(nil)
        #expect(!window.isVisible)
    }

    @Test func externalUpdaterStatusReplacesIdleAboutState() throws {
        let target = DuckpadAppInfoController(loadRelease: { nil })
        target.updateStatus(.checking)
        #expect(target.state == .checking)
        let release = try #require(AppRelease(tag: "v0.7.0"))
        target.updateStatus(.available(release))
        #expect(target.state == .available(release))
        target.updateStatus(.current(release))
        #expect(target.state == .current(release))
        target.updateStatus(.failed)
        #expect(target.state == .failed)
    }

    @Test func cancellingExternalCheckEnablesRetryAndFinishingPreservesResults() throws {
        let target = DuckpadAppInfoController(loadRelease: { nil })
        target.onCheckForUpdates = { [weak target] in target?.updateStatus(.checking) }
        let check = NSMenuItem(title: "Check for Updates…",
            action: #selector(target.performCheckForUpdates(_:)), keyEquivalent: "")
        target.performCheckForUpdates()
        #expect(!target.validateMenuItem(check))
        // Sparkle's Cancel path completes without either an error or a result.
        target.finishUpdateCheck()
        #expect(target.state == .idle)
        #expect(target.validateMenuItem(check))
        target.performCheckForUpdates()
        let release = try #require(AppRelease(tag: "v0.7.0"))
        target.updateStatus(.available(release))
        target.finishUpdateCheck()
        #expect(target.state == .available(release))
        #expect(target.validateMenuItem(check))
    }

    @Test func installedUpdaterOwnsBothMenuAndAboutActions() async {
        var checks = 0
        var opened = false
        let target = DuckpadAppInfoController(loadRelease: { nil }, openURL: { _ in opened = true; return true })
        target.onCheckForUpdates = { checks += 1 }
        target.performCheckForUpdates()
        target.performUpdate()
        #expect(checks == 2)
        #expect(!opened)
        #expect(target.state == .idle)
    }

    @Test func updateBadgeTracksAvailabilityWithoutDuplicatingAccessories() throws {
        _ = NSApplication.shared
        let document = DuckpadWindowController(workspace: ScratchWorkspaceUseCase(store: InMemorySessionStore()), previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(), automaticallyStarts: false)
        defer { document.close() }
        let window = try #require(document.window)
        var clicks = 0
        document.showAvailableUpdate(version: "0.7.0") { clicks += 1 }
        let badge = try #require(window.titlebarAccessoryViewControllers.first as? UpdateTitlebarAccessoryController)
        #expect(badge.layoutAttribute == .right)
        badge.refreshLocalization(catalog: LocalizationCatalog(language: .korean))
        #expect(badge.button.title == "새로운 버전: 0.7.0")
        badge.button.performClick(nil)
        #expect(clicks == 1)
        document.showAvailableUpdate(version: "0.7.1") { clicks += 10 }
        #expect(window.titlebarAccessoryViewControllers.count == 1)
        #expect(badge.button.title.contains("0.7.1"))
        badge.button.performClick(nil)
        #expect(clicks == 11)
        document.showAvailableUpdate(version: nil) {}
        #expect(window.titlebarAccessoryViewControllers.isEmpty)
    }

    @Test func comparesVersionsWithoutOfferingDowngradesAndOpensTheRealRelease() async throws {
        let release = try #require(AppRelease(tag: "v0.10.0"))
        for installed in ["0.9.9", "0.10.0", "1.0.0"] {
            var opened: [URL] = []
            let target = DuckpadAppInfoController(
                appInfo: .init(version: installed, build: "4"),
                loadRelease: { release }, openURL: { opened.append($0); return true }
            )
            await target.checkForUpdates()
            #expect(target.state == (installed == "0.9.9" ? .available(release) : .current(release)))
            if installed == "0.9.9" {
                target.performUpdate()
                #expect(opened == [release.url])
            }
            target.performStarOnGitHub()
            target.performReportIssue()
            #expect(opened.suffix(2) == [DuckpadProject.repositoryURL, DuckpadProject.issuesURL])
        }
    }

    @Test func distinguishesDevelopmentBuildsNoReleasesAndFailures() async throws {
        let release = try #require(AppRelease(tag: "v0.1.3"))
        let development = DuckpadAppInfoController(appInfo: .init(version: nil, build: nil), loadRelease: { release })
        await development.checkForUpdates()
        #expect(development.state == .development(release))
        #expect(development.appInfo.versionDescription == "Development build")
        let empty = DuckpadAppInfoController(loadRelease: { nil })
        await empty.checkForUpdates()
        #expect(empty.state == .noRelease)
        let failed = DuckpadAppInfoController(loadRelease: { throw URLError(.notConnectedToInternet) })
        await failed.checkForUpdates()
        #expect(failed.state == .failed)
    }

    @Test func acceptsTwoPartPackageAndReleaseVersionsWithoutOfferingDowngrades() async throws {
        let release = try #require(AppRelease(tag: "v1.1.9"))
        let target = DuckpadAppInfoController(appInfo: .init(version: "1.2", build: "4"), loadRelease: { release })
        await target.checkForUpdates()
        #expect(target.state == .current(release))
        #expect(target.appInfo.versionDescription == "Version 1.2.0 (4)")
        #expect(AppRelease(tag: "v1.2")?.version == SemanticVersion("1.2.0"))
    }

    private actor ReleaseGate {
        var calls = 0
        var pending: CheckedContinuation<AppRelease?, Never>?
        func load() async -> AppRelease? {
            calls += 1
            return await withCheckedContinuation { pending = $0 }
        }
        func waitForRequest() async { while pending == nil { await Task.yield() } }
        func finish() { pending?.resume(returning: AppRelease(tag: "v1.0.0")); pending = nil }
    }

    @Test func simultaneousChecksShareOneRequest() async {
        let gate = ReleaseGate()
        let target = DuckpadAppInfoController(appInfo: .init(version: "0.1.3", build: "4"), loadRelease: { await gate.load() })
        let task = Task { await target.checkForUpdates() }
        await gate.waitForRequest()
        #expect(target.state == .checking)
        await target.checkForUpdates()
        #expect(await gate.calls == 1)
        await gate.finish()
        await task.value
        #expect(target.state == .available(AppRelease(tag: "v1.0.0")!))
    }

    @Test func aboutWindowRendersUpdateStatesInBothAppearances() throws {
        let target = DuckpadAppInfoController(appInfo: .init(version: "0.1.3", build: "4"), loadRelease: { nil })
        let about = DuckpadAboutWindowController(target: target)
        defer { about.close() }
        let release = try #require(AppRelease(tag: "v0.2.0"))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            about.window?.appearance = NSAppearance(named: appearance)
            about.render(.available(release))
            about.window?.contentView?.layoutSubtreeIfNeeded()
            #expect(about.updateTitle.stringValue == "New version: 0.2.0")
            #expect(about.updateButton.title == "Download Update")
            about.render(.checking)
            #expect(!about.updateButton.isEnabled)
            about.render(.failed)
            #expect(about.updateButton.title == "Try Again")
            #expect(about.updateButton.isEnabled)
        }
        #expect(target.appInfo.diagnosticDescription.contains("Version 0.1.3 (4)"))
    }

    @Test func aboutLayoutFitsEveryLanguageAndUpdateState() throws {
        let target = DuckpadAppInfoController(appInfo: .init(version: "0.6.5", build: "43"), loadRelease: { nil })
        let about = DuckpadAboutWindowController(target: target)
        defer { about.close() }
        let window = try #require(about.window)
        let content = try #require(window.contentView)
        let release = try #require(AppRelease(tag: "v0.6.6"))
        let states: [DuckpadAppInfoController.UpdateState] = [.idle, .checking, .current(release),
            .available(release), .development(release), .noRelease, .failed]
        for language in AppLanguage.allCases where language != .system {
            about.refreshLocalization(catalog: LocalizationCatalog(language: language))
            for state in states {
                about.render(state)
                content.layoutSubtreeIfNeeded()
                let status = about.updateTitle.convert(about.updateTitle.bounds, to: content)
                let action = about.updateButton.convert(about.updateButton.bounds, to: content)
                #expect(content.bounds.contains(status))
                #expect(content.bounds.contains(action))
                #expect(status.maxX < action.minX)
                for label in [about.updateTitle, about.updateDetail] where !label.isHidden {
                    let cell = try #require(label.cell)
                    let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0,
                        width: label.bounds.width, height: 1000)).height
                    #expect(label.bounds.height + 1 >= needed)
                }
            }
        }
    }

    @Test func projectMenusUseAnApplicationLifetimeTarget() throws {
        let target = DuckpadAppInfoController(appInfo: .init(version: "0.2.0", build: "5"), loadRelease: { nil })
        let document = DuckpadWindowController(workspace: ScratchWorkspaceUseCase(store: InMemorySessionStore()), previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(), automaticallyStarts: false)
        let menu = DuckpadMainMenuFactory.make(target: document, projectTarget: target)
        defer { document.close() }
        let app = try #require(menu.items.first?.submenu)
        #expect(!app.items.contains { $0.target === target })
        let help = try #require(menu.items.first(where: { $0.submenu?.title == "Help" })?.submenu)
        for title in ["Check for Updates…", "Release Notes", "Report an Issue…", "Star Duckpad on GitHub", "About Duckpad"] {
            #expect(help.items.first(where: { $0.title == title })?.target === target)
        }
        #expect(!help.items.contains { $0.title == "Duckpad User Guide" })
        help.update()
        #expect(help.items.last?.title == "v0.2.0")
        #expect(help.items.last?.isEnabled == false)
        #expect(help.items.last?.action == nil)
        #expect(document.window?.titlebarAccessoryViewControllers.isEmpty == true)
    }
}
