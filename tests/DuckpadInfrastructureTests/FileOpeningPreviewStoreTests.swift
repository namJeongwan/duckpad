import Darwin
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
import Testing

@Test(arguments: [TextFileEncoding.utf8, .utf16LittleEndian, .utf16BigEndian])
func openingPreviewReadsOnlyBoundedPrefixAndTrimsPartialUnicode(_ encoding: TextFileEncoding) async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let prefix = String(repeating: "a", count: encoding == .utf8 ? 65535 : 32766)
    let data = TextFileCodec.encode(prefix + "🦆tail", encoding: encoding,
        byteOrderMark: encoding == .utf8 ? .absent : .present)
    try data.write(to: url)
    let file = try FileHandle(forWritingTo: url)
    try file.truncate(atOffset: 2 * 1024 * 1024 * 1024)
    try file.close()
    let preview = try #require(await LocalTextFileStore().openingPreview(from: url, assuming: nil))
    #expect(preview.text == prefix)
    #expect(preview.totalByteCount == 2 * 1024 * 1024 * 1024)
}

@Test func openingPreviewSkipsSmallBinaryAndNonRegularFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalTextFileStore()
    let small = root.appendingPathComponent("small")
    try Data("small file".utf8).write(to: small)
    #expect(await store.openingPreview(from: small, assuming: nil) == nil)
    let binary = root.appendingPathComponent("binary")
    try Data(repeating: 0, count: 8 * 1024 * 1024).write(to: binary)
    #expect(await store.openingPreview(from: binary, assuming: nil) == nil)
    #expect(await store.openingPreview(from: root, assuming: nil) == nil)
    let fifo = root.appendingPathComponent("fifo")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    #expect(await store.openingPreview(from: fifo, assuming: nil) == nil)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
    #expect(await store.openingPreview(from: link, assuming: nil) == nil)
}
