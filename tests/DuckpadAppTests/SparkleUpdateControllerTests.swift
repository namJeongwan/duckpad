import AppKit
import Sparkle
import Testing
@testable import DuckpadApp

// The public NSSecureCoding initializer is the only public constructor for this
// Sparkle state. Zero values represent a scheduled, not-yet-downloaded update.
private final class ScheduledUpdateStateCoder: NSCoder {
    override var allowsKeyedCoding: Bool { true }
    override func decodeInteger(forKey key: String) -> Int { 0 }
    override func decodeBool(forKey key: String) -> Bool { false }
}

@Suite(.serialized) @MainActor
struct SparkleUpdateControllerTests {
    @Test func dismissingUpdateKeepsBadgeAndAllowsAnotherPresentation() throws {
        _ = NSApplication.shared
        let controller = SparkleUpdateController()
        let item = try updateItem()
        let state = try #require(SPUUserUpdateState(coder: ScheduledUpdateStateCoder()))
        var version: String?
        controller.onAvailableVersion = { version = $0 }
        controller.standardUserDriverWillHandleShowingUpdate(false, forUpdate: item, state: state)
        #expect(version == "9.9.9")
        controller.standardUserDriverWillFinishUpdateSession()
        #expect(version == "9.9.9")
        controller.standardUserDriverWillHandleShowingUpdate(true, forUpdate: item, state: state)
        controller.standardUserDriverWillFinishUpdateSession()
        #expect(version == "9.9.9")
    }

    @Test func failedCheckPreservesBadgeButConfirmedNoUpdateClearsIt() throws {
        _ = NSApplication.shared
        let controller = SparkleUpdateController()
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
            userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil), delegate: nil)
        let state = try #require(SPUUserUpdateState(coder: ScheduledUpdateStateCoder()))
        var version: String?
        controller.onAvailableVersion = { version = $0 }
        controller.standardUserDriverWillHandleShowingUpdate(false, forUpdate: try updateItem(), state: state)
        controller.standardUserDriverWillFinishUpdateSession()
        controller.updater(updater, didFinishUpdateCycleFor: .updates,
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        #expect(version == "9.9.9")
        controller.updaterDidNotFindUpdate(updater,
            error: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue)))
        #expect(version == nil)
    }

    @Test(arguments: [SPUUserUpdateChoice.dismiss, .skip, .install])
    func onlyExplicitSkipClearsKnownUpdate(choice: SPUUserUpdateChoice) throws {
        _ = NSApplication.shared
        let controller = SparkleUpdateController()
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
            userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil), delegate: nil)
        let state = try #require(SPUUserUpdateState(coder: ScheduledUpdateStateCoder()))
        let item = try updateItem()
        var version: String?
        controller.onAvailableVersion = { version = $0 }
        controller.standardUserDriverWillHandleShowingUpdate(false, forUpdate: item, state: state)
        controller.updater(updater, userDidMake: choice, forUpdate: item, state: state)
        controller.standardUserDriverWillFinishUpdateSession()
        controller.updater(updater, didFinishUpdateCycleFor: .updates,
            error: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue)))
        #expect(version == (choice == .skip ? nil : "9.9.9"))
    }

    private func updateItem() throws -> SUAppcastItem {
        try #require(SUAppcastItem(dictionary: [
            "title": "Duckpad 9.9.9",
            "sparkle:shortVersionString": "9.9.9",
            "enclosure": ["url": "https://example.com/Duckpad.zip", "sparkle:version": "999",
                          "sparkle:shortVersionString": "9.9.9", "length": "1", "type": "application/octet-stream"]
        ]))
    }
}
