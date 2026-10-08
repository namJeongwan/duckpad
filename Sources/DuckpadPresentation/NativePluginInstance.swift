import AppKit
import CryptoKit
import DuckpadApplication
import DuckpadLocalization
import DuckpadNativeABI

@MainActor final class NativePluginInstance {
    let registration: ExtensionServiceRegistration
    let image: NativePluginImage
    private var instance: UnsafeMutableRawPointer?
    var preparePaste: (() -> ((String) -> Bool)?)?
    var onClose: (() -> Void)?
    var readDocument: (() -> String?)?
    private var nextToken: UInt64 = 0
    private var paste: (UInt64, (String) -> Bool)?
    init(_ registration: ExtensionServiceRegistration, root: URL, installation: any VerifiedNativePluginInstallation, language: String) throws {
        self.registration = registration
        image = try NativePluginImage.load(registration, installation: installation)
        let command = SHA256.hash(data: Data(registration.command.id.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
        let storage = root.appendingPathComponent(registration.extensionID.rawValue).appendingPathComponent(registration.publisherFingerprint).appendingPathComponent(command)
        var api = DuckpadHostV1()
        api.abi_version = 1; api.struct_size = UInt32(MemoryLayout<DuckpadHostV1>.size)
        api.context = Unmanaged.passUnretained(self).toOpaque()
        api.prepare_insert = { context in
            guard let context else { return 0 }
            let address = UInt(bitPattern: context)
            return MainActor.assumeIsolated {
                let owner = Unmanaged<NativePluginInstance>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue()
                guard let action = owner.preparePaste?() else { return 0 }
                owner.nextToken &+= 1
                if owner.nextToken == 0 { owner.nextToken = 1 }
                owner.paste = (owner.nextToken, action)
                return owner.nextToken
            }
        }
        api.insert_text = { context, token, bytes, length in
            guard let context, length >= 0, length <= 16 * 1024 * 1024, length == 0 || bytes != nil else { return 0 }
            let data = length == 0 ? Data() : Data(bytes: bytes!, count: length)
            guard let text = String(data: data, encoding: .utf8) else { return 0 }
            let address = UInt(bitPattern: context)
            return MainActor.assumeIsolated {
                let owner = Unmanaged<NativePluginInstance>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue()
                guard let pending = owner.paste, pending.0 == token else { return 0 }
                owner.paste = nil
                return pending.1(text) ? 1 : 0
            }
        }
        api.close_panel = { context in
            guard let context else { return }
            let address = UInt(bitPattern: context)
            MainActor.assumeIsolated {
                Unmanaged<NativePluginInstance>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue().onClose?()
            }
        }
        api.read_document = { context, bytes, capacity in
            guard let context, capacity <= 512 * 1024 else { return -1 }
            let address = UInt(bitPattern: context)
            return MainActor.assumeIsolated {
                let owner = Unmanaged<NativePluginInstance>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue()
                guard owner.registration.capabilities.contains(.documentsRead),
                      let text = owner.readDocument?(), text.utf8.count <= 512 * 1024 else { return -1 }
                let data = Array(text.utf8)
                if let bytes {
                    guard capacity >= data.count else { return -1 }
                    data.withUnsafeBufferPointer { source in
                        if let base = source.baseAddress { bytes.update(from: base, count: source.count) }
                    }
                }
                return Int64(data.count)
            }
        }
        let config = try JSONSerialization.data(withJSONObject: ["language": language, "resourceDirectory": image.directory.path,
            "storageDirectory": storage.path, "commandID": registration.command.id.rawValue])
        instance = config.withUnsafeBytes { bytes in image.create(&api, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) }
        guard instance != nil else { throw CocoaError(.executableLoad) }
    }
    func makeView() throws -> NSView {
        guard let instance, let pointer = image.view(instance) else { throw CocoaError(.executableLoad) }
        return Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue()
    }
    func setLanguage(_ language: String) { language.withCString { image.language(instance, $0) } }
    func detach() { paste = nil; preparePaste = nil; onClose = nil; readDocument = nil }
    func stop() {
        detach()
        guard let instance else { return }
        self.instance = nil
        image.deactivate(instance); image.destroy(instance)
    }
}
