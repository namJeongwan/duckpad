import DuckpadApplication
import DuckpadDomain
import Foundation

public struct ValidatedWasmModule: Equatable, Sendable {
    public let memoryMaximumPages: UInt32
    public let tableMaximumElements: UInt32
}

public enum WasmModulePolicy {
    private struct FunctionType: Equatable {
        let parameters: [UInt8]
        let results: [UInt8]
    }

    private struct Reader {
        let data: Data
        var offset: Int = 0

        mutating func byte() throws(ExtensionFailure) -> UInt8 {
            guard offset < data.count else { throw .invalidModule("truncated WebAssembly module") }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func bytes(_ count: Int) throws(ExtensionFailure) -> Data {
            guard count >= 0, offset <= data.count, count <= data.count - offset else {
                throw .invalidModule("section exceeds module bytes")
            }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }

        mutating func unsigned(maxBytes: Int = 5) throws(ExtensionFailure) -> UInt32 {
            var result: UInt32 = 0
            for index in 0..<maxBytes {
                let next = try byte()
                let payload = UInt32(next & 0x7f)
                let shift = index * 7
                guard shift < 32, payload <= (UInt32.max >> shift) else { throw .invalidModule("LEB128 overflow") }
                result |= payload << shift
                if next & 0x80 == 0 { return result }
            }
            throw .invalidModule("overlong LEB128")
        }

        mutating func name(maximumBytes: Int = 256) throws(ExtensionFailure) -> String {
            let count = Int(try unsigned())
            guard count <= maximumBytes, let value = String(data: try bytes(count), encoding: .utf8) else {
                throw .invalidModule("invalid WebAssembly name")
            }
            return value
        }
    }

    public static func validate(_ data: Data, limits: ExtensionHostLimits) throws(ExtensionFailure) -> ValidatedWasmModule {
        guard limits.isValid, data.count <= limits.maximumModuleBytes, data.count <= Int(UInt32.max) else {
            throw .limitExceeded("module bytes")
        }
        guard data.count >= 8, data.prefix(8) == Data([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]) else {
            throw .invalidModule("unsupported WebAssembly header")
        }
        var reader = Reader(data: data, offset: 8)
        var types: [FunctionType] = []
        var functionTypes: [UInt32] = []
        var functionExports: [String: UInt32] = [:]
        var exportedMemory = false
        var memoryMaximum: UInt32?
        var tableMaximum: UInt32 = 0
        var seen: Set<UInt8> = []
        var lastSection: UInt8 = 0

        while reader.offset < data.count {
            let id = try reader.byte()
            let size = Int(try reader.unsigned())
            let sectionData = try reader.bytes(size)
            if id != 0 {
                guard id <= 12, !seen.contains(id), id > lastSection else { throw .invalidModule("duplicate or out-of-order section") }
                seen.insert(id); lastSection = id
            }
            var section = Reader(data: sectionData)
            switch id {
            case 0:
                _ = try section.name(maximumBytes: 4_096)
                section.offset = section.data.count
            case 1:
                let count = Int(try section.unsigned())
                guard count <= 128 else { throw .limitExceeded("function types") }
                for _ in 0..<count {
                    guard try section.byte() == 0x60 else { throw .invalidModule("non-function type") }
                    let parameterCount = Int(try section.unsigned())
                    guard parameterCount <= 16 else { throw .limitExceeded("function parameters") }
                    var parameters: [UInt8] = []
                    for _ in 0..<parameterCount { parameters.append(try valueType(&section)) }
                    let resultCount = Int(try section.unsigned())
                    guard resultCount <= 1 else { throw .invalidModule("multi-value ABI is unsupported") }
                    var results: [UInt8] = []
                    for _ in 0..<resultCount { results.append(try valueType(&section)) }
                    types.append(FunctionType(parameters: parameters, results: results))
                }
            case 2:
                guard try section.unsigned() == 0 else { throw .invalidModule("imports are forbidden") }
            case 3:
                let count = Int(try section.unsigned())
                guard count <= 4_096 else { throw .limitExceeded("functions") }
                for _ in 0..<count { functionTypes.append(try section.unsigned()) }
            case 4:
                let count = Int(try section.unsigned())
                guard count <= 1 else { throw .limitExceeded("tables") }
                for _ in 0..<count {
                    guard try section.byte() == 0x70 else { throw .invalidModule("unsupported table element type") }
                    let bounds = try limitsPair(&section)
                    guard let maximum = bounds.maximum, maximum <= limits.maximumTableElements else {
                        throw .limitExceeded("table maximum")
                    }
                    tableMaximum = maximum
                }
            case 5:
                let count = Int(try section.unsigned())
                guard count == 1 else { throw .invalidModule("exactly one memory is required") }
                let bounds = try limitsPair(&section)
                guard let maximum = bounds.maximum, maximum <= limits.maximumMemoryPages else {
                    throw .limitExceeded("memory maximum")
                }
                memoryMaximum = maximum
            case 7:
                let count = Int(try section.unsigned())
                guard count <= 256 else { throw .limitExceeded("exports") }
                for _ in 0..<count {
                    let name = try section.name()
                    let kind = try section.byte()
                    let index = try section.unsigned()
                    if kind == 0 { functionExports[name] = index }
                    if kind == 2 && name == "memory" && index == 0 { exportedMemory = true }
                }
            case 8:
                throw .invalidModule("start functions are forbidden")
            default:
                section.offset = section.data.count
            }
            guard section.offset == section.data.count else { throw .invalidModule("malformed section payload") }
        }
        guard let memoryMaximum, exportedMemory else { throw .invalidModule("bounded exported memory is required") }
        try requireExport("duckpad_invoke", signature: FunctionType(parameters: [0x7f, 0x7f, 0x7f], results: [0x7f]), exports: functionExports, functions: functionTypes, types: types)
        try requireExport("duckpad_output_pointer", signature: FunctionType(parameters: [], results: [0x7f]), exports: functionExports, functions: functionTypes, types: types)
        try requireExport("duckpad_output_length", signature: FunctionType(parameters: [], results: [0x7f]), exports: functionExports, functions: functionTypes, types: types)
        return ValidatedWasmModule(memoryMaximumPages: memoryMaximum, tableMaximumElements: tableMaximum)
    }

