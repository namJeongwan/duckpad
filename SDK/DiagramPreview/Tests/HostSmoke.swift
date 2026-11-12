import Foundation
import DuckpadNativeABI

@main struct HostSmoke {
    @MainActor static func main() {
        let prefix = MemoryLayout<DuckpadHostV1>.offset(of: \.read_document)!
        let old = UnsafeMutableRawPointer.allocate(byteCount: prefix, alignment: 8)
        defer { old.deallocate() }
        old.initializeMemory(as: UInt8.self, repeating: 0, count: prefix)
        old.storeBytes(of: UInt32(1), as: UInt32.self)
        old.storeBytes(of: UInt32(prefix), toByteOffset: 4, as: UInt32.self)
        let legacy = DuckpadHost(old.assumingMemoryBound(to: DuckpadHostV1.self))
        precondition(legacy != nil && legacy?.documentText() == nil)
        var api = DuckpadHostV1()
        api.abi_version = 1; api.struct_size = UInt32(MemoryLayout<DuckpadHostV1>.size)
        api.read_document = { _, buffer, capacity in
            let bytes = Array("한글 🦆".utf8)
            if let buffer {
                guard capacity >= bytes.count else { return -1 }
                for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            }
            return Int64(bytes.count)
        }
        precondition(DuckpadHost(&api)?.documentText() == "한글 🦆")
        api.read_document = { _, _, _ in 512 * 1024 + 1 }
        precondition(DuckpadHost(&api)?.documentText() == nil)
        api.read_document = { _, _, _ in -1 }
        precondition(DuckpadHost(&api)?.documentText() == nil)
        api.abi_version = 2
        precondition(DuckpadHost(&api) == nil)
        print("Old ABI prefix, UTF-8 document, bounds and unavailable reads passed")
    }
}
