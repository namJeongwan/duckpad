import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
import Testing

@Test func bundledLanguageRegistryIsBroadAndDeterministic() throws {
    let registry = try LanguageManifestLoader().loadBundled()
    #expect(registry.definitions.count >= 60)
    #expect(registry[.plainText]?.lexerName == "null")
    #expect(Set(registry.definitions.map(\.id)).count == registry.definitions.count)
    let complete = registry.definitions.filter { $0.supportTier == .keywordComplete }
    let requiredComplete = Set([
        "swift", "c", "cpp", "objc", "csharp", "java", "kotlin", "javascript",
        "typescript", "python", "rust", "go", "ruby", "php", "sql", "html",
        "css", "json", "yaml", "bash",
    ])
    #expect(Set(complete.map(\.id.rawValue)).isSuperset(of: requiredComplete))
    #expect(complete.count == 20)
    let intrinsicVocabulary = Set(["html", "css", "json", "yaml"])
    #expect(complete.allSatisfy { !$0.keywordLists.isEmpty || intrinsicVocabulary.contains($0.id.rawValue) })
}

@Test func registryRejectsDuplicateNormalizedDisplayNames() throws {
    let registry = try LanguageManifestLoader().loadBundled()
    let duplicate = LanguageDefinition(
        id: LanguageID(rawValue: "duplicate-plain"),
        displayName: " plain text ",
        group: "Text",
        lexerName: "null"
    )
    #expect(throws: LanguageRegistryError.self) {
        _ = try LanguageRegistry(definitions: registry.definitions + [duplicate])
    }
}

@Test func detectorUsesExplicitPrecedenceAndAmbiguityRules() throws {
    let registry = try LanguageManifestLoader().loadBundled()
    let detector = LanguageDetector(registry: registry)
    #expect(detector.detect(filename: "Makefile", contentPrefix: Data()).languageID.rawValue == "make")
    #expect(detector.detect(filename: "makefile", contentPrefix: Data()).languageID == .plainText)
    #expect(detector.detect(filename: ".bashrc", contentPrefix: Data()).languageID.rawValue == "bash")
    #expect(detector.detect(filename: "CONFIG.JSON", contentPrefix: Data()).languageID.rawValue == "json")
    #expect(detector.detect(filename: "c", contentPrefix: Data()).languageID == .plainText)
    #expect(detector.detect(filename: "tool.unknown", contentPrefix: Data("#!/usr/bin/env -S python3 -u\n".utf8)).languageID.rawValue == "python")
    #expect(detector.detect(filename: "tool", contentPrefix: Data("#!/bin/sh\n".utf8)).languageID.rawValue == "bash")
    #expect(detector.detect(filename: "tool", contentPrefix: Data("#!/usr/bin/notpython\n".utf8)).languageID == .plainText)
    #expect(detector.detect(
        filename: "Makefile", contentPrefix: Data("#!/bin/sh\n".utf8),
        override: .manual(LanguageID(rawValue: "python"))
    ).languageID.rawValue == "python")
    #expect(detector.detect(filename: "view.xml", contentPrefix: Data("<?xml version=\"1.0\"?><svg/>".utf8)).languageID.rawValue == "xml")

    let objc = detector.detect(filename: "sample.m", contentPrefix: Data("#import <AppKit/AppKit.h>".utf8))
    #expect(objc.languageID.rawValue == "objc")
    #expect(Set(objc.candidates.map(\.rawValue)) == Set(["objc", "matlab", "octave"]))
    #expect(detector.detect(filename: "sample.m", contentPrefix: Data("function value = f(x)".utf8)).languageID.rawValue == "matlab")
    #expect(detector.detect(filename: "sample.m", contentPrefix: Data("## octave\nendfunction".utf8)).languageID.rawValue == "octave")
    #expect(detector.detect(filename: "sample.fs", contentPrefix: Data("module Duck\nlet x = 1".utf8)).languageID.rawValue == "fsharp")
    #expect(detector.detect(filename: "sample.fs", contentPrefix: Data(": quack 1 . ;".utf8)).languageID.rawValue == "forth")
    #expect(detector.detect(filename: "sample.r", contentPrefix: Data("REBOL [Title: \"Duck\"]".utf8)).languageID.rawValue == "rebol")
}

@Test func detectorRepairsOnlyTruncatedUTF8SuffixAndHonoursBOM() throws {
    let registry = try LanguageManifestLoader().loadBundled()
    let detector = LanguageDetector(registry: registry, maximumContentProbeBytes: 256)
    var bytes = Data([0xEF, 0xBB, 0xBF])
    bytes.append(contentsOf: "#!/usr/bin/env python3\n".utf8)
    bytes.append(contentsOf: String(repeating: "a", count: 228).utf8)
    bytes.append(contentsOf: "🦆".utf8)
    #expect(detector.detect(filename: nil, contentPrefix: bytes).languageID.rawValue == "python")
}

@Test func unknownPersistedManualLanguageIsPreservedAsUnavailable() throws {
    let registry = try LanguageManifestLoader().loadBundled()
    let detection = LanguageDetector(registry: registry).detect(
        filename: "sample.swift", contentPrefix: Data(),
        override: .manual(LanguageID(rawValue: "removed-language"))
    )
    #expect(detection.languageID == .plainText)
    #expect(detection.confidence == .manual)
    #expect(detection.reason.contains("removed-language"))
}

@Test func malformedOrNarrowManifestFailsTypedInsteadOfClaimingBroadSupport() {
    let malformed = Data("{\"version\":1,\"languages\":[]}".utf8)
    #expect(throws: LanguageManifestError.self) {
        _ = try LanguageManifestLoader().load(malformed)
    }
}
