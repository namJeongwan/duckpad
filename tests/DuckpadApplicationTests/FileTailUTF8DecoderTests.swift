import DuckpadApplication
import DuckpadDomain
import Foundation
import Testing

struct FileTailUTF8DecoderTests {
    @Test func splitKoreanEmojiAndResetNeverInsertReplacementCharacters() throws {
        var decoder = FileTailUTF8Decoder()
        let source = Data("한글 🦆 café\r\n".utf8)
        var output = Data()
        for byte in source { output.append(try decoder.decode(Data([byte]))) }
        #expect(output == source); #expect(decoder.pendingByteCount == 0)
        #expect(try decoder.decode(Data([0xED])).isEmpty)
        #expect(try decoder.decode(Data("new".utf8), reset: true) == Data("new".utf8))
        #expect(throws: FileObservationError.invalidUTF8) { _ = try decoder.decode(Data([0x80])) }
    }
    @Test func rotatedBOMSplitAcrossWritesIsRemovedOnce() throws {
        var decoder = FileTailUTF8Decoder()
        #expect(try decoder.decode(Data([0xEF]), reset: true).isEmpty)
        #expect(try decoder.decode(Data([0xBB])).isEmpty)
        #expect(try decoder.decode(Data([0xBF, 0x61])) == Data("a".utf8))
        #expect(try decoder.decode(Data([0xEF, 0xBB, 0xBF])) == Data([0xEF, 0xBB, 0xBF]))
    }
    @Test func olderBindingsRemainEditableAndRemoteMetadataRoundTrips() throws {
        let identity = FileIdentity(canonicalPath: "/tmp/app.log", device: 1, inode: 2, byteCount: 0, modifiedNanoseconds: 0, contentToken: "fixture")
        let binding = FileBinding(canonicalPath: "/tmp/app.log", encoding: .utf8, byteOrderMark: .absent, lineEnding: .lf, observedIdentity: identity)
        let data = try JSONEncoder().encode(binding)
        let restored = try JSONDecoder().decode(FileBinding.self, from: data)
        #expect(!restored.isReadOnly); #expect(restored.tailMode == nil); #expect(restored.remoteFile == nil)
        var remote = binding
        remote.remoteFile = try #require(RemoteFileLocation(host: "user@alias", path: "/var/log/app.log"))
        remote.tailMode = true
        #expect(remote.isReadOnly)
        #expect(try JSONDecoder().decode(FileBinding.self, from: JSONEncoder().encode(remote)) == remote)
    }
}
