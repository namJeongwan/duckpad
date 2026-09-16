import AppKit
import Darwin
import DuckpadApplication
import DuckpadNativeABI

/// Managed, verified installations are kept loaded for the
/// process lifetime. Swift/ObjC classes cannot be safely unregistered by dlclose.
@MainActor final class NativePluginImage {
    typealias Create = @convention(c) (UnsafePointer<DuckpadHostV1>?, UnsafePointer<UInt8>?, Int) -> UnsafeMutableRawPointer?
    typealias View = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    typealias Action = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias Language = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
    private static var loaded: [String: NativePluginImage] = [:]
    let directory: URL
    let create: Create
    let view: View
    let deactivate: Action
    let destroy: Action
    let language: Language
    private let handle: UnsafeMutableRawPointer

    static func load(_ registration: ExtensionServiceRegistration, installation: any VerifiedNativePluginInstallation) throws -> NativePluginImage {
        try installation.validateForLoading()
        if let image = loaded[registration.packageDigest] {
            guard image.directory.path == installation.directory.path else { throw NativePluginValidationFailure.changedPackage }
            return image
        }
        let image = try NativePluginImage(installation: installation)
        loaded[registration.packageDigest] = image
        return image
    }
    private init(installation: any VerifiedNativePluginInstallation) throws {
        directory = installation.directory
        guard let handle = dlopen(directory.appendingPathComponent("module.dylib").path, RTLD_NOW | RTLD_LOCAL) else {
            throw NSError(domain: "DuckpadNativePlugin", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: dlerror())])
        }
        self.handle = handle
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let address = dlsym(handle, name) else { throw NSError(domain: "DuckpadNativePlugin", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing native entry point: \(name)"]) }
            return unsafeBitCast(address, to: type)
        }
        let version = try symbol("duckpad_native_abi_version", as: (@convention(c) () -> UInt32).self)
        guard version() == DUCKPAD_NATIVE_ABI_VERSION else { throw CocoaError(.executableRuntimeMismatch) }
        create = try symbol("duckpad_native_create", as: Create.self)
        view = try symbol("duckpad_native_view", as: View.self)
        deactivate = try symbol("duckpad_native_deactivate", as: Action.self)
        destroy = try symbol("duckpad_native_destroy", as: Action.self)
        language = try symbol("duckpad_native_set_language", as: Language.self)
    }
}
