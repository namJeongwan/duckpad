import AppKit
import Darwin
import DuckpadNativeABI

@main @MainActor struct NativeModuleSmoke {
    static func main() throws {
        _ = NSApplication.shared
        typealias Version = @convention(c) () -> UInt32
        typealias Create = @convention(c) (UnsafePointer<DuckpadHostV1>?, UnsafePointer<UInt8>?, Int) -> UnsafeMutableRawPointer?
        typealias View = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
        typealias Language = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
        typealias Stop = @convention(c) (UnsafeMutableRawPointer?) -> Void
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diagram-native-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in CommandLine.arguments.dropFirst() {
            let package = URL(fileURLWithPath: path)
            guard let image = dlopen(package.appendingPathComponent("module.dylib").path, RTLD_NOW | RTLD_LOCAL) else {
                fatalError(dlerror().map { String(cString: $0) } ?? "dlopen failed")
            }
            func symbol<T>(_ name: String, _ type: T.Type) -> T { unsafeBitCast(dlsym(image, name)!, to: type) }
            precondition(symbol("duckpad_native_abi_version", Version.self)() == 1)
            var api = DuckpadHostV1(); api.abi_version = 1; api.struct_size = UInt32(MemoryLayout<DuckpadHostV1>.size)
            let config = try JSONEncoder().encode(["resourceDirectory": package.path, "storageDirectory": root.path, "language": "ko"])
            let create = symbol("duckpad_native_create", Create.self)
            precondition(create(nil, nil, 0) == nil)
            let instance = config.withUnsafeBytes { data in create(&api, data.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count) }!
            precondition(symbol("duckpad_native_view", View.self)(instance) != nil)
            for language in ["en", "ko", "ja", "zh-Hans", "de", "fr", "it", "pt-BR"] {
                language.withCString { symbol("duckpad_native_set_language", Language.self)(instance, $0) }
            }
            let stop = symbol("duckpad_native_deactivate", Stop.self); stop(instance); stop(instance)
            symbol("duckpad_native_destroy", Stop.self)(instance)
            // Native modules deliberately remain mapped, matching the host loader.
            print("PASS: native ABI creation, view, eight locales and teardown", package.lastPathComponent)
        }
    }
}
