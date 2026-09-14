import AppKit
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadInfrastructure
import Testing

@Suite(.serialized) @MainActor
struct BuiltInFormattingTests {
    @Test func timedOutAndCancelledEvaluationsDrainBeforeStartingAnotherRuntime() async throws {
        _ = NSApplication.shared
        for cancel in [false, true] {
            var created: [PrettierWebRuntime] = []
            let formatter = BundledPrettierFormatter(timeout: .seconds(3), idleTimeout: .seconds(30)) { _, timeout in
                let script = created.isEmpty
                    ? "globalThis.duckpadFormat = () => { const end = Date.now() + 4500; while (Date.now() < end) {} return '{}\\n'; };"
                    : "globalThis.duckpadFormat = () => '{}\\n';"
                let runtime = PrettierWebRuntime(script: script, timeout: timeout)
                created.append(runtime)
                return runtime
            }
            let task = Task { try await formatter.format(.init(text: "{}", parser: "json")) }
            let startupDeadline = ContinuousClock.now + .seconds(5)
            while created.first?.isEvaluating != true, ContinuousClock.now < startupDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(created.first?.isEvaluating == true)
            // Give the already submitted synchronous JS call time to start.
            try await Task.sleep(for: .milliseconds(100))
            if cancel {
                task.cancel()
                await #expect(throws: CancellationError.self) { try await task.value }
            } else {
                await #expect(throws: FormattingFailure.timedOut) { try await task.value }
            }
            #expect(created.first?.isEvaluating == true)
            await #expect(throws: FormattingFailure.busy) { try await formatter.format(.init(text: "{}", parser: "json")) }
            #expect(formatter.runtimeStartCount == 1)
            let drainDeadline = ContinuousClock.now + .seconds(6)
            while created.first?.isEvaluating == true, ContinuousClock.now < drainDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(created.first?.isEvaluating == false)
            #expect(try await formatter.format(.init(text: "{}", parser: "json")) == "{}\n")
            #expect(formatter.runtimeStartCount == 2)
        }
    }

    @Test func compactJSONBundleMatchesFullBundleAndUpgradesOnce() async throws {
        _ = NSApplication.shared
        let compact = BundledPrettierFormatter()
        let full = BundledPrettierFormatter()
        _ = try await full.format(.init(text: "a: 1", parser: "yaml"))
        let samples = [
            ("json", #"{"unicode":"\uD83E\uDD86 한글","number":1e-7,"array":[1,2,3],"slash":"\/"}"#),
            ("jsonc", "{/* keep */\"a\":1,\"b\":[1,2,3],}"),
            ("json5", "{a:'한글', b:0xff, c:[1,2,3,],}"),
        ]
        for tabs in [false, true] {
            var settings = FormattingSettings()
            settings.useTabs = tabs; settings.tabWidth = 4; settings.printWidth = 40
            settings.singleQuote = true
            for (parser, text) in samples {
                let request = FormattingRequest(text: text, parser: parser, settings: settings)
                let expected = try await full.format(request)
                #expect(try await compact.format(request) == expected)
            }
        }
        #expect(compact.runtimeStartCount == 1)
        #expect(try await compact.format(.init(text: "a:   1", parser: "yaml")) == "a: 1\n")
        #expect(compact.runtimeStartCount == 2)
        #expect(try await compact.format(.init(text: "{}", parser: "json")) == "{}\n")
        #expect(compact.runtimeStartCount == 2)
    }

    @Test func runtimeIsReusedAndReleasedAfterIdle() async throws {
        _ = NSApplication.shared
        let formatter = BundledPrettierFormatter(idleTimeout: .milliseconds(100))
        #expect(try await formatter.format(.init(text: "{}", parser: "json")) == "{}\n")
        #expect(try await formatter.format(.init(text: "{\"a\":1}", parser: "json")) == "{ \"a\": 1 }\n")
        #expect(formatter.runtimeStartCount == 1)
        #expect(formatter.hasResidentRuntime)
        let deadline = ContinuousClock.now + .seconds(3)
        while formatter.hasResidentRuntime, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!formatter.hasResidentRuntime)
        _ = try await formatter.format(.init(text: "{}", parser: "json"))
        #expect(formatter.runtimeStartCount == 2)
    }

