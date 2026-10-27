import DuckpadApplication
import Testing

struct TerminalLocaleEnvironmentTests {
    @Test func explicitShellLocaleAndOverridesSurviveWithoutUnrelatedVariables() {
        let inherited = ["LANG": "ko_KR.UTF-8", "LC_ALL": "C", "LC_TIME": "de_DE.UTF-8",
                         "LANGUAGE": "ko:en", "GITHUB_TOKEN": "test-only", "DYLD_INSERT_LIBRARIES": "test-only"]
        #expect(TerminalLocaleEnvironment.values(inherited: inherited, systemLocaleIdentifier: "ja_JP") ==
                ["LANG": "ko_KR.UTF-8", "LC_ALL": "C", "LC_TIME": "de_DE.UTF-8", "LANGUAGE": "ko:en"])
    }

    @Test(arguments: ["ko_KR", "ja_JP", "de_DE", "en_US"])
    func finderLaunchUsesSystemLocaleWithoutOverridingCategorySettings(identifier: String) {
        let result = TerminalLocaleEnvironment.values(inherited: ["LC_NUMERIC": "C"], systemLocaleIdentifier: identifier)
        #expect(result == ["LANG": identifier + ".UTF-8", "LC_NUMERIC": "C"])
    }

    @Test func invalidSystemLocaleAndMalformedEnvironmentHaveAWorkingUTF8Fallback() {
        let result = TerminalLocaleEnvironment.values(inherited: ["LANG": "", "LC_CTYPE": "ko\0_KR", "LC_ALL": String(repeating: "x", count: 4096)],
                                                       systemLocaleIdentifier: "missing_locale")
        #expect(result == ["LANG": "en_US.UTF-8"])
    }
}
