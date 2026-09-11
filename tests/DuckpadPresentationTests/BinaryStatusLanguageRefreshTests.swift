import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization
@testable import DuckpadPresentation
import Testing

@Suite(.serialized) @MainActor
struct BinaryStatusLanguageRefreshTests {
    @Test func languageRefreshPreservesBinaryAndLoadingStatus() {
        let bar = DocumentStatusBarView()
        let progress = FileLoadingProgress(path: "/test/image.dmg", loadedByteCount: 25, totalByteCount: 100)
        // Loading is visible even before an editor buffer is attached.
        bar.showLoading(progress)
        let korean = LocalizationCatalog(language: .korean)
        bar.refreshLocalization(catalog: korean)
        #expect(bar.lengthLabel.stringValue == "불러오는 중: 25%")
        bar.apply(.init(length: 25, lines: 1, line: 1, column: 1,
                        selectedCharacters: 0, selectedLines: 0, isOvertype: false), binarySummary: "1.23 GB")
        for language in [AppLanguage.english, .korean] {
            let catalog = LocalizationCatalog(language: language)
            bar.refreshLocalization(catalog: catalog)
            #expect(bar.lengthLabel.stringValue == catalog.text("Loading: %1$@%%", arguments: ["25"]))
            #expect(bar.lengthLabel.toolTip == progress.path)
            #expect(bar.modeButton.title == "—")
        }
        bar.showLoading(nil)
        #expect(bar.lengthLabel.stringValue == "1.23 GB")
        bar.refreshLocalization(catalog: korean)
        #expect(bar.lengthLabel.stringValue == "1.23 GB")
        #expect(bar.modeButton.title == "—")
        #expect(PresentationErrorText.message(FileOperationFailure.readOnly, catalog: korean)
                == korean.text("Binary files are read-only and cannot be saved."))
    }
}