    @Test func cancellationDiscardsOnlyItsRuntimeAndSyntaxFailureCanReuseIt() async throws {
        _ = NSApplication.shared
        let formatter = BundledPrettierFormatter()
        let first = Task { try await formatter.format(.init(text: "{}", parser: "json")) }
        while formatter.runtimeStartCount == 0 { await Task.yield() }
        await #expect(throws: FormattingFailure.busy) { try await formatter.format(.init(text: "{}", parser: "json")) }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(!formatter.hasResidentRuntime)
        await #expect(throws: FormattingFailure.self) { try await formatter.format(.init(text: "{broken", parser: "json")) }
        let starts = formatter.runtimeStartCount
        #expect(try await formatter.format(.init(text: "{}", parser: "json")) == "{}\n")
        #expect(formatter.runtimeStartCount == starts)
    }

    @Test func largeJSONAndSyntaxErrorsStayBounded() async throws {
        _ = NSApplication.shared
        let formatter = BundledPrettierFormatter()
        let privateText = String(repeating: "private-workflow-text 한글 🦆 ", count: 8_000)
        let object = ["prompt": privateText, "nested": "line one\nline two"]
        let input = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let output = try await formatter.format(.init(text: input, parser: "json"))
        #expect(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String] == object)
        do {
            _ = try await formatter.format(.init(text: input + "!", parser: "json"))
            Issue.record("Malformed JSON unexpectedly formatted")
        } catch FormattingFailure.invalidSyntax(let detail) {
            #expect(detail.count <= 300)
            #expect(!detail.contains("private-workflow-text"))
            #expect(!detail.contains("\n"))
            #expect(detail.contains("1:"))
        }
    }

    @Test func bundledParsersFormatOfflineAndAreIdempotent() async throws {
        _ = NSApplication.shared
        let formatter = BundledPrettierFormatter()
        let examples = [
            ("json", "{\"한글\":1,\"emoji\":\"🦆\"}", "\"한글\": 1"),
            ("jsonc", "{/* keep */\"a\":1}", "/* keep */"),
            ("json5", "{a:1,}", "a: 1"),
            ("babel", "const x={a:1,b:2}", "const x = { a: 1, b: 2 };"),
            ("typescript", "const x:number=1", "const x: number = 1;"),
            ("yaml", "a:   1\nb:   [1,2]", "a: 1"),
            ("html", "<DIV><p>hello</p></DIV>", "<div>"),
            ("css", "a{color:red}", "color: red;"),
            ("scss", "$a:red;a{color:$a}", "$a: red;"),
            ("markdown", "#   Title\n\n-   hello", "# Title"),
            ("graphql", "query{user{id}}", "query {"),
            ("xml", "<root a = '1'><b>한글</b></root>", "a='1'"),
            ("sql", "select * from users where id=1", "id = 1"),
        ]
        for (parser, input, expected) in examples {
            let result = try await formatter.format(.init(text: input, parser: parser))
            #expect(result.contains(expected), "\(parser): \(result)")
            #expect(result.hasSuffix("\n"))
            #expect(try await formatter.format(.init(text: result, parser: parser)) == result)
        }
    }

    @Test func optionsAndSQLDialectsReachTheBundledEngine() async throws {
        _ = NSApplication.shared
        let formatter = BundledPrettierFormatter()
        var settings = FormattingSettings()
        settings.singleQuote = true
        settings.semicolons = false
        let js = try await formatter.format(.init(text: "const x=\"hi\";", parser: "babel", settings: settings))
        #expect(js == "const x = 'hi'\n")
        for dialect in SQLFormattingDialect.allCases {
            settings.sqlDialect = dialect
            let sql = try await formatter.format(.init(text: "SELECT a FROM t WHERE id=1", parser: "sql", settings: settings))
            #expect(sql.contains("id = 1"))
        }
        let mixed = "<p>Hello <b>world</b>!</p>"
        #expect(try await formatter.format(.init(text: mixed, parser: "xml")) == mixed + "\n")
    }

    @Test func invalidInputSizeTimeoutAndCancellationDoNotReturnReplacementText() async throws {
        _ = NSApplication.shared
        let formatter = BundledPrettierFormatter()
        await #expect(throws: FormattingFailure.self) { try await formatter.format(.init(text: "{broken", parser: "json")) }
        await #expect(throws: FormattingFailure.tooLarge) {
            try await formatter.format(.init(text: String(repeating: "x", count: 1_024 * 1_024 + 1), parser: "babel"))
        }
        let short = BundledPrettierFormatter(timeout: .nanoseconds(1))
        await #expect(throws: FormattingFailure.timedOut) { try await short.format(.init(text: "{}", parser: "json")) }
        let task = Task { try await formatter.format(.init(text: "{}", parser: "json")) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await formatter.format(.init(text: "{\"a\":1}", parser: "json")) == "{ \"a\": 1 }\n")
    }
}
