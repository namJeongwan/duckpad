import Foundation
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization
@testable import DuckpadPresentation
import Testing

struct GeneratedDocumentTitleTests {
    private func tab(_ title: String, generated: GeneratedDocumentTitle?, path: String? = nil) -> TabSnapshot {
        TabSnapshot(id: TabID(), title: title, isActive: true, isDirty: true, isPinned: false,
                    buffer: EditorBufferDescriptor(bufferID: BufferID(), revision: 0), fullPath: path, generatedTitle: generated)
    }

    @Test func generatedLabelsUseEveryCatalogWithoutTranslatingUserFilenames() {
        for language in AppLanguage.allCases where language != .system {
            let catalog = LocalizationCatalog(language: language)
            let number = 12.formatted(.number.locale(catalog.locale))
            #expect(tab("new 12", generated: .untitled(12)).localizedTitle(catalog: catalog) == catalog.text("new %1$@", arguments: [number]))
            #expect(tab("new 12 (restored)", generated: .restored("new 12")).localizedTitle(catalog: catalog) == catalog.text("%1$@ (restored)", arguments: ["new 12"]))
            #expect(tab("new 12 (restored)", generated: nil).localizedTitle(catalog: catalog) == "new 12 (restored)")
            #expect(tab("new 12", generated: .untitled(12), path: "/tmp/new 12").localizedTitle(catalog: catalog) == "new 12")
        }
    }

    @Test func generatedMetadataSurvivesRecoveryAndOldArchivesRemainReadable() throws {
        var session = ScratchSession(); let id = session.addUntitled()
        let data = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(ScratchSession.self, from: data)
        #expect(try restored.document(for: id).generatedTitle == .untitled(1))
        var document = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored.document(for: id))) as? [String: Any])
        document.removeValue(forKey: "generatedTitle")
        let old = try JSONDecoder().decode(ScratchDocument.self, from: JSONSerialization.data(withJSONObject: document))
        #expect(old.generatedTitle == nil)
        #expect(old.title == "new 1")
        let binding = FileBinding(canonicalPath: "/tmp/new 1", encoding: .utf8, byteOrderMark: .absent, lineEnding: .lf,
                                  observedIdentity: FileIdentity(canonicalPath: "/tmp/new 1", device: 1, inode: 1, byteCount: 0, modifiedNanoseconds: 0, contentToken: ""))
        try session.bindFile(tabID: id, binding: binding, title: "new 1")
        #expect(try session.document(for: id).generatedTitle == nil)
        #expect(try session.document(for: id).title == "new 1")
    }

    @Test @MainActor func compareChoicesDisambiguateLocalizedGeneratedNameCollisions() throws {
        let catalog = LocalizationCatalog(language: .korean)
        let generated = tab("new 12", generated: .untitled(12))
        let filename = generated.localizedTitle(catalog: catalog)
        let saved = tab(filename, generated: nil, path: "/tmp/" + filename)
        let choices = NativeOpenDocumentComparePresenter.choices(source: generated, candidates: [saved], catalog: catalog)
        #expect(choices.count == 1)
        #expect(choices.first?.label == filename + " — /tmp/" + filename)
    }
}
