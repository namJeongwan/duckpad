import DuckpadApplication
import DuckpadDomain
import DuckpadPluginSupport
import DuckpadWAMRBridge
import Foundation

public enum PluginRuntimeExecutor {
    public static func response(for request: ExtensionHostRequest) -> ExtensionHostResponse {
        do {
            guard request.protocolVersion == 1, request.limits.isValid else {
                throw ExtensionFailure.hostUnavailable("unsupported handshake or limits")
            }
            _ = try WasmModulePolicy.validate(request.module, limits: request.limits)
            return try execute(request)
        } catch {
            return ExtensionHostResponse(failure: String(describing: error))
        }
    }

    public static func responseFrame(for requestFrame: Data) throws -> Data {
        let request = try PluginFrameCodec.decode(ExtensionHostRequest.self, from: requestFrame)
        return try PluginFrameCodec.encode(response(for: request))
    }

    private static func execute(_ request: ExtensionHostRequest) throws -> ExtensionHostResponse {
        guard request.module.count <= Int(UInt32.max),
              request.context.utf8.count <= Int(UInt32.max),
              request.limits.maximumOutputBytes <= Int(UInt32.max) else {
            throw ExtensionFailure.limitExceeded("WAMR ABI")
        }
        var output = Data(count: request.limits.maximumOutputBytes)
        var outputLength = UInt32(output.count)
        var error = [CChar](repeating: 0, count: 512)
        let runtimeLimits = DPWAMRLimits(
            module_bytes: UInt32(request.limits.maximumModuleBytes),
            stack_bytes: request.limits.stackBytes,
            heap_bytes: request.limits.heapBytes,
            output_bytes: UInt32(request.limits.maximumOutputBytes)
        )
        let succeeded = request.module.withUnsafeBytes { module in
            request.context.utf8.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { destination in
                    dp_wamr_invoke(
                        module.bindMemory(to: UInt8.self).baseAddress,
                        request.module.count,
                        request.context.operation,
                        input.bindMemory(to: UInt8.self).baseAddress,
                        UInt32(request.context.utf8.count),
                        runtimeLimits,
                        destination.bindMemory(to: UInt8.self).baseAddress,
                        &outputLength,
                        &error,
                        UInt32(error.count)
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
        guard String(data: output, encoding: .utf8) != nil else {
            throw ExtensionFailure.invalidResult("module emitted invalid UTF-8")
        }
        let range: ExtensionUTF8Range
        switch request.context.inputScope {
        case .selection:
            guard request.context.selection.length > 0 else {
                throw ExtensionFailure.invalidResult("Sort Selected Lines requires a selection")
            }
            range = request.context.selection
        case .document:
            range = ExtensionUTF8Range(location: 0, length: request.context.utf8.count)
        }
        return ExtensionHostResponse(result: ExtensionCommandResult(
            edits: output == request.context.utf8
                ? []
                : [ExtensionTextEdit(range: range, replacementUTF8: output)],
            status: request.context.operation == 1
                ? "Selected lines sorted"
                : "Trailing whitespace removed"
        ))
    }
}
