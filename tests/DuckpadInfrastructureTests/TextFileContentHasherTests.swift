import CryptoKit
@testable import DuckpadInfrastructure
import Foundation
import Testing

@Test func fileContentHashReusesOnlyByteIdenticalPrefixes() {
    let hasher = TextFileContentHasher(chunkSize: 16)
    let original = Data(repeating: 0x61, count: 67)
    func full(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    #expect(hasher.digest(original) == full(original))
    #expect(hasher.lastHashedByteCount == 67)
    #expect(hasher.digest(original) == full(original))
    #expect(hasher.lastHashedByteCount == 0)
    var appended = original
    appended.append(contentsOf: "한🦆".utf8)
    #expect(hasher.digest(appended) == full(appended))
    #expect(hasher.lastHashedByteCount == 7)
    var changed = appended
    changed[17] = 0x62
    #expect(hasher.digest(changed) == full(changed))
    #expect(hasher.lastHashedByteCount == changed.count - 16)
    let truncated = Data(changed.prefix(32))
    #expect(hasher.digest(truncated) == full(truncated))
    #expect(hasher.digest(Data()) == full(Data()))
    #expect(hasher.digest(original) == full(original))
}

@Test func fileContentHashDoesNotRetainOversizedSnapshots() {
    let hasher = TextFileContentHasher(chunkSize: 8, maximumCachedBytes: 16)
    let bytes = Data(repeating: 1, count: 32)
    let first = hasher.digest(bytes)
    #expect(hasher.digest(bytes) == first)
    #expect(hasher.lastHashedByteCount == bytes.count)
}
