import Foundation

/// One connection owns one terminal. Only the signed containing app may connect.
@objc public protocol DuckpadTerminalHostProtocol {
    func readRemoteFile(_ request: Data, requestID: String, withReply reply: @escaping @Sendable (Data?) -> Void)
    func cancelRemoteFile(_ requestID: String)
    func waitForExit(withReply reply: @escaping (Int32) -> Void)
    func start(directory: String, environment: [String: String], rows: UInt16, columns: UInt16,
               withReply reply: @escaping (FileHandle?, String?) -> Void)
}

public enum TerminalHostXPC {
    public static let identifier = "com.namjeongwan.duckpad.terminal-host"
}
