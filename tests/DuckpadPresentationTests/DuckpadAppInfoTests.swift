import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
@testable import DuckpadPresentation
import Testing

@Suite(.serialized) @MainActor struct DuckpadAppInfoTests {
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
            #expect(about.updateTitle.stringValue == "Duckpad 0.2.0 is available")
            #expect(about.updateButton.title == "Download Update")
            about.render(.checking)
            #expect(!about.updateButton.isEnabled)
            about.render(.failed)
            #expect(about.updateButton.title == "Try Again")
            #expect(about.updateButton.isEnabled)
        }
        #expect(target.appInfo.diagnosticDescription.contains("Version 0.1.3 (4)"))
    }

    @Test func projectMenusUseAnApplicationLifetimeTarget() throws {
        let target = DuckpadAppInfoController(appInfo: .init(version: "0.2.0", build: "5"), loadRelease: { nil })
        let document = DuckpadWindowController(workspace: ScratchWorkspaceUseCase(store: InMemorySessionStore()), automaticallyStarts: false)
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