    private static func valueType(_ reader: inout Reader) throws(ExtensionFailure) -> UInt8 {
        let value = try reader.byte()
        guard [0x7f, 0x7e, 0x7d, 0x7c].contains(value) else { throw .invalidModule("unsupported value type") }
        return value
    }

    private static func limitsPair(_ reader: inout Reader) throws(ExtensionFailure) -> (minimum: UInt32, maximum: UInt32?) {
        let flags = try reader.unsigned()
        guard flags == 1 else { throw .invalidModule("explicit non-shared 32-bit maximum required") }
        let minimum = try reader.unsigned()
        let maximum = try reader.unsigned()
        guard minimum <= maximum else { throw .invalidModule("invalid limits") }
        return (minimum, maximum)
    }

    private static func requireExport(_ name: String, signature: FunctionType, exports: [String: UInt32], functions: [UInt32], types: [FunctionType]) throws(ExtensionFailure) {
        guard let functionIndex = exports[name], functionIndex < functions.count,
              functions[Int(functionIndex)] < types.count,
              types[Int(functions[Int(functionIndex)])] == signature else {
            throw .invalidModule("missing or invalid ABI export \(name)")
        }
    }
}

public enum PluginFrameCodec {
    public static let maximumFrameBytes = 16 * 1_024 * 1_024

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let body = try JSONEncoder().encode(value)
        guard body.count <= maximumFrameBytes, body.count <= Int(UInt32.max) else { throw ExtensionFailure.limitExceeded("IPC frame") }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    public static func decode<T: Decodable>(_ type: T.Type, from frame: Data) throws -> T {
        guard frame.count >= 4 else { throw ExtensionFailure.hostUnavailable("truncated IPC frame") }
        let length = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= maximumFrameBytes, frame.count == 4 + Int(length) else { throw ExtensionFailure.limitExceeded("IPC frame") }
        return try JSONDecoder().decode(type, from: frame.dropFirst(4))
    }
}
