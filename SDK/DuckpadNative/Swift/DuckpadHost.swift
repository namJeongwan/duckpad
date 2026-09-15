import Foundation
import DuckpadNativeABI

/// Copyable wrapper; only use it on the main thread while the plugin is active.
@MainActor public struct DuckpadHost {
    private let api: DuckpadHostV1
    public init?(_ api: UnsafePointer<DuckpadHostV1>) {
        guard api.pointee.abi_version == 1,
              api.pointee.struct_size >= MemoryLayout<DuckpadHostV1>.size else { return nil }
        self.api = api.pointee
    }
    public func prepareInsert() -> UInt64 { api.prepare_insert?(api.context) ?? 0 }
    public func insert(_ text: String, token: UInt64) -> Bool {
        guard token != 0 else { return false }
        return Array(text.utf8).withUnsafeBufferPointer {
            api.insert_text?(api.context, token, $0.baseAddress, $0.count) == 1
        }
    }
    public func closePanel() { api.close_panel?(api.context) }
}
