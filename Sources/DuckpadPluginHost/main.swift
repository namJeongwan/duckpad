import Darwin
import DuckpadApplication
import DuckpadDomain
import DuckpadPluginRuntimeCore
import DuckpadPluginSupport
import Foundation

/// SwiftPM/test-only development host. Packaged applications use the embedded
/// App-Sandboxed XPC service instead of spawning this executable.
@main
enum DuckpadPluginHostMain {
    static func main() {
        let response: ExtensionHostResponse
        do {
            response = PluginRuntimeExecutor.response(for: try PluginFrameCodec.decode(
                ExtensionHostRequest.self,
                from: readFrame(from: .standardInput)
            ))
        } catch {
            response = ExtensionHostResponse(failure: String(describing: error))
        }
        do {
            try FileHandle.standardOutput.write(contentsOf: PluginFrameCodec.encode(response))
        } catch {
            FileHandle.standardError.write(Data("DuckpadPluginHost framing failure\n".utf8))
            Darwin.exit(70)
        }
    }

    private static func readFrame(from handle: FileHandle) throws -> Data {
        let prefix = try readExactly(4, from: handle)
        let length = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= PluginFrameCodec.maximumFrameBytes else {
            throw ExtensionFailure.limitExceeded("IPC request")
        }
        var frame = prefix
        frame.append(try readExactly(Int(length), from: handle))
        if let trailing = try handle.read(upToCount: 1), !trailing.isEmpty {
            throw ExtensionFailure.hostUnavailable("plugin host request has trailing bytes")
        }
        return frame
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else {
                throw ExtensionFailure.hostUnavailable("truncated IPC request")
            }
            result.append(chunk)
        }
        return result
    }
}
