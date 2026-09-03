import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
import Testing

private actor FolderStoreFake: FolderSearchFileStore {
    let enumeration: FolderSearchEnumeration

    init(_ enumeration: FolderSearchEnumeration) { self.enumeration = enumeration }

    func enumerateTextCandidates(
        rootPath: String,
        maximumFiles: Int,
        maximumDocumentBytes: Int,
        maximumTotalBytes: Int
    ) async throws(FolderSearchFailure) -> FolderSearchEnumeration {
        enumeration
    }
}

private actor CancellingFolderStore: FolderSearchFileStore {
    private var entered = false

    func enumerateTextCandidates(
        rootPath: String,
        maximumFiles: Int,
        maximumDocumentBytes: Int,
        maximumTotalBytes: Int
    ) async throws(FolderSearchFailure) -> FolderSearchEnumeration {
        entered = true
        while !Task.isCancelled { await Task.yield() }
        throw .search(.cancelled)
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }
}

private func folderIdentity(_ path: String, _ data: Data, serial: Int64) -> FileIdentity {
    FileIdentity(
        canonicalPath: path,
        device: 1,
        inode: UInt64(serial),
        byteCount: UInt64(data.count),
        modifiedNanoseconds: serial,
        contentToken: "folder-\(serial)-\(data.count)"
    )
}

@Test func folderSearchDecodesTextAndReturnsStructuredUnicodeResults() async throws {
    let firstPath = "/tmp/project/a.txt"
    let secondPath = "/tmp/project/nested/b.txt"
    let invalidPath = "/tmp/project/image.bin"
    let first = Data("duck α\nnot here\nduck🙂".utf8)
    let second = TextFileCodec.encode("한글 duck", encoding: .utf16LittleEndian, byteOrderMark: .present)
    let invalid = Data([0xFF, 0x00, 0xC0])
    let enumeration = FolderSearchEnumeration(
        rootPath: "/tmp/project",
        files: [
            FolderSearchFile(path: firstPath, relativePath: "a.txt", data: first, identity: folderIdentity(firstPath, first, serial: 1)),
            FolderSearchFile(path: secondPath, relativePath: "nested/b.txt", data: second, identity: folderIdentity(secondPath, second, serial: 2)),
            FolderSearchFile(path: invalidPath, relativePath: "image.bin", data: invalid, identity: folderIdentity(invalidPath, invalid, serial: 3)),
        ],
        isTruncated: false,
        skippedFileCount: 0,
        totalBytes: first.count + second.count + invalid.count
    )
    let useCase = FolderSearchUseCase(store: FolderStoreFake(enumeration), regexEngine: ICURegexEngine())

    let result = try await useCase.search(
        rootPath: enumeration.rootPath,
        query: SearchQuery(pattern: "duck", options: SearchOptions(matchCase: true))
    )

    #expect(result.rootPath == enumeration.rootPath)
    #expect(result.matchCount == 3)
    #expect(result.documents.map(\.relativePath) == ["a.txt", "nested/b.txt"])
    #expect(result.documents[0].matches.map(\.line) == [1, 3])
    #expect(result.documents[1].matches[0].column == 8)
    #expect(result.searchedFileCount == 2)
    #expect(result.skippedFileCount == 1)
    #expect(result.searchedByteCount == first.count + second.count)
    #expect(!result.isTruncated)
}

@Test func folderSearchEnforcesGlobalMatchAndEnumerationBounds() async throws {
    let path = "/tmp/project/many.txt"
    let data = Data("duck duck duck".utf8)
    let enumeration = FolderSearchEnumeration(
        rootPath: "/tmp/project",
        files: [FolderSearchFile(
            path: path,
            relativePath: "many.txt",
            data: data,
            identity: folderIdentity(path, data, serial: 1)
        )],
        isTruncated: true,
        skippedFileCount: 4,
        totalBytes: data.count
    )
    let limits = FolderSearchLimits(
        maximumFiles: 5,
        maximumDocumentBytes: 32,
        maximumTotalBytes: 64,
        maximumMatches: 1,
        maximumResultBytes: 4_096
    )
    let useCase = FolderSearchUseCase(
        store: FolderStoreFake(enumeration),
        regexEngine: ICURegexEngine(),
        limits: limits
    )

    let result = try await useCase.search(rootPath: enumeration.rootPath, query: SearchQuery(pattern: "duck"))
    #expect(result.matchCount == 1)
    #expect(result.isTruncated)
    #expect(result.skippedFileCount == 4)
}

