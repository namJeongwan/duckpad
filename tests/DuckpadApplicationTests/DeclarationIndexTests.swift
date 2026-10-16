import DuckpadApplication
import Foundation
import Testing

@Suite struct DeclarationIndexTests {
    @Test func referencesExcludeDeclarationsCommentsAndLiterals() async {
        let source = "func 이름() {}\n이름()\nlet 이름Else = 0\n// 이름()\n\"이름\"\n이름()"
        let index = await BuiltinDeclarationAnalyzer().index(utf8: Data(source.utf8), language: "swift")
        let matches = index.matches(named: "이름", kind: .references)
        #expect(matches.map(\.line) == [2, 6])
        #expect(matches.allSatisfy { $0.range.length == 6 })
        #expect(matches.map { $0.preview(in: Data(source.utf8)) } == ["이름()", "이름()"])
    }
    @Test func referenceCandidatesAndPreviewAreBounded() async {
        let source = "func swim() {}\n" + String(repeating: "swim(); ", count: 5_000)
        let index = await BuiltinDeclarationAnalyzer().index(utf8: Data(source.utf8), language: "swift")
        let matches = index.matches(named: "swim", kind: .references)
        #expect(matches.count == 201)
        #expect(matches.allSatisfy { $0.preview(in: Data(source.utf8)).utf8.count <= 260 })
    }
    @Test func protobufMessagesRPCsAndNestedEnums() async throws {
        let text = """
        syntax = "proto3";
        package example.v1;
        service SessionService {
          rpc Session(stream ClientMessage) returns (stream ServerMessage) {}
        }
        message ClientMessage {
          enum Source { UNKNOWN = 0; }
          Source source = 1;
          oneof payload { AudioFormat audio = 2; }
        }
        message ServerMessage { ClientMessage request = 1; }
        message AudioFormat { uint32 channels = 1; }
        // message Ghost {}
        option java_package = "message Fake {}";
        """
        #expect(DeclarationLanguage.forFilename("ignite_session.proto") == "protobuf")
        let index = await BuiltinDeclarationAnalyzer().index(utf8: Data(text.utf8), language: "protobuf")
        #expect(index.isComplete)
        #expect(index.declarations.map(\.name) == ["SessionService", "Session", "ClientMessage", "Source", "payload", "ServerMessage", "AudioFormat"])
        let use = text[..<text.range(of: "ClientMessage)")!.lowerBound].utf8.count
        #expect(index.word(at: use) == "ClientMessage")
        #expect(index.navigationRange(at: use)?.count == "ClientMessage".utf8.count)
        #expect(index.candidates(named: "ClientMessage", at: use).map(\.line) == [6])
        let nestedUse = text[..<text.range(of: "Source source")!.lowerBound].utf8.count
        #expect(index.candidates(named: "Source", at: nestedUse).count == 1)
        #expect(index.candidates(named: "Source", at: use).isEmpty)
        #expect(index.candidates(named: "Source").count == 1)
    }
    @Test func hoverRangeRequiresIdentifierInterior() async throws {
        let source = "let 이름 = 1 // 이름\nprint(이름)\n\"이름\""
        let index = await BuiltinDeclarationAnalyzer().index(utf8: Data(source.utf8), language: "swift")
        #expect(index.navigationRange(at: 4) == 4..<10)
        #expect(index.navigationRange(at: 7) == 4..<10)
        #expect(index.navigationRange(at: 10) == nil)
        #expect(index.navigationRange(at: 18) == nil)
        #expect(index.navigationRange(at: source.utf8.count - 3) == nil)
    }
    @Test func unicodeScopesParametersAndLiterals() async throws {
        let text = "// func ghost() {}\nlet 이름 = 1\nfunc outer(arg: Int) {\n let 이름 = 2\n print(이름, arg)\n}\nprint(이름)\nlet text = \"func fake() {}\""
        let index = await BuiltinDeclarationAnalyzer().index(utf8: Data(text.utf8), language: "swift")
        #expect(index.isComplete)
        #expect(index.declarations.map(\.name) == ["이름", "outer", "arg", "이름", "text"])
        let localUse = try #require(text.range(of: "이름, arg"))
        let offset = text[..<localUse.lowerBound].utf8.count
        #expect(index.word(at: offset) == "이름")
        #expect(index.candidates(named: "이름", at: offset).map(\.line) == [4])
        #expect(index.candidates(named: "arg", at: offset).count == 1)
        #expect(index.candidates(named: "이름", at: text.utf8.count).map(\.line) == [2])
        for declaration in index.declarations {
            let bytes = Data(text.utf8)
            #expect(String(decoding: bytes[declaration.range.location..<(declaration.range.location + declaration.range.length)], as: UTF8.self) == declaration.name)
        }
    }
    @Test func pythonSuitesShareFunctionScope() async {
        let text = "def f(arg):\n    if True:\n        value = 1\n    print(value, arg)\ndef g():\n    print(value)\n"
        let index = await BuiltinDeclarationAnalyzer().index(utf8: Data(text.utf8), language: "python")
        let use = text[..<text.range(of: "print(value, arg)")!.lowerBound].utf8.count
        #expect(index.candidates(named: "value", at: use).count == 1)
        #expect(index.candidates(named: "arg", at: use).count == 1)
        #expect(index.candidates(named: "value", at: text.utf8.count).isEmpty)
    }
    @Test(arguments: ["def f(\n    arg=1,\n):\n    print(arg)\nprint(arg)", "def f(\n    arg,\n):\n    value = 1\n    print(value, arg)\nprint(value)", "def f(arg): print(arg)\nprint(arg)"])
    func pythonMultilineHeadersAndInlineSuitesDoNotLeak(source: String) async {
        let index = await BuiltinDeclarationAnalyzer().index(utf8: Data(source.utf8), language: "python")
        let use = source[..<source.range(of: "print")!.lowerBound].utf8.count
        #expect(index.candidates(named: "arg", at: use).count == 1)
        #expect(index.candidates(named: "arg", at: source.utf8.count).isEmpty)
        #expect(index.candidates(named: "value", at: source.utf8.count).isEmpty)
        #expect(index.candidates(named: "value").isEmpty)
        #expect(index.candidates(named: "arg").isEmpty)
    }
    @Test(arguments: ["const pattern = ", "const pattern = () => ", "if (true) "])
    func regexAndCommentsDoNotDeclareNames(prefix: String) async {
        let text = prefix + "/function fake(){}/;\n/* function ghost() {} */\nfunction real() {}\nreal();"
        let index = await BuiltinDeclarationAnalyzer().index(utf8: Data(text.utf8), language: "javascript")
        #expect(index.declarations.map(\.name).contains("real"))
        #expect(!index.declarations.map(\.name).contains("ghost"))
        #expect(index.candidates(named: "fake").isEmpty)

    }
    @Test func qualifiedNamesDoNotClaimLexicalResolution() async {
        let text = "let value = 1\nobject.value\nType::member"
        let index = await BuiltinDeclarationAnalyzer().index(utf8: Data(text.utf8), language: "swift")
        #expect(index.isQualified(at: text[..<text.range(of: "value", options: .backwards)!.lowerBound].utf8.count))
        #expect(index.isQualified(at: text.utf8.count))
        #expect(!index.isQualified(at: 4))
        #expect(DeclarationLanguage.isCompatible("typescript", "javascript"))
        #expect(!DeclarationLanguage.isCompatible("swift", "javascript"))
    }
    @Test(arguments: [("rust", "fn swim(speed: i32) {}"), ("go", "func swim(speed int) {}"), ("c", "void swim(int speed) {}"), ("java", "void swim(int speed) {}"), ("csharp", "void swim(int speed) {}"), ("typescript", "function swim(speed: number) {}")])
    func commonFunctionForms(language: String, source: String) async {
        let index = await BuiltinDeclarationAnalyzer().index(utf8: Data(source.utf8), language: language)
        #expect(index.declarations.map(\.name).contains("swim"))
        #expect(index.declarations.map(\.name).contains("speed"))
    }
    @Test(arguments: ["R", "u8R", "uR", "UR", "LR"])
    func cppRawLiteralPrefixesFailClosed(prefix: String) async {
        let text = "auto text = \(prefix)\"tag(\" void fake() {} )tag\";\nfake();"
        let index = await BuiltinDeclarationAnalyzer().index(utf8: Data(text.utf8), language: "cpp")
        #expect(!index.isComplete)
        #expect(index.declarations.isEmpty)
    }
    @Test(arguments: ["r", "br", "cr"])
    func rustRawLiteralPrefixesFailClosed(prefix: String) async {
        let text = "let text = \(prefix)##\"\"; fn fake() {} \"##;\nfake();"
        let index = await BuiltinDeclarationAnalyzer().index(utf8: Data(text.utf8), language: "rust")
        #expect(!index.isComplete)
        #expect(index.declarations.isEmpty)
    }
    @Test func rejectsOversizedUnsupportedAndInvalidInput() async {
        let analyzer = BuiltinDeclarationAnalyzer()
        for (bytes, language) in [(Data(repeating: 97, count: DeclarationIndex.maximumBytes + 1), "swift"), (Data([255]), "swift"), (Data("func fake() {}".utf8), "json")] {
            let index = await analyzer.index(utf8: bytes, language: language)
            #expect(index.declarations.isEmpty)
            #expect(!index.isComplete)
        }
    }
}
