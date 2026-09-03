import Darwin
import DuckpadApplication
import DuckpadDomain
import DuckpadPluginSupport
import DuckpadWAMRBridge
import Foundation

@main
enum DuckpadPluginHostMain {
    static func main() {
        let response: ExtensionHostResponse
        do {
            let frame = try readFrame(from: .standardInput)
            let request = try PluginFrameCodec.decode(ExtensionHostRequest.self, from: frame)
            guard request.protocolVersion == 1, request.limits.isValid else {
                throw ExtensionFailure.hostUnavailable("unsupported handshake or limits")
            }
            _ = try WasmModulePolicy.validate(request.module, limits: request.limits)
            response = try execute(request)
        } catch {
            response = ExtensionHostResponse(failure: String(describing: error))
        }
        do { try FileHandle.standardOutput.write(contentsOf: PluginFrameCodec.encode(response)) }
        catch { FileHandle.standardError.write(Data("DuckpadPluginHost framing failure\n".utf8)); Darwin.exit(70) }
    }

    private static func execute(_ request: ExtensionHostRequest) throws -> ExtensionHostResponse {
        guard request.module.count <= Int(UInt32.max), request.context.utf8.count <= Int(UInt32.max),
              request.limits.maximumOutputBytes <= Int(UInt32.max) else { throw ExtensionFailure.limitExceeded("WAMR ABI") }
        var output = Data(count: request.limits.maximumOutputBytes)
        var outputLength = UInt32(output.count)
        var error = [CChar](repeating: 0, count: 512)
        let runtimeLimits = DPWAMRLimits(
            module_bytes: UInt32(request.limits.maximumModuleBytes), stack_bytes: request.limits.stackBytes,
            heap_bytes: request.limits.heapBytes, output_bytes: UInt32(request.limits.maximumOutputBytes)
        )
        let succeeded = request.module.withUnsafeBytes { module in
            request.context.utf8.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { destination in
                    dp_wamr_invoke(
                        module.bindMemory(to: UInt8.self).baseAddress, request.module.count,
                        request.context.operation, input.bindMemory(to: UInt8.self).baseAddress,
                        UInt32(request.context.utf8.count), runtimeLimits,
                        destination.bindMemory(to: UInt8.self).baseAddress, &outputLength,
                        &error, UInt32(error.count)
                    )
                }
            }
        }
        guard succeeded else {
            let end = error.firstIndex(of: 0) ?? error.endIndex
            let message = String(decoding: error[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            throw ExtensionFailure.invalidModule(message)
        }
        output.removeSubrange(Int(outputLength)..<output.count)
        guard String(data: output, encoding: .utf8) != nil else { throw ExtensionFailure.invalidResult("module emitted invalid UTF-8") }
        let range: ExtensionUTF8Range
        switch request.context.inputScope {
        case .selection:
            guard request.context.selection.length > 0 else { throw ExtensionFailure.invalidResult("Sort Selected Lines requires a selection") }
            range = request.context.selection
        case .document:
            range = ExtensionUTF8Range(location: 0, length: request.context.utf8.count)
        }
        return ExtensionHostResponse(result: ExtensionCommandResult(
            edits: output == request.context.utf8 ? [] : [ExtensionTextEdit(range: range, replacementUTF8: output)],
            status: request.context.operation == 1 ? "Selected lines sorted" : "Trailing whitespace removed"
        ))
    }

    private static func readFrame(from handle: FileHandle) throws -> Data {
        let prefix = try readExactly(4, from: handle)
        let length = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= PluginFrameCodec.maximumFrameBytes else { throw ExtensionFailure.limitExceeded("IPC request") }
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
