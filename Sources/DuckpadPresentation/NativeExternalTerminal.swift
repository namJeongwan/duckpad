import AppKit

/// Pass a literal directory URL to Terminal's document handler. No shell command
/// is built from workspace names, including spaces, quotes or shell metacharacters.
@MainActor enum NativeExternalTerminal {
    static func open(_ directory: URL, completion: @escaping @MainActor (Bool) -> Void) {
        guard directory.isFileURL,
              let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            completion(false); return
        }
        NSWorkspace.shared.open([directory], withApplicationAt: application, configuration: .init()) { _, error in
            let succeeded = error == nil
            Task { @MainActor in completion(succeeded) }
        }
    }
}
