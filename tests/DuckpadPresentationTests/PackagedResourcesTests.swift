import Foundation
@testable import DuckpadPresentation
import Testing

struct PackagedResourcesTests {
    @Test func packagedAppResolvesItsOwnResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root)
        let resources = try #require(app.resourceURL)
        let packaged = resources.appendingPathComponent("Duckpad_DuckpadPresentation.bundle")
        try FileManager.default.createDirectory(at: packaged, withIntermediateDirectories: true)
        try Data("packaged fixture".utf8).write(to: packaged.appendingPathComponent("marker.txt"))
        let resolved = try #require(DuckpadPresentationResources.resolve(in: app))
        #expect(resolved.bundleURL.standardizedFileURL == packaged.standardizedFileURL)
        let marker = try #require(resolved.url(forResource: "marker", withExtension: "txt"))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "packaged fixture")
    }

    @Test func missingPackagedResourcesDoNotFallBackToDeveloperBuildOrTrap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root)
        #expect(DuckpadPresentationResources.resolve(in: app) == nil)
    }

    @Test func previewAssetsAreAvailableDuringSwiftPackageTests() throws {
        let bundle = try #require(DuckpadPresentationResources.bundle)
        #expect(bundle.url(forResource: "preview", withExtension: "js", subdirectory: "MarkdownPreview") != nil)
        #expect(bundle.url(forResource: "katex", withExtension: "css", subdirectory: "MarkdownPreview") != nil)
    }

    private func makeApp(at root: URL) throws -> Bundle {
        let url = root.appendingPathComponent("Fixture.app")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "test.duckpad.packaged-resources", "CFBundlePackageType": "APPL",
            "CFBundleName": "Fixture", "CFBundleVersion": "1",
        ], format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        return try #require(Bundle(url: url))
    }
}
