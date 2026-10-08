import Foundation
import DuckpadNativeABI

/// Copyable wrapper; only use it on the main thread while the plugin is active.
@MainActor public struct DuckpadHost {
    private let api: DuckpadHostV1
    public init?(_ api: UnsafePointer<DuckpadHostV1>) {
        let raw = UnsafeRawPointer(api)
        let version = raw.load(as: UInt32.self)
        let size = Int(raw.load(fromByteOffset: 4, as: UInt32.self))
        let baseSize = MemoryLayout<DuckpadHostV1>.offset(of: \.read_document)!
        guard version == 1, size >= baseSize else { return nil }
        var copy = DuckpadHostV1()
        withUnsafeMutableBytes(of: &copy) { $0.copyBytes(from: UnsafeRawBufferPointer(start: raw, count: min(size, $0.count))) }
        if size < MemoryLayout<DuckpadHostV1>.size { copy.read_document = nil }
        self.api = copy
    }
    public func prepareInsert() -> UInt64 { api.prepare_insert?(api.context) ?? 0 }
    public func insert(_ text: String, token: UInt64) -> Bool {
        guard token != 0 else { return false }
        return Array(text.utf8).withUnsafeBufferPointer {
            api.insert_text?(api.context, token, $0.baseAddress, $0.count) == 1
        }
    }
    public func closePanel() { api.close_panel?(api.context) }
    public func documentText() -> String? {
        guard let read = api.read_document else { return nil }
        let size = read(api.context, nil, 0)
        guard size >= 0, size <= 512 * 1024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(size))
        let copied = bytes.withUnsafeMutableBufferPointer { read(api.context, $0.baseAddress, $0.count) }
        guard copied == size else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }
}
