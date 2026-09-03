import Foundation

/// Value-only boundary exported by the sandboxed plugin runtime. The payload is
/// the same bounded frame used by the development process host; no URL, file
/// handle, environment block, or host object crosses the connection.
@objc public protocol DuckpadPluginXPCProtocol {
    func invoke(_ requestFrame: Data, withReply reply: @escaping (Data?, String?) -> Void)
}

public enum DuckpadPluginXPCService {
    public static let bundleIdentifier = "com.namjeongwan.duckpad.plugin-runtime"
}
