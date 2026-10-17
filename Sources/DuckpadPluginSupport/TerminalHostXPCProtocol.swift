import Foundation

/// One connection owns one terminal. Only the signed containing app may connect.
@objc public protocol DuckpadTerminalHostProtocol {
    func waitForExit(withReply reply: @escaping (Int32) -> Void)
    func start(directory: String, environment: [String: String], rows: UInt16, columns: UInt16,
               withReply reply: @escaping (FileHandle?, String?) -> Void)
}

public enum TerminalHostXPC {
    public static let identifier = "com.namjeongwan.duckpad.terminal-host"
}