@Test func folderSearchRejectsInvalidLimitsBeforeEnumeration() async {
    let enumeration = FolderSearchEnumeration(
        rootPath: "/tmp/project",
        files: [],
        isTruncated: false,
        skippedFileCount: 0,
        totalBytes: 0
    )
    let useCase = FolderSearchUseCase(
        store: FolderStoreFake(enumeration),
        regexEngine: ICURegexEngine(),
        limits: FolderSearchLimits(maximumFiles: 0)
    )
    do {
        _ = try await useCase.search(rootPath: enumeration.rootPath, query: SearchQuery(pattern: "duck"))
        Issue.record("invalid limits were accepted")
    } catch let error {
        #expect(error == .invalidLimits)
    }
}

@Test func folderSearchCancellationReachesEnumeration() async {
    let store = CancellingFolderStore()
    let useCase = FolderSearchUseCase(store: store, regexEngine: ICURegexEngine())
    let task = Task {
        try await useCase.search(rootPath: "/tmp/project", query: SearchQuery(pattern: "duck"))
    }
    await store.waitUntilEntered()
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("cancelled search returned a result")
    } catch let error as FolderSearchFailure {
        #expect(error == .search(.cancelled))
    } catch {
        Issue.record("unexpected cancellation error: \(error)")
    }
}

@Test func folderSearchRejectsInvalidRegexBeforeEnumeratingEmptyFolder() async {
    let enumeration = FolderSearchEnumeration(
        rootPath: "/tmp/project", files: [], isTruncated: false,
        skippedFileCount: 0, totalBytes: 0
    )
    let useCase = FolderSearchUseCase(store: FolderStoreFake(enumeration), regexEngine: ICURegexEngine())
    let query = SearchQuery(pattern: "(", options: SearchOptions(mode: .regularExpression))

    do {
        _ = try await useCase.search(rootPath: enumeration.rootPath, query: query)
        Issue.record("invalid regex was accepted for an empty folder")
    } catch let error {
        guard case .search(.invalidRegularExpression) = error else {
            Issue.record("unexpected error: \(error)")
            return
        }
    }
}

@Test func folderSearchRejectsInvalidRegexWhenEveryCandidateIsUndecodable() async {
    let path = "/tmp/project/image.bin"
    let data = Data([0xFF, 0x00, 0xC0])
    let enumeration = FolderSearchEnumeration(
        rootPath: "/tmp/project",
        files: [FolderSearchFile(
            path: path, relativePath: "image.bin", data: data,
            identity: folderIdentity(path, data, serial: 1)
        )],
        isTruncated: false, skippedFileCount: 0, totalBytes: data.count
    )
    let useCase = FolderSearchUseCase(store: FolderStoreFake(enumeration), regexEngine: ICURegexEngine())
    let query = SearchQuery(pattern: "(", options: SearchOptions(mode: .regularExpression))

    do {
        _ = try await useCase.search(rootPath: enumeration.rootPath, query: query)
        Issue.record("invalid regex was accepted for skipped candidates")
    } catch let error {
        guard case .search(.invalidRegularExpression) = error else {
            Issue.record("unexpected error: \(error)")
            return
        }
    }
}

@Test func folderSearchChargesLongDocumentMetadataOnceAndBoundsMatches() async throws {
    let relative = String(repeating: "long/", count: 120) + "result.txt"
    let path = "/tmp/project/" + relative
    let data = Data(Array(repeating: "duck ", count: 200).joined().utf8)
    let enumeration = FolderSearchEnumeration(
        rootPath: "/tmp/project",
        files: [FolderSearchFile(
            path: path, relativePath: relative, data: data,
            identity: folderIdentity(path, data, serial: 1)
        )],
        isTruncated: false, skippedFileCount: 0, totalBytes: data.count
    )
    let useCase = FolderSearchUseCase(
        store: FolderStoreFake(enumeration), regexEngine: ICURegexEngine(),
        limits: FolderSearchLimits(
            maximumFiles: 10, maximumDocumentBytes: 2_000, maximumTotalBytes: 2_000,
            maximumMatches: 100_000, maximumResultBytes: 4_096
        )
    )

    let result = try await useCase.search(rootPath: enumeration.rootPath, query: SearchQuery(pattern: "duck"))

    #expect(result.documents.count == 1)
    #expect(result.matchCount > 1)
    #expect(result.matchCount < 200)
    #expect(result.isTruncated)
}
