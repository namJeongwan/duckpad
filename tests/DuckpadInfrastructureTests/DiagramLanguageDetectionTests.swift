import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
import Testing

@Test func diagramExtensionsDetectWithoutTakingOverMarkdownOrPlainText() throws {
    let registry = try LanguageManifestLoader().loadBundled()
    let detector = LanguageDetector(registry: registry)
    for (name, language) in [("graph.d2", "d2"), ("GRAPH.D2", "d2"), ("graph.mmd", "mermaid"), ("graph.mermaid", "mermaid")] {
        #expect(detector.detect(filename: name, contentPrefix: Data()).languageID.rawValue == language)
        #expect(registry[.init(rawValue: language)]?.supportTier == .structural)
    }
    #expect(detector.detect(filename: "note.md", contentPrefix: Data("flowchart LR\nA-->B".utf8)).languageID.rawValue == "markdown")
    #expect(detector.detect(filename: "note.txt", contentPrefix: Data("a -> b".utf8)).languageID == .plainText)
}
