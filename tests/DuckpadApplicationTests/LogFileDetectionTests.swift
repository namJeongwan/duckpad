import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
import Testing

@Suite struct LogFileDetectionTests {
    @Test func commonPythonRustJavaAndStructuredLogsUseOneDetectionPath() throws {
        let detector = LanguageDetector(registry: try LanguageManifestLoader().loadBundled())
        for text in ["ERROR:my.logger:failed 한글\n", "2026-10-22T10:20:30Z WARN my_crate: request failed\n",
                     "2026-10-22 10:20:30.120 INFO [main] example.Class - ready\n", "{\"level\":\"error\",\"message\":\"failed\"}\n",
                     "\u{1b}[31m색상\u{1b}[0m\n", "INFO ready\nDEBUG details\n"] {
            #expect(detector.detect(filename: "output.txt", contentPrefix: Data(text.utf8)).languageID == .log)
        }
        #expect(detector.detect(filename: "app.log", contentPrefix: Data()).languageID == .log)
        #expect(detector.detect(filename: "app.log.2026-10-22", contentPrefix: Data()).languageID == .log)
        #expect(detector.detect(filename: "syslog", contentPrefix: Data()).languageID == .log)
        #expect(detector.detect(filename: "app.log.gz", contentPrefix: Data()).languageID != .log)
        #expect(detector.detect(filename: "app.log", contentPrefix: Data("ERROR:x\n".utf8), override: .manual(.plainText)).languageID == .plainText)
        #expect(detector.detect(filename: "code.py", contentPrefix: Data("# INFO x\n# ERROR y\n".utf8)).languageID.rawValue == "python")
    }
    @Test func ordinaryTextIncompleteEscapesAndProbeSuffixDoNotTriggerLogMode() {
        for text in ["Please review the error message.", "Some information about a warning.", "\u{1b}[31", "\u{1b}]8;;https://example.com\u{7}", "{\"message\":\"error\"}"] {
            #expect(!LogFileDetection.matches(Data(text.utf8)))
        }
        let text = String(repeating: "ordinary text\n", count: 2_000) + "ERROR:logger:too far\n"
        #expect(!LogFileDetection.matches(Data(text.utf8)))
        #expect(!LogFileDetection.isRotatedLogFilename("app.log.gz"))
    }
}
